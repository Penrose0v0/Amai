import AmaiCore
import Foundation

/// 系统记忆的一条条目。在 Markdown 中渲染为
/// `- 条目文字 <!-- src:2026-10-19,2026-10-20 kind:inferred -->`，可按 `### 小节` 分组。
/// `kind` 为 `unknown` 时不写 `kind:`，与 Schema v1 之前的旧格式一致。
public struct MemoryItem: Codable, Sendable, Equatable {
    public var text: String
    /// 来源日期（YYYY-MM-DD），对应 daily 文件。
    public var sources: [String]
    /// 所属小节（`### 小节`）；没有分组时为 nil。
    public var section: String?
    /// 依据类型。旧条目没有记录时为 `unknown`。
    public var kind: MemoryEntryKind

    public init(text: String, sources: [String], section: String? = nil, kind: MemoryEntryKind = .unknown) {
        self.text = text
        self.sources = sources
        self.section = section
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case text, sources, section, kind }

    /// 模型常漏写 sources 或写成单个字符串，宽松解码；缺失的来源由 `MemoryItems.sanitize` 补上。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        if let list = try? c.decodeIfPresent([String].self, forKey: .sources) {
            sources = list
        } else if let single = try? c.decodeIfPresent(String.self, forKey: .sources) {
            sources = [single]
        } else {
            sources = []
        }
        section = try? c.decodeIfPresent(String.self, forKey: .section)
        kind = (try? c.decodeIfPresent(MemoryEntryKind.self, forKey: .kind)) ?? .unknown
    }
}

public enum MemoryItems {
    public static let maxTextLength = 160

    /// 渲染为区块正文。
    /// - 给出 `sections`：按其顺序分组输出，不在其中的小节归入最后一组；
    /// - 不给：按条目中出现的顺序分组，没有小节的条目放在最前面且不加标题。
    public static func render(_ items: [MemoryItem], sections: [String]? = nil) -> String {
        if let sections {
            var blocks: [String] = []
            for section in sections {
                let group = items.filter { item in
                    let s = item.section.flatMap { sections.contains($0) ? $0 : nil } ?? sections.last
                    return s == section
                }
                guard !group.isEmpty else { continue }
                blocks.append("### \(section)\n" + group.map(line).joined(separator: "\n"))
            }
            return blocks.joined(separator: "\n\n")
        }
        var order: [String?] = []
        for item in items where !order.contains(item.section) { order.append(item.section) }
        order.sort { $0 == nil && $1 != nil }
        return order.map { section in
            let lines = items.filter { $0.section == section }.map(line).joined(separator: "\n")
            return section.map { "### \($0)\n" + lines } ?? lines
        }.joined(separator: "\n\n")
    }

    static func line(_ item: MemoryItem) -> String {
        var tags: [String] = []
        if !item.sources.isEmpty { tags.append("src:\(item.sources.joined(separator: ","))") }
        if item.kind != .unknown { tags.append("kind:\(item.kind.rawValue)") }
        return tags.isEmpty ? "- \(item.text)" : "- \(item.text) <!-- \(tags.joined(separator: " ")) -->"
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"<!--\s*((?:src|kind):[^>]*?)\s*-->"#)

    /// 从区块正文解析条目（渲染的逆过程）。没有 `kind:` 的旧条目解析为 `unknown`。
    public static func parse(_ body: String) -> [MemoryItem] {
        var items: [MemoryItem] = []
        var section: String?
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                section = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("- ") else { continue }
            var text = String(line.dropFirst(2))
            var sources: [String] = []
            var kind = MemoryEntryKind.unknown
            let range = NSRange(text.startIndex..., in: text)
            if let m = tagRegex.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) {
                for token in text[r].split(whereSeparator: \.isWhitespace) {
                    if token.hasPrefix("src:") {
                        sources = token.dropFirst(4).split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    } else if token.hasPrefix("kind:") {
                        kind = MemoryEntryKind(rawValue: String(token.dropFirst(5))) ?? .unknown
                    }
                }
                if let whole = Range(m.range, in: text) { text.removeSubrange(whole) }
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { items.append(MemoryItem(text: text, sources: sources, section: section, kind: kind)) }
        }
        return items
    }

    /// 清理模型输出：去换行与注释符号、截断、凭据脱敏、来源只保留合法日期，
    /// 缺来源时补 `fallbackSource`；按规范化文本 + 依据类型去重并合并来源。
    public static func sanitize(_ items: [MemoryItem], fallbackSource: String?, limit: Int) -> [MemoryItem] {
        var cleaned: [MemoryItem] = []
        for item in items {
            var text = item.text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "<!--", with: "")
                .replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("- ") { text = String(text.dropFirst(2)) }
            text = SecretRedactor.redact(String(text.prefix(maxTextLength))).text
            guard !text.isEmpty else { continue }
            var sources = item.sources.filter(isDate)
            if sources.isEmpty, let fallbackSource { sources = [fallbackSource] }
            cleaned.append(MemoryItem(text: text, sources: sources, section: item.section, kind: item.kind))
        }
        return Array(merge(cleaned).prefix(limit))
    }

    /// 合并重复条目：规范化文本相同**且**依据类型相同才合并，来源取并集。
    /// 依据不同的同文条目分开保留，避免合并时把推断"顺带"提升为用户陈述，或反过来丢掉用户陈述。
    public static func merge(_ items: [MemoryItem]) -> [MemoryItem] {
        var result: [MemoryItem] = []
        var index: [String: Int] = [:]
        for item in items {
            let key = "\(item.kind.rawValue)|\(normalize(item.text))"
            if let i = index[key] {
                result[i].sources = Array(Set(result[i].sources + item.sources)).sorted()
                continue
            }
            index[key] = result.count
            var copy = item
            copy.sources = Array(Set(item.sources)).sorted()
            result.append(copy)
        }
        return result
    }

    /// 依据类型校验（防止非法升级）。把模型改写后的条目与改写前的条目按规范化文本对应：
    ///
    /// - 对应到旧条目：沿用旧条目的依据，来源取并集。只有 `allowUpgrade` 认可时，
    ///   才允许从非用户依据（observed / inferred / unknown）提升为 stated / confirmed；
    ///   其他改动（包括降级）一律保持旧依据。旧条目同文但依据不同时各保留一条。
    /// - 新条目：采用提出的依据；提出 stated / confirmed 但未获认可、或未给出依据时用 `defaultKind`。
    public static func reconcileKinds(
        _ proposed: [MemoryItem],
        previous: [MemoryItem],
        defaultKind: MemoryEntryKind,
        allowUpgrade: (MemoryItem) -> Bool = { _ in false }
    ) -> [MemoryItem] {
        var byText: [String: [MemoryItem]] = [:]
        for item in previous { byText[normalize(item.text), default: []].append(item) }

        var result: [MemoryItem] = []
        for item in proposed {
            let matches = byText[normalize(item.text)] ?? []
            if matches.isEmpty {
                var copy = item
                if item.kind == .unknown || (item.kind.isUserBacked && !allowUpgrade(item)) {
                    copy.kind = defaultKind
                }
                result.append(copy)
                continue
            }
            var kinds: [MemoryEntryKind] = []
            for m in matches where !kinds.contains(m.kind) { kinds.append(m.kind) }
            for old in kinds {
                var copy = item
                copy.kind = old
                if item.kind.isUserBacked, !old.isUserBacked, allowUpgrade(item) { copy.kind = item.kind }
                let oldSources = matches.filter { $0.kind == old }.flatMap(\.sources)
                copy.sources = Array(Set(item.sources + oldSources)).sorted()
                result.append(copy)
            }
        }
        return merge(result)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func isDate(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

/// 从模型输出中取出 JSON 对象并解码（容忍代码块与前后多余文字）。
enum ModelJSON {
    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text[open...close].utf8))
    }
}

import AmaiCore
import Foundation

/// 系统记忆的一条条目。在 Markdown 中渲染为
/// `- 条目文字 <!-- src:2026-10-19,2026-10-20 kind:inferred -->`，可按 `### 小节` 分组。
/// `kind` 为 `unknown` 时不写 `kind:`，与 Schema v1 之前的旧格式一致。
/// 其他结构化字段（例如财务的 `cur:JPY txn:2026-10-20`）以 `键:值` 写在同一注释里，读写不丢失。
public struct MemoryItem: Codable, Sendable, Equatable {
    public var text: String
    /// 来源日期（YYYY-MM-DD），对应 daily 文件。
    public var sources: [String]
    /// 所属小节（`### 小节`）；没有分组时为 nil。
    public var section: String?
    /// 依据类型。旧条目没有记录时为 `unknown`。
    public var kind: MemoryEntryKind
    /// 结构化字段（键为小写字母）。
    public var attributes: [String: String]

    public init(
        text: String, sources: [String], section: String? = nil,
        kind: MemoryEntryKind = .unknown, attributes: [String: String] = [:]
    ) {
        self.text = text
        self.sources = sources
        self.section = section
        self.kind = kind
        self.attributes = attributes
    }

    private enum CodingKeys: String, CodingKey { case text, sources, section, kind, attributes }

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
        attributes = (try? c.decodeIfPresent([String: String].self, forKey: .attributes)) ?? [:]
    }
}

public enum MemoryItems {
    public static let maxTextLength = 160

    /// 渲染为区块正文。
    /// - 给出 `sections`：按其顺序分组输出，不在其中的小节归入最后一组；
    /// - 不给：按条目中出现的顺序分组，没有小节的条目放在最前面且不加标题。
    /// `sectionMeta` 写在小节标题后的注释里（例如 Work 项目的稳定 ID）。
    public static func render(
        _ items: [MemoryItem], sections: [String]? = nil, sectionMeta: [String: [String: String]] = [:]
    ) -> String {
        func header(_ name: String) -> String {
            let meta = sectionMeta[name].map(tags) ?? ""
            return meta.isEmpty ? "### \(name)" : "### \(name) <!-- \(meta) -->"
        }
        if let sections {
            var blocks: [String] = []
            for section in sections {
                let group = items.filter { item in
                    let s = item.section.flatMap { sections.contains($0) ? $0 : nil } ?? sections.last
                    return s == section
                }
                guard !group.isEmpty else { continue }
                blocks.append(header(section) + "\n" + group.map(line).joined(separator: "\n"))
            }
            return blocks.joined(separator: "\n\n")
        }
        var order: [String?] = []
        for item in items where !order.contains(item.section) { order.append(item.section) }
        order.sort { $0 == nil && $1 != nil }
        return order.map { section in
            let lines = items.filter { $0.section == section }.map(line).joined(separator: "\n")
            return section.map { header($0) + "\n" + lines } ?? lines
        }.joined(separator: "\n\n")
    }

    static func line(_ item: MemoryItem) -> String {
        var fields: [String: String] = item.attributes
        fields.removeValue(forKey: "src")
        fields.removeValue(forKey: "kind")
        var parts: [String] = []
        if !item.sources.isEmpty { parts.append("src:\(item.sources.joined(separator: ","))") }
        if item.kind != .unknown { parts.append("kind:\(item.kind.rawValue)") }
        let rest = tags(fields)
        if !rest.isEmpty { parts.append(rest) }
        return parts.isEmpty ? "- \(item.text)" : "- \(item.text) <!-- \(parts.joined(separator: " ")) -->"
    }

    /// `键:值` 列表，按键排序；值中的空白、`%` 与注释符号做百分号编码，保证能原样读回。
    static func tags(_ fields: [String: String]) -> String {
        fields.filter { isKey($0.key) && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\(encode($0.value))" }
            .joined(separator: " ")
    }

    private static func encode(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "%": out += "%25"
            case " ": out += "%20"
            case "\n": out += "%0A"
            case ">": out += "%3E"
            case "\t": out += "%09"
            default: out.append(ch)
            }
        }
        return out
    }

    static func isKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLowercase || $0 == "_") }
    }

    /// 解析注释里的 `键:值`。
    static func parseTags(_ text: Substring) -> [String: String] {
        var fields: [String: String] = [:]
        for token in text.split(whereSeparator: \.isWhitespace) {
            guard let colon = token.firstIndex(of: ":") else { continue }
            let key = String(token[..<colon])
            guard isKey(key) else { continue }
            fields[key] = String(token[token.index(after: colon)...]).removingPercentEncoding ?? String(token[token.index(after: colon)...])
        }
        return fields
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"<!--\s*([a-z_]+:[^>]*?)\s*-->\s*$"#)

    /// 小节标题与其元数据（按出现顺序）。
    public static func sections(_ body: String) -> [(name: String, meta: [String: String])] {
        var result: [(String, [String: String])] = []
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("### ") else { continue }
            let (name, meta) = splitHeader(String(line.dropFirst(4)))
            if !result.contains(where: { $0.0 == name }) { result.append((name, meta)) }
        }
        return result
    }

    private static func splitHeader(_ text: String) -> (String, [String: String]) {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = tagRegex.firstMatch(in: text, range: range),
              let inner = Range(m.range(at: 1), in: text), let whole = Range(m.range, in: text)
        else { return (text.trimmingCharacters(in: .whitespaces), [:]) }
        let meta = parseTags(text[inner])
        var name = text
        name.removeSubrange(whole)
        return (name.trimmingCharacters(in: .whitespaces), meta)
    }

    /// 从区块正文解析条目（渲染的逆过程）。没有 `kind:` 的旧条目解析为 `unknown`。
    public static func parse(_ body: String) -> [MemoryItem] {
        var items: [MemoryItem] = []
        var section: String?
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                section = splitHeader(String(line.dropFirst(4))).0
                continue
            }
            guard line.hasPrefix("- ") else { continue }
            var text = String(line.dropFirst(2))
            var sources: [String] = []
            var kind = MemoryEntryKind.unknown
            var attributes: [String: String] = [:]
            let range = NSRange(text.startIndex..., in: text)
            if let m = tagRegex.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) {
                attributes = parseTags(text[r])
                if let src = attributes.removeValue(forKey: "src") {
                    sources = src.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
                if let k = attributes.removeValue(forKey: "kind") {
                    kind = MemoryEntryKind(rawValue: k) ?? .unknown
                }
                if let whole = Range(m.range, in: text) { text.removeSubrange(whole) }
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                items.append(MemoryItem(text: text, sources: sources, section: section, kind: kind, attributes: attributes))
            }
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
            cleaned.append(MemoryItem(text: text, sources: sources, section: item.section, kind: item.kind, attributes: item.attributes))
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
                result[i].attributes.merge(item.attributes) { old, _ in old }
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

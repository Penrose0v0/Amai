import AmaiCore
import Foundation

/// 系统记忆的一条条目。在 Markdown 中渲染为
/// `- 条目文字 <!-- src:2026-10-19,2026-10-20 -->`，可按 `### 小节` 分组。
/// 早期版本写过依据类型 `kind:`（ADR-0009 已移除），读取时忽略，下次整理改写该文件时不再写出。
/// 其他结构化字段（例如财务的 `cur:JPY txn:2026-10-20`）以 `键:值` 写在同一注释里，读写不丢失。
public struct MemoryItem: Codable, Sendable, Equatable {
    public var text: String
    /// 来源日期（YYYY-MM-DD），对应 daily 文件。
    public var sources: [String]
    /// 所属小节（`### 小节`）；没有分组时为 nil。
    public var section: String?
    /// 结构化字段（键为小写字母）。
    public var attributes: [String: String]

    public init(
        text: String, sources: [String], section: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.text = text
        self.sources = sources
        self.section = section
        self.attributes = attributes
    }

    private enum CodingKeys: String, CodingKey { case text, sources, section, attributes }

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
        fields.removeValue(forKey: Self.legacyKindKey)
        var parts: [String] = []
        if !item.sources.isEmpty { parts.append("src:\(item.sources.joined(separator: ","))") }
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

    /// 早期版本记录依据类型的字段名。读取时丢弃，不进入 `attributes`，也不再写出。
    static let legacyKindKey = "kind"

    /// 从区块正文解析条目（渲染的逆过程）。带旧 `kind:` 字段的条目照常读入，只是忽略该字段。
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
            var attributes: [String: String] = [:]
            let range = NSRange(text.startIndex..., in: text)
            if let m = tagRegex.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) {
                attributes = parseTags(text[r])
                if let src = attributes.removeValue(forKey: "src") {
                    sources = src.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
                attributes.removeValue(forKey: Self.legacyKindKey)
                if let whole = Range(m.range, in: text) { text.removeSubrange(whole) }
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                items.append(MemoryItem(text: text, sources: sources, section: section, attributes: attributes))
            }
        }
        return items
    }

    /// 清理模型输出：去换行与注释符号、截断、凭据脱敏、来源只保留合法日期，
    /// 缺来源时补 `fallbackSource`；按规范化文本去重并合并来源。
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
            cleaned.append(MemoryItem(text: text, sources: sources, section: item.section, attributes: item.attributes))
        }
        return Array(merge(cleaned).prefix(limit))
    }

    /// 合并重复条目：规范化文本相同即合并，来源取并集，结构化字段以先出现的为准。
    public static func merge(_ items: [MemoryItem]) -> [MemoryItem] {
        var result: [MemoryItem] = []
        var index: [String: Int] = [:]
        for item in items {
            let key = normalize(item.text)
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

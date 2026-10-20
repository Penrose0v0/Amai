import AmaiCore
import Foundation

/// 系统记忆的一条条目。在 Markdown 中渲染为
/// `- 条目文字 <!-- src:2026-10-19,2026-10-20 -->`，可按 `### 小节` 分组。
public struct MemoryItem: Codable, Sendable, Equatable {
    public var text: String
    /// 来源日期（YYYY-MM-DD），对应 daily 文件。
    public var sources: [String]
    /// 所属小节，仅 summary 使用。
    public var section: String?

    public init(text: String, sources: [String], section: String? = nil) {
        self.text = text
        self.sources = sources
        self.section = section
    }

    private enum CodingKeys: String, CodingKey { case text, sources, section }

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
    }
}

public enum MemoryItems {
    public static let maxTextLength = 160

    /// 渲染为区块正文。给出 `sections` 时按其顺序分组输出，不在其中的归入最后一组。
    public static func render(_ items: [MemoryItem], sections: [String]? = nil) -> String {
        guard let sections else { return items.map(line).joined(separator: "\n") }
        var blocks: [String] = []
        for section in sections {
            let group = items.filter { ($0.section ?? sections.last) == section }
            guard !group.isEmpty else { continue }
            blocks.append("### \(section)\n" + group.map(line).joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    static func line(_ item: MemoryItem) -> String {
        let sources = item.sources.isEmpty ? "" : " <!-- src:\(item.sources.joined(separator: ",")) -->"
        return "- \(item.text)\(sources)"
    }

    private static let srcRegex = try! NSRegularExpression(pattern: #"<!--\s*src:([^>]*?)\s*-->"#)

    /// 从区块正文解析条目（渲染的逆过程）。
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
            let range = NSRange(text.startIndex..., in: text)
            if let m = srcRegex.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) {
                sources = text[r].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if let whole = Range(m.range, in: text) { text.removeSubrange(whole) }
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { items.append(MemoryItem(text: text, sources: sources, section: section)) }
        }
        return items
    }

    /// 清理模型输出：去换行与注释符号、截断、凭据脱敏、来源只保留合法日期，
    /// 缺来源时补 `fallbackSource`；按规范化文本去重并合并来源。
    public static func sanitize(_ items: [MemoryItem], fallbackSource: String?, limit: Int) -> [MemoryItem] {
        var result: [MemoryItem] = []
        var index: [String: Int] = [:]
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
            let key = normalize(text)
            if let i = index[key] {
                result[i].sources = Array(Set(result[i].sources + sources)).sorted()
                continue
            }
            index[key] = result.count
            result.append(MemoryItem(text: text, sources: Array(Set(sources)).sorted(), section: item.section))
            if result.count >= limit { break }
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

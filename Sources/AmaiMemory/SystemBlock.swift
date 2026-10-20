import Foundation

/// Markdown 文件中由系统维护的区块，用两条 HTML 注释包住（渲染时不可见）：
///
/// ```markdown
/// <!-- amai:<name>:begin · 说明 -->
/// …系统生成的内容…
/// <!-- amai:<name>:end -->
/// ```
///
/// 系统只改写区块内的内容；区块外由用户自由编辑，系统永不覆盖。
public struct SystemBlock: Sendable, Equatable {
    public let name: String
    public let note: String

    public init(name: String, note: String) {
        self.name = name
        self.note = note
    }

    public var beginPrefix: String { "<!-- amai:\(name):begin" }
    public var beginMarker: String { "\(beginPrefix) · \(note) -->" }
    public var endMarker: String { "<!-- amai:\(name):end -->" }

    public enum SpliceError: Error, Equatable {
        /// 只有一条标记或顺序颠倒。为避免误删用户内容，拒绝写入。
        case malformedMarkers(String)
    }

    /// 区块内的内容（不含标记）；没有完整区块时为 nil。
    public func content(in text: String) -> String? {
        guard let b = text.range(of: beginPrefix), let e = text.range(of: endMarker), b.lowerBound < e.lowerBound,
              let lineEnd = text[b.upperBound...].firstIndex(of: "\n"), lineEnd < e.lowerBound
        else { return nil }
        return text[text.index(after: lineEnd)..<e.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉整个区块（含标记），得到用户手写的部分，作为模型上下文使用。
    public func removing(from text: String) -> String {
        guard let range = blockRange(in: text) else { return text }
        var result = text
        result.removeSubrange(range)
        return result
    }

    /// 把 `body` 放进文件内容：
    /// - 文件为空：用 `newFileTitle` 生成新文件（一级标题 + `heading` + 区块）；
    /// - 有完整区块：只替换区块；
    /// - 没有区块：插到 `insertBeforeHeading` 所在行之前（找不到时追加到文末），并带上 `heading`；
    /// - 标记不完整：抛错。
    public func splice(
        body: String,
        into existing: String?,
        newFileTitle: String,
        heading: String,
        insertBeforeHeading: String? = nil
    ) throws -> String {
        let block = [beginMarker, body, endMarker].filter { !$0.isEmpty }.joined(separator: "\n")
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "# \(newFileTitle)\n\n\(heading)\n\n\(block)\n"
        }
        if let range = blockRange(in: existing) {
            var result = existing
            result.replaceSubrange(range, with: block)
            return result
        }
        guard existing.range(of: beginPrefix) == nil, existing.range(of: endMarker) == nil else {
            throw SpliceError.malformedMarkers(name)
        }
        let section = "\(heading)\n\n\(block)\n"
        if let anchor = insertBeforeHeading,
           let r = existing.range(of: "\n" + anchor + "\n") ?? (existing.hasPrefix(anchor + "\n") ? existing.range(of: anchor) : nil) {
            var result = existing
            let insertAt = existing[r].hasPrefix("\n") ? existing.index(after: r.lowerBound) : r.lowerBound
            result.insert(contentsOf: section + "\n", at: insertAt)
            return result
        }
        let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
        return existing + separator + section
    }

    /// 从开始标记所在行的行首到结束标记末尾。
    private func blockRange(in text: String) -> Range<String.Index>? {
        guard let b = text.range(of: beginPrefix), let e = text.range(of: endMarker), b.lowerBound < e.lowerBound
        else { return nil }
        let lineStart = text[..<b.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        return lineStart..<e.upperBound
    }
}

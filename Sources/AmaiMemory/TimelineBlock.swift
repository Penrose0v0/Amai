import AmaiCore
import Foundation

/// daily 文件中由系统管理的时间线区块（2026-10-20 用户确认的方案）：
///
/// ```markdown
/// ## 时间线
///
/// <!-- amai:timeline:begin · 由 Amai 自动维护 … -->
/// - 11:31–11:37 浏览项目文件与日程安排 <!-- seg:<UUID> conf:0.88 src:mlx:… -->
///   在 VS Code 中浏览 Amai 项目文件，并查看日历中的日程安排。
/// <!-- amai:timeline:end -->
/// ```
///
/// - 系统只改写两条注释之间的内容，区块外由用户自由编辑，系统永不触碰；
/// - 每个活动片段以 `seg:<UUID>` 保留稳定 ID，跨窗口延续时 ID 不变；
/// - 时间线里的内容都是模型推断，低置信度片段在行首加〔低置信〕标记；
/// - 空闲与隐私跳过片段不写入。
public enum TimelineBlock {
    public static let beginPrefix = "<!-- amai:timeline:begin"
    public static let endMarker = "<!-- amai:timeline:end -->"
    public static let beginMarker = "\(beginPrefix) · 由 Amai 根据屏幕活动自动维护，均为模型推断；区块内的修改会被覆盖，需要保留的内容请写在区块外 -->"
    public static let heading = "## 时间线"
    public static let lowConfidenceTag = "〔低置信〕"
    public static let lowConfidenceThreshold = 0.5

    public enum SpliceError: Error, Equatable {
        /// 只有开始或只有结束标记，或顺序颠倒。为避免误删用户内容，拒绝写入。
        case malformedMarkers
    }

    /// 片段是否写入 daily：空闲与隐私跳过不写。
    public static func includes(_ segment: ActivitySegment) -> Bool {
        if segment.category == .idle { return false }
        if segment.provider == "rule:idle" || segment.provider == "rule:privacy" { return false }
        return true
    }

    public static func isLowConfidence(_ segment: ActivitySegment) -> Bool {
        segment.confidence < lowConfidenceThreshold || segment.provider.hasPrefix("fallback")
    }

    /// 渲染区块正文（不含首尾标记），按开始时间排序。
    public static func render(_ segments: [ActivitySegment], timeZone: TimeZone) -> String {
        segments
            .filter(includes)
            .sorted { $0.timeRange.start < $1.timeRange.start }
            .map { line(for: $0, timeZone: timeZone) }
            .joined(separator: "\n")
    }

    static func line(for segment: ActivitySegment, timeZone: TimeZone) -> String {
        let time = "\(hhmm(segment.timeRange.start, timeZone))–\(hhmm(segment.timeRange.end, timeZone))"
        let tag = isLowConfidence(segment) ? lowConfidenceTag : ""
        let title = sanitize(segment.title)
        let meta = String(format: "seg:%@ conf:%.2f src:%@", segment.id.uuidString, segment.confidence, segment.provider)
        var text = "- \(time) \(tag)\(title) <!-- \(meta) -->"
        let summary = sanitize(segment.summary)
        if !summary.isEmpty {
            text += "\n  \(summary)"
        }
        return text
    }

    /// 把渲染结果放进文件内容中。
    /// - 文件为空：生成新文件（标题 + 时间线小节 + 区块）；
    /// - 有完整标记：只替换标记之间的内容；
    /// - 没有标记（用户删掉了区块）：在文末追加时间线小节与区块；
    /// - 标记不完整：抛错，不写入。
    public static func splice(body: String, into existing: String?, dayTitle: String) throws -> String {
        let block = [beginMarker, body, endMarker].filter { !$0.isEmpty }.joined(separator: "\n")
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "# \(dayTitle)\n\n\(heading)\n\n\(block)\n"
        }

        let begin = existing.range(of: beginPrefix)
        let end = existing.range(of: endMarker)
        switch (begin, end) {
        case let (b?, e?) where b.lowerBound < e.lowerBound:
            // 开始标记占据整行：从行首替换到结束标记末尾。
            let lineStart = existing[..<b.lowerBound].lastIndex(of: "\n").map { existing.index(after: $0) } ?? existing.startIndex
            var result = existing
            result.replaceSubrange(lineStart..<e.upperBound, with: block)
            return result
        case (nil, nil):
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            return existing + separator + "\(heading)\n\n\(block)\n"
        default:
            throw SpliceError.malformedMarkers
        }
    }

    /// 标题与摘要里的换行、HTML 注释符号会破坏区块结构，写入前去掉；再做一次凭据脱敏兜底。
    static func sanitize(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .trimmingCharacters(in: .whitespaces)
        return SecretRedactor.redact(flattened).text
    }

    private static func hhmm(_ date: Date, _ timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

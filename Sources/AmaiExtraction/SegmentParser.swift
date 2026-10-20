import AmaiCore
import Foundation

/// 模型输出的一个活动片段，时间已映射回绝对时间并校验过。
struct ParsedSegment: Equatable {
    var range: TimeRange
    var title: String
    var summary: String
    var category: ActivityCategory
    var confidence: Double
    var continuesPrevious: Bool
}

enum SegmentParserError: Error, Equatable {
    case noJSONArray
    case decodeFailed
    case noValidSegments
}

/// 解析并校验活动切分模型的 JSON 输出。
/// 容错：代码块包裹、前后多余文字、`HH:MM` 省略秒、跨午夜。
/// 校验：裁剪到窗口范围内、按开始时间排序、消除重叠、丢弃无效片段。
enum SegmentParser {
    private struct Raw: Decodable {
        let start: String
        let end: String
        let title: String?
        let summary: String?
        let category: String?
        let confidence: Double?
        let continues_previous: Bool?
    }

    static func parse(_ text: String, window: TimeRange, timeZone: TimeZone) throws -> [ParsedSegment] {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close else {
            throw SegmentParserError.noJSONArray
        }
        let json = Data(text[open...close].utf8)
        guard let raws = try? JSONDecoder().decode([Raw].self, from: json) else {
            throw SegmentParserError.decodeFailed
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: window.start)

        var segments: [ParsedSegment] = []
        for (i, raw) in raws.enumerated() {
            guard var start = clockTime(raw.start, day: day, window: window, calendar: calendar),
                  var end = clockTime(raw.end, day: day, window: window, calendar: calendar)
            else { continue }
            start = max(start, window.start)
            end = min(end, window.end)
            guard end > start else { continue }
            let title = String((raw.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            guard !title.isEmpty else { continue }
            segments.append(ParsedSegment(
                range: TimeRange(start: start, end: end),
                title: title,
                summary: String((raw.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
                category: ActivityCategory(rawValue: (raw.category ?? "").lowercased()) ?? .other,
                confidence: min(1, max(0, raw.confidence ?? 0.5)),
                continuesPrevious: i == 0 && (raw.continues_previous ?? false)
            ))
        }

        segments.sort { $0.range.start < $1.range.start }
        var cleaned: [ParsedSegment] = []
        for var seg in segments {
            if let prev = cleaned.last, seg.range.start < prev.range.end {
                let newStart = prev.range.end
                guard seg.range.end > newStart else { continue }
                seg.range = TimeRange(start: newStart, end: seg.range.end)
            }
            // 只有时间上排第一的片段可以延续上一个片段。
            if !cleaned.isEmpty { seg.continuesPrevious = false }
            cleaned.append(seg)
        }
        guard !cleaned.isEmpty else { throw SegmentParserError.noValidSegments }
        return cleaned
    }

    /// 把短于 `minDuration` 的片段并入相邻片段，直到所有片段都够长或只剩一个。
    /// 合并后的标题、摘要、分类取两者中较长的那个；置信度按时长加权；
    /// "延续上一个片段"只保留在合并结果的第一个片段上。
    static func mergeShort(_ segments: [ParsedSegment], minDuration: TimeInterval) -> [ParsedSegment] {
        var list = segments
        while list.count > 1, let i = list.indices.min(by: { list[$0].range.duration < list[$1].range.duration }),
              list[i].range.duration < minDuration {
            // 优先并入前一个；第一个片段并入后一个。
            let j = i > 0 ? i - 1 : i + 1
            let (a, b) = (min(i, j), max(i, j))
            let first = list[a], second = list[b]
            let dominant = first.range.duration >= second.range.duration ? first : second
            let total = first.range.duration + second.range.duration
            let confidence = total > 0
                ? (first.confidence * first.range.duration + second.confidence * second.range.duration) / total
                : dominant.confidence
            list[a] = ParsedSegment(
                range: TimeRange(start: first.range.start, end: max(first.range.end, second.range.end)),
                title: dominant.title,
                summary: dominant.summary,
                category: dominant.category,
                confidence: confidence,
                continuesPrevious: first.continuesPrevious
            )
            list.remove(at: b)
        }
        return list
    }

    /// "HH:MM:SS" 或 "HH:MM" → 绝对时间。早于窗口开始一小时以上视为跨过午夜。
    private static func clockTime(_ s: String, day: Date, window: TimeRange, calendar: Calendar) -> Date? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        let seconds = parts.count >= 3 ? parts[2] : 0
        guard var date = calendar.date(
            bySettingHour: parts[0], minute: parts[1], second: min(59, max(0, seconds)), of: day
        ) else { return nil }
        if date < window.start.addingTimeInterval(-3600) {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }
}

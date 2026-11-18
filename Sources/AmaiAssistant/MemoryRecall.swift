import AmaiCore
import AmaiMemory
import Foundation

/// 为一个问题准备好的记忆：放进提示词的文字，以及它来自哪里。
public struct RecalledMemory: Sendable, Equatable {
    public var text: String
    public var sources: [MemorySource]
    /// 这次放进提示词的各项的标识（会话记下来，同一段对话里不重复放）。
    public var keys: Set<String>
    /// 问题指向的日期（YYYY-MM-DD）。会话记下来，下一个问题说"那天"时指的就是它们。
    public var days: [String] = []
}

/// 问答的记忆检索：由后端在调用模型之前完成，模型不需要、也不能自己去查。
///
/// 两条路并行：
/// - 问题里提到了日期（"昨天""11 月 6 日""上周"）：直接取那几天的时间线；
/// - 其余：用问题做一次混合检索（关键词 + 语义向量，`MemoryAPI.search`）。
///
/// 只读，经过 `MemoryAPI`，所以可读分区与 MCP、与云端模型是同一份授权。
/// 参考 OpenClaw：它的检索默认要模型调用 `memory_search`，自动注入由另一个插件用子 Agent 先总结再放入；
/// 这里面向的是不一定会调用工具的本地小模型，所以直接放检索到的条目（已经是一条一条的短句），不再过一遍模型。
public struct MemoryRecall: Sendable {
    public let api: MemoryAPI
    private let timeZone: TimeZone

    /// 检索结果最多放几条、整段最多多少字符。条目是单条的短句，6 条通常只有几百个字符。
    public static let maxEntries = 6
    public static let maxCharacters = 5000
    static let dayCharacters = 1800
    static let rangeDayCharacters = 360

    public init(api: MemoryAPI, timeZone: TimeZone = .current) {
        self.api = api
        self.timeZone = timeZone
    }

    public var isEnabled: Bool { !api.access.categories.isEmpty }

    /// 面板唤出时调用：把索引更新到最新、让向量模型加载好，提交问题后检索就不用等。
    public func prepare() async {
        guard isEnabled else { return }
        await api.prepareSearch()
    }

    /// 指代上文日期的说法。
    static let sameDayWords = ["那天", "那一天", "当天", "这天", "这一天", "同一天", "that day", "the same day", "その日", "当日"]

    /// - Parameters:
    ///   - previousQuestion: 上一个问题。追问往往很短（"那后来呢？"），带上它一起检索。
    ///   - previousDays: 上一个问题指向的日期。这个问题说"那天"时沿用。
    ///   - shown: 这段对话里已经放进过提示词的项（它们还在历史里，不重复放）。
    public func recall(
        question: String, previousQuestion: String? = nil, previousDays: [String] = [],
        shown: Set<String> = [], now: Date = Date()
    ) async -> RecalledMemory? {
        guard isEnabled else { return nil }
        var sections: [String] = []
        var sources: [MemorySource] = []
        var keys = Set<String>()

        // 1. 提到的日期 → 时间线。
        var dates = DateMentions.parse(question, now: now, timeZone: timeZone)
        var notes: [String] = []
        if dates.isEmpty, !previousDays.isEmpty, Self.sameDayWords.contains(where: question.lowercased().contains) {
            dates.days = previousDays.compactMap { MemoryDirectory.day(ofDailyFile: "\(MemoryDirectory.dailyDirectory)/\($0).md", timeZone: timeZone) }
            notes.append("\"That day\" in the question refers to \(previousDays.joined(separator: ", ")), discussed earlier in this conversation.")
        }
        // 问题限定了日期时，检索结果也只保留那几天的：否则"那天做了什么决定"会被别的日子的决定带偏。
        var scope: Set<String>?
        if !dates.isEmpty {
            var names = Set(dates.days.map { MemoryDirectory.dayName(for: $0, timeZone: timeZone) })
            if let range = dates.range {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                var day = range.lowerBound
                while day <= range.upperBound, names.count < 40 {
                    names.insert(MemoryDirectory.dayName(for: day, timeZone: timeZone))
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
            }
            scope = names
        }
        if !dates.isEmpty {
            if api.access.allows(.daily) {
                for day in dates.days {
                    let name = MemoryDirectory.dayName(for: day, timeZone: timeZone)
                    let key = "day:\(name)"
                    // 今天的时间线还在增长，每次都重新给；过去的日子给过一次就够了。
                    guard !shown.contains(key) || name == MemoryDirectory.dayName(for: now, timeZone: timeZone) else { continue }
                    guard let timeline = try? api.timeline(on: name) else { continue }
                    sections.append(Self.format(timeline, limit: Self.dayCharacters))
                    keys.insert(key)
                    if timeline.exists { sources.append(Self.source(day: name)) }
                }
                if let range = dates.range {
                    var lines: [String] = []
                    var day = range.upperBound
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = timeZone
                    while day >= range.lowerBound, lines.count < DateMentions.maxRangeDays {
                        let name = MemoryDirectory.dayName(for: day, timeZone: timeZone)
                        if let timeline = try? api.timeline(on: name), timeline.exists {
                            lines.append(Self.brief(timeline))
                            sources.append(Self.source(day: name))
                        }
                        guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
                        day = previous
                    }
                    let from = MemoryDirectory.dayName(for: range.lowerBound, timeZone: timeZone)
                    let to = MemoryDirectory.dayName(for: range.upperBound, timeZone: timeZone)
                    sections.append(lines.isEmpty
                        ? "Daily records from \(from) to \(to): none."
                        : "Daily records from \(from) to \(to), newest first:\n" + lines.joined(separator: "\n"))
                }
            } else {
                sections.append("The question mentions a date, but the user has not allowed the assistant to read daily timelines (Amai Settings → Assistant).")
            }
        }

        // 2. 混合检索。
        var query = question
        if let previousQuestion, question.count < 24 { query = previousQuestion + "\n" + question }
        // 限定日期时多取一些再筛。
        if let results = try? await api.search(query, limit: scope == nil ? Self.maxEntries : Self.maxEntries * 4, now: now) {
            var lines: [String] = []
            for result in results where lines.count < Self.maxEntries {
                if let scope, !(result.date.map(scope.contains) ?? false), scope.isDisjoint(with: result.sources) { continue }
                let key = "\(result.file)#\(result.content)"
                guard !shown.contains(key), keys.insert(key).inserted else { continue }
                // 已经整天给出的时间线里的条目不再单独列。
                if result.category == .daily, let date = result.date,
                   keys.contains("day:\(date)") || shown.contains("day:\(date)") { continue }
                lines.append(Self.format(result))
                let source = MemorySource(
                    category: result.category, file: result.file,
                    section: result.category == .daily || result.section.isEmpty ? nil : result.section, date: result.date
                )
                if !sources.contains(source) { sources.append(source) }
            }
            if !lines.isEmpty {
                sections.insert("Entries found for this question, most relevant first:\n" + lines.joined(separator: "\n"), at: 0)
            }
        }

        let days = dates.days.map { MemoryDirectory.dayName(for: $0, timeZone: timeZone) }
        guard !sections.isEmpty else {
            // 没有新的内容可放，但仍要把"那天"指的是哪天告诉模型，并让会话记住日期。
            guard !days.isEmpty else { return nil }
            return RecalledMemory(text: notes.joined(separator: "\n"), sources: [], keys: [], days: days)
        }
        var text = (notes + sections).joined(separator: "\n\n")
        if text.count > Self.maxCharacters { text = String(text.prefix(Self.maxCharacters)) + " […]" }
        return RecalledMemory(text: text, sources: sources, keys: keys, days: days)
    }

    // MARK: - Formatting

    private static func source(day: String) -> MemorySource {
        MemorySource(category: .daily, file: "\(MemoryDirectory.dailyDirectory)/\(day).md", date: day)
    }

    /// `- [work › Lumen, 2026-11-06] 放弃 CloudKit…` / `- [timeline 2026-11-07] 14:00–15:00 …`
    static func format(_ result: MemorySearchResult) -> String {
        var label: String
        if result.category == .daily {
            label = "timeline" + (result.date.map { " \($0)" } ?? "")
        } else {
            label = result.category.rawValue
            if !result.section.isEmpty { label += " › \(result.section)" }
            if let date = result.date { label += ", \(date)" }
        }
        return "- [\(label)] " + result.content.replacingOccurrences(of: "\n", with: " ")
    }

    static func format(_ timeline: DayTimeline, limit: Int) -> String {
        guard timeline.exists, !(timeline.entries.isEmpty && (timeline.summary ?? "").isEmpty) else {
            return "Timeline for \(timeline.date): no record for this day."
        }
        var lines = ["Timeline for \(timeline.date):"]
        if let summary = timeline.summary, !summary.isEmpty { lines.append("Summary: " + summary) }
        for entry in timeline.entries {
            var line = "- \(entry.start)–\(entry.end) \(entry.title)"
            if !entry.summary.isEmpty { line += " — \(entry.summary)" }
            if entry.lowConfidence { line += " (uncertain)" }
            lines.append(line)
        }
        if !timeline.userNotes.isEmpty { lines.append("User's own notes: " + timeline.userNotes) }
        let text = lines.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + " […]" : text
    }

    /// 一段时间里的一天：有日终摘要用摘要，否则列出各片段的标题。
    static func brief(_ timeline: DayTimeline) -> String {
        let body: String
        if let summary = timeline.summary, !summary.isEmpty {
            body = summary.replacingOccurrences(of: "\n", with: " ")
        } else {
            body = timeline.entries.map(\.title).joined(separator: "; ")
        }
        let clipped = body.count > rangeDayCharacters ? String(body.prefix(rangeDayCharacters)) + " […]" : body
        return "- \(timeline.date): \(clipped)"
    }
}

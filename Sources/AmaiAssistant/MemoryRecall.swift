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
/// 候选有两种来源：
/// - 问题里提到了日期（"昨天""11 月 6 日""上周五"）：那几天的时间线，逐条作为候选；
/// - 混合检索（关键词 + 语义向量，`MemoryAPI.search`）的结果。
///
/// 放多少由 token 预算决定（ADR-0012），不再是固定的前 6 条与按字符截断的整天时间线：
/// 1. 提到的那几天的日终摘要、日期区间里每天的概要；
/// 2. 按相关度排序的条目：混合检索的结果，与提到的那几天里按问题排出的片段一起，按得分从高到低；
/// 3. 提到的那几天里剩下的片段，按时间顺序。
/// 依次装入，直到预算用完。一天没有放全时注明还有几条没放，模型知道不是全部。
/// 去重：提到的那天里的检索命中只出现在那天的时间线里；文字相同的条目只放一次；同一段对话里给过的不再给。
///
/// 检索结果只去掉明显不如最好结果的长尾（低于第一名得分的 `relativeFloor`）；第一名总会保留，
/// 所以这不是"无关问题就什么都不给"的绝对门槛。
///
/// 只读，经过 `MemoryAPI`，所以可读分区与 MCP、与云端模型是同一份授权。
/// 参考 OpenClaw：它的检索默认要模型调用 `memory_search`，自动注入由另一个插件用子 Agent 先总结再放入；
/// 这里面向的是不一定会调用工具的本地小模型，所以直接放检索到的条目（已经是一条一条的短句），不再过一遍模型。
public struct MemoryRecall: Sendable {
    public let api: MemoryAPI
    private let timeZone: TimeZone
    /// 放进提示词的记忆最多这么多 token（估算：汉字每字 1，其余每 4 个字符 1）。
    public let tokenBudget: Int

    public static let defaultTokenBudget = 4096
    /// 每次检索取多少条候选（`MemoryAPI` 的上限）。最终放多少由预算与 `relativeFloor` 决定。
    public static let searchLimit = MemoryAPI.maxSearchLimit
    /// 检索结果低于第一名得分的这个比例就不放。
    public static let relativeFloor = 0.5
    static let rangeDayCharacters = 360

    public init(api: MemoryAPI, timeZone: TimeZone = .current, tokenBudget: Int = MemoryRecall.defaultTokenBudget) {
        self.api = api
        self.timeZone = timeZone
        self.tokenBudget = tokenBudget
    }

    public var isEnabled: Bool { !api.access.categories.isEmpty }

    /// 面板唤出时调用：把索引更新到最新、让向量模型加载好，提交问题后检索就不用等。
    public func prepare() async {
        guard isEnabled else { return }
        await api.prepareSearch()
    }

    /// 指代上文日期的说法。
    static let sameDayWords = ["那天", "那一天", "当天", "这天", "这一天", "同一天", "that day", "the same day", "その日", "当日"]

    /// 与 `MemoryChunker.estimatedTokens` 相同的估算。
    static func tokens(_ text: String) -> Int {
        var wide = 0, narrow = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 { wide += 1 } else { narrow += 1 }
        }
        return wide + (narrow + 3) / 4
    }

    /// 一个候选：放进提示词的一行。
    struct Candidate {
        enum Group: Equatable {
            case entries
            case day(String)
            case range
        }

        let key: String
        let line: String
        let group: Group
        let tokens: Int
        /// 时间线片段在当天的位置（输出时按时间排）。
        var order = 0
        var source: MemorySource?
    }

    /// - Parameters:
    ///   - previousQuestion: 上一个问题。追问往往很短（"那后来呢？"），带上它一起检索。
    ///   - previousDays: 上一个问题指向的日期。这个问题说"那天"时沿用。
    ///   - shown: 这段对话里已经放进过提示词的项（它们还在历史里，不重复放）。
    public func recall(
        question: String, previousQuestion: String? = nil, previousDays: [String] = [],
        shown: Set<String> = [], now: Date = Date()
    ) async -> RecalledMemory? {
        guard isEnabled else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // 1. 提到的日期。
        var dates = DateMentions.parse(question, now: now, timeZone: timeZone)
        var notes: [String] = []
        if dates.isEmpty, !previousDays.isEmpty, Self.sameDayWords.contains(where: question.lowercased().contains) {
            dates.days = previousDays.compactMap { MemoryDirectory.day(ofDailyFile: "\(MemoryDirectory.dailyDirectory)/\($0).md", timeZone: timeZone) }
            notes.append("\"That day\" in the question refers to \(previousDays.joined(separator: ", ")), discussed earlier in this conversation.")
        }
        let dayNames = dates.days.map { MemoryDirectory.dayName(for: $0, timeZone: timeZone) }
        // 问题限定了日期时，检索结果也只保留那几天的：否则"那天做了什么决定"会被别的日子的决定带偏。
        var scope: Set<String>?
        if !dates.isEmpty {
            var names = Set(dayNames)
            if let range = dates.range {
                var day = range.lowerBound
                while day <= range.upperBound, names.count < 40 {
                    names.insert(MemoryDirectory.dayName(for: day, timeZone: timeZone))
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
            }
            scope = names
        }
        var query = question
        if let previousQuestion, question.count < 24 { query = previousQuestion + "\n" + question }

        // 2. 候选：混合检索。
        var ranked: [(candidate: Candidate, score: Double)] = []
        var seenText = Set<String>()
        if let results = try? await api.search(query, limit: Self.searchLimit, now: now) {
            let kept = results.filter { result in
                guard let scope else { return true }
                return (result.date.map(scope.contains) ?? false) || !scope.isDisjoint(with: result.sources)
            }
            let best = kept.first?.score ?? 0
            for result in kept where result.score >= best * Self.relativeFloor {
                // 提到的那天里的命中，交给那天的时间线（见下）。
                if result.category == .daily, let date = result.date, dayNames.contains(date) { continue }
                let text = MemoryHybridText.normalize(result.content)
                guard seenText.insert(text).inserted else { continue }
                let line = Self.format(result)
                let source = MemorySource(
                    category: result.category, file: result.file,
                    section: result.category == .daily || result.section.isEmpty ? nil : result.section, date: result.date
                )
                ranked.append((Candidate(key: "\(result.file)#\(result.content)", line: line, group: .entries, tokens: Self.tokens(line), source: source), result.score))
            }
        }

        // 3. 候选：提到的那几天的时间线，逐条。
        var tiered: [Candidate] = []
        var chronological: [Candidate] = []
        var dayStatus: [(name: String, exists: Bool, allowed: Bool, total: Int)] = []
        if !dayNames.isEmpty {
            if api.access.allows(.daily) {
                for (day, name) in zip(dates.days, dayNames) {
                    guard let timeline = try? api.timeline(on: name) else { continue }
                    let entries = timeline.entries
                    dayStatus.append((name, timeline.exists, true, entries.count))
                    let source = timeline.exists ? Self.source(day: name) : nil
                    if let summary = timeline.summary, !summary.isEmpty {
                        let line = "Summary: " + summary
                        tiered.append(Candidate(key: "day:\(name)#summary", line: line, group: .day(name), tokens: Self.tokens(line), order: -1, source: source))
                    }
                    // 这一天里按问题排出的片段，与检索结果一起按得分排。
                    var scores: [Int: Double] = [:]
                    if entries.count > 1, let hits = try? await api.search(query, limit: Self.searchLimit, now: now, days: day...day) {
                        for hit in hits {
                            let content = MemoryHybridText.normalize(hit.content)
                            guard let index = entries.indices.first(where: { scores[$0] == nil && content.contains(MemoryHybridText.normalize(entries[$0].start + entries[$0].end + entries[$0].title)) }) else { continue }
                            scores[index] = hit.score
                        }
                    }
                    for (index, entry) in entries.enumerated() {
                        let line = Self.format(entry)
                        let candidate = Candidate(key: "day:\(name)#\(entry.start)–\(entry.end) \(entry.title)", line: line, group: .day(name), tokens: Self.tokens(line), order: index, source: source)
                        if let score = scores[index] { ranked.append((candidate, score)) } else { chronological.append(candidate) }
                    }
                    if !timeline.userNotes.isEmpty {
                        let line = "User's own notes: " + timeline.userNotes
                        chronological.append(Candidate(key: "day:\(name)#notes", line: line, group: .day(name), tokens: Self.tokens(line), order: entries.count, source: source))
                    }
                }
            } else {
                notes.append("The question mentions a date, but the user has not allowed the assistant to read daily timelines (Amai Settings → Assistant).")
            }
        }
        var rangeHeader: String?
        if let range = dates.range, api.access.allows(.daily) {
            var day = range.upperBound
            while day >= range.lowerBound, tiered.filter({ $0.group == .range }).count < DateMentions.maxRangeDays {
                let name = MemoryDirectory.dayName(for: day, timeZone: timeZone)
                if let timeline = try? api.timeline(on: name), timeline.exists {
                    let line = Self.brief(timeline)
                    tiered.append(Candidate(key: "range:\(name)", line: line, group: .range, tokens: Self.tokens(line), source: Self.source(day: name)))
                }
                guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
                day = previous
            }
            let from = MemoryDirectory.dayName(for: range.lowerBound, timeZone: timeZone)
            let to = MemoryDirectory.dayName(for: range.upperBound, timeZone: timeZone)
            rangeHeader = "Daily records from \(from) to \(to), newest first:"
        }

        // 4. 按优先级装入预算。
        var used = notes.reduce(0) { $0 + Self.tokens($1) }
        var selected: [Candidate] = []
        var keys = Set<String>()
        var headers = Set<String>()
        func header(for group: Candidate.Group) -> (key: String, tokens: Int) {
            switch group {
            case .entries: ("entries", Self.tokens("Entries found for this question, most relevant first:"))
            case .day(let name): ("day:\(name)", Self.tokens("Timeline for \(name):") + 10)
            case .range: ("range", Self.tokens(rangeHeader ?? ""))
            }
        }
        func take(_ candidate: Candidate) {
            guard !shown.contains(candidate.key), !keys.contains(candidate.key) else { return }
            let h = header(for: candidate.group)
            let cost = candidate.tokens + (headers.contains(h.key) ? 0 : h.tokens)
            guard used + cost <= tokenBudget else { return }
            used += cost
            headers.insert(h.key)
            keys.insert(candidate.key)
            selected.append(candidate)
        }
        tiered.forEach(take)
        ranked.sorted { $0.score > $1.score }.map(\.candidate).forEach(take)
        chronological.forEach(take)

        // 5. 输出。
        var sections: [String] = []
        let entries = selected.filter { $0.group == .entries }
        if !entries.isEmpty {
            sections.append("Entries found for this question, most relevant first:\n" + entries.map(\.line).joined(separator: "\n"))
        }
        for status in dayStatus {
            let mine = selected.filter { $0.group == .day(status.name) }.sorted { $0.order < $1.order }
            if !status.exists || (status.total == 0 && mine.isEmpty) {
                // 没有记录的日子照样说明：模型要知道这一天确实是空的，而不是没去查。
                sections.append("Timeline for \(status.name): no record for this day.")
                continue
            }
            let alreadyShown = shown.filter { $0.hasPrefix("day:\(status.name)#") && $0 != "day:\(status.name)#summary" && $0 != "day:\(status.name)#notes" }.count
            let given = mine.filter { $0.order >= 0 && $0.order < status.total }.count
            let missing = status.total - given - alreadyShown
            guard !mine.isEmpty || missing > 0 else { continue }
            var lines = ["Timeline for \(status.name):"]
            lines += mine.map(\.line)
            if alreadyShown > 0 { lines.append("(\(alreadyShown) entries of this day were shown earlier in this conversation.)") }
            if missing > 0 { lines.append("(\(missing) more entries of this day not shown.)") }
            sections.append(lines.joined(separator: "\n"))
        }
        let rangeLines = selected.filter { $0.group == .range }
        if let rangeHeader {
            sections.append(rangeLines.isEmpty ? rangeHeader.replacingOccurrences(of: ", newest first:", with: ": none.")
                : rangeHeader + "\n" + rangeLines.map(\.line).joined(separator: "\n"))
        }

        var sources: [MemorySource] = []
        for candidate in selected { if let s = candidate.source, !sources.contains(s) { sources.append(s) } }
        guard !sections.isEmpty else {
            // 没有新的内容可放，但仍要把"那天"指的是哪天告诉模型，并让会话记住日期。
            guard !dayNames.isEmpty else { return nil }
            return RecalledMemory(text: notes.joined(separator: "\n"), sources: [], keys: [], days: dayNames)
        }
        return RecalledMemory(text: (notes + sections).joined(separator: "\n\n"), sources: sources, keys: keys, days: dayNames)
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

    /// 时间线中的一个片段：`- 09:00–12:10 标题 — 摘要`。
    static func format(_ entry: TimelineEntry) -> String {
        var line = "- \(entry.start)–\(entry.end) \(entry.title)"
        if !entry.summary.isEmpty { line += " — \(entry.summary)" }
        if entry.lowConfidence { line += " (uncertain)" }
        return line
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

/// 去重与匹配用的归一化：只保留字母与数字，转小写。
enum MemoryHybridText {
    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

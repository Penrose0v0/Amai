import AmaiCore
import AmaiMemory
import Foundation

/// 出题模型。只收到每道题抽样到的那几条证据（已脱敏），不会收到完整的记忆。
public protocol QAQuestionModel: Sendable {
    var identifier: String { get }
    var sendsDataOffDevice: Bool { get }
    func generate(system: String, user: String, schemaJSON: String) async throws -> String
}

/// 一个待出题的槽位：题型、语言、证据都由代码按种子确定，出题模型只负责把它写成自然的问题与标准答案。
public struct QASlot: Codable, Sendable, Equatable {
    public var id: String
    public var type: QAQuestionType
    public var subtype: String
    public var language: String
    public var turns: Int
    public var evidence: [String]
    public var context: [String]
    /// noRecordDate：一个没有 daily 文件的日期。
    public var date: String?
}

/// 各题型的数量。默认合计 100 道（连续追问每轮算一道：6 段 × 3 轮）。
public struct QAQuotas: Codable, Sendable, Equatable {
    public var factDocument = 15
    public var factTimeline = 15
    public var relativeDate = 8
    public var ordering = 7
    public var when = 7
    public var crossLingualEnglish = 8
    public var crossLingualJapanese = 7
    public var followUpConversations = 6
    public var followUpTurns = 3
    public var absentEntity = 9
    public var noRecordDate = 3
    public var falsePremise = 3

    public init() {}

    public var totalQuestions: Int {
        factDocument + factTimeline + relativeDate + ordering + when + crossLingualEnglish + crossLingualJapanese
            + followUpConversations * followUpTurns + absentEntity + noRecordDate + falsePremise
    }

    /// 按比例缩放到大约 `total` 道题（开发时在合成数据上快速跑通用）。每种至少 1 个。
    public static func scaled(to total: Int) -> QAQuotas {
        var q = QAQuotas()
        guard total != q.totalQuestions else { return q }
        let factor = Double(total) / Double(q.totalQuestions)
        func s(_ v: Int) -> Int { max(1, Int((Double(v) * factor).rounded())) }
        q.factDocument = s(q.factDocument); q.factTimeline = s(q.factTimeline)
        q.relativeDate = s(q.relativeDate); q.ordering = s(q.ordering); q.when = s(q.when)
        q.crossLingualEnglish = s(q.crossLingualEnglish); q.crossLingualJapanese = s(q.crossLingualJapanese)
        q.followUpConversations = s(q.followUpConversations)
        q.absentEntity = s(q.absentEntity); q.noRecordDate = s(q.noRecordDate); q.falsePremise = s(q.falsePremise)
        return q
    }
}

// MARK: - Plan

/// 按种子从证据目录中抽样，排出所有槽位。尽量不重复使用同一条证据。
public struct QAPlanner {
    let catalog: EvidenceCatalog
    let now: Date
    let timeZone: TimeZone
    var random: QARandom
    var used = Set<String>()

    public init(catalog: EvidenceCatalog, now: Date, timeZone: TimeZone, seed: UInt64) {
        self.catalog = catalog
        self.now = now
        self.timeZone = timeZone
        self.random = QARandom(seed: seed)
    }

    var documentUnits: [QAEvidence] { catalog.units.filter { $0.category != .daily } }
    var dailyUnits: [QAEvidence] { catalog.units.filter { $0.category == .daily } }
    /// 有确定日期、且不晚于"现在"的条目（时间题用）。
    var datedUnits: [QAEvidence] {
        let today = QADates.dayName(now, timeZone)
        return catalog.units.filter { ($0.date ?? "9") <= today && $0.date != nil }
    }

    /// 只出现一次的事（"什么时候""谁先"的题需要它：反复出现的日常如"健身房跑步"在多天都有，问"哪天"没有唯一答案）。
    /// 按标题（时间线片段 " — " 之前的部分）归一化后的前 12 个字符判断是否重复。出题模型只看到抽样的证据，看不出这一点，所以由本地判断。
    var singularDatedUnits: [QAEvidence] {
        func key(_ unit: QAEvidence) -> String {
            let title = unit.text.components(separatedBy: " — ").first ?? unit.text
            return String(QAText.normalize(title).prefix(12))
        }
        var counts: [String: Int] = [:]
        for unit in catalog.units { counts[key(unit), default: 0] += 1 }
        let singular = datedUnits.filter { counts[key($0)] == 1 }
        return singular.isEmpty ? datedUnits : singular
    }

    /// 从候选里取一条没用过的；都用过了就允许重复。
    mutating func pick(_ pool: [QAEvidence]) -> QAEvidence? {
        let fresh = pool.filter { !used.contains($0.id) }
        guard let chosen = (fresh.isEmpty ? pool : fresh).randomElement(using: &random) else { return nil }
        used.insert(chosen.id)
        return chosen
    }

    public mutating func plan(_ quotas: QAQuotas) -> [QASlot] {
        var slots: [QASlot] = []
        func slot(_ type: QAQuestionType, _ subtype: String, language: String = "zh", turns: Int = 1,
                  evidence: [QAEvidence] = [], context: [QAEvidence] = [], date: String? = nil) {
            slots.append(QASlot(
                id: String(format: "S%03d", slots.count + 1), type: type, subtype: subtype, language: language,
                turns: turns, evidence: evidence.map(\.id), context: context.map(\.id), date: date
            ))
        }
        let anyUnits = catalog.units
        for _ in 0..<quotas.factDocument {
            if let e = pick(documentUnits.isEmpty ? anyUnits : documentUnits) { slot(.fact, "document", evidence: [e]) }
        }
        for _ in 0..<quotas.factTimeline {
            if let e = pick(dailyUnits.isEmpty ? anyUnits : dailyUnits) { slot(.fact, "timeline", evidence: [e]) }
        }
        for _ in 0..<quotas.relativeDate {
            if let e = pick(datedUnits) { slot(.temporal, "relativeDate", evidence: [e]) }
        }
        let singular = singularDatedUnits
        for _ in 0..<quotas.ordering {
            guard let a = pick(singular) else { continue }
            let others = singular.filter { $0.date != a.date }
            guard let b = pick(others) else { continue }
            slot(.temporal, "ordering", evidence: [a, b].sorted { ($0.date ?? "") < ($1.date ?? "") })
        }
        for _ in 0..<quotas.when {
            if let e = pick(singular) { slot(.temporal, "when", evidence: [e]) }
        }
        for _ in 0..<quotas.crossLingualEnglish {
            if let e = pick(anyUnits) { slot(.crossLingual, "english", language: "en", evidence: [e]) }
        }
        for _ in 0..<quotas.crossLingualJapanese {
            if let e = pick(anyUnits) { slot(.crossLingual, "japanese", language: "ja", evidence: [e]) }
        }
        for index in 0..<quotas.followUpConversations {
            // 交替使用同一天的时间线与同一小节的长期记忆。
            let group = index % 2 == 0 ? followUpGroup(byDay: true, size: quotas.followUpTurns)
                : followUpGroup(byDay: false, size: quotas.followUpTurns)
            guard let group = group ?? followUpGroup(byDay: index % 2 != 0, size: quotas.followUpTurns) else { continue }
            slot(.followUp, index % 2 == 0 ? "sameDay" : "sameTopic", turns: quotas.followUpTurns, evidence: group)
        }
        for _ in 0..<quotas.absentEntity {
            let neighbors = [pick(anyUnits), pick(anyUnits)].compactMap { $0 }
            slot(.unanswerable, "absentEntity", context: neighbors)
        }
        for date in noRecordDates(quotas.noRecordDate) {
            slot(.unanswerable, "noRecordDate", evidence: [], date: date)
        }
        for _ in 0..<quotas.falsePremise {
            if let e = pick(anyUnits) { slot(.unanswerable, "falsePremise", context: [e]) }
        }
        return slots
    }

    /// 同一天（或同一小节）里的几条证据，按时间顺序。
    mutating func followUpGroup(byDay: Bool, size: Int) -> [QAEvidence]? {
        let units = byDay ? dailyUnits.filter { $0.kind == .timelineEntry } : documentUnits.filter { $0.kind == .item }
        func grouped(fresh: Bool) -> [String: [QAEvidence]] {
            var result: [String: [QAEvidence]] = [:]
            for unit in units where !fresh || !used.contains(unit.id) {
                result[byDay ? (unit.date ?? "") : "\(unit.file)#\(unit.section ?? "")", default: []].append(unit)
            }
            return result.filter { $0.value.count >= size }
        }
        // 优先用没用过的条目；凑不齐时允许与其他题共用证据。
        var groups = grouped(fresh: true)
        if groups.isEmpty { groups = grouped(fresh: false) }
        let candidates = groups.keys.sorted()
        guard let key = candidates.randomElement(using: &random) else { return nil }
        var members = groups[key]!
        members.shuffle(using: &random)
        let chosen = Array(members.prefix(size)).sorted { ($0.time ?? "") < ($1.time ?? "") }
        used.formUnion(chosen.map(\.id))
        return chosen
    }

    /// 没有 daily 文件的日期：优先取记录范围之内的空档，不够再取记录开始之前的日子。
    mutating func noRecordDates(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        let existing = Set(catalog.days)
        let calendar = QADates.calendar(timeZone)
        let today = calendar.startOfDay(for: now)
        let first = catalog.days.first.flatMap { QADates.parse($0, timeZone) } ?? today
        var gaps: [String] = []
        var day = first
        while day < today {
            let name = QADates.dayName(day, timeZone)
            if !existing.contains(name) { gaps.append(name) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        gaps.shuffle(using: &random)
        var result = Array(gaps.prefix(count))
        var offset = 3
        while result.count < count {
            result.append(QADates.dayName(calendar.date(byAdding: .day, value: -offset, to: first)!, timeZone))
            offset += 9
        }
        return result
    }
}

// MARK: - Dates

/// 日期计算与"相对日期"的说法。说法由代码算好交给出题模型，避免它自己算错。
public enum QADates {
    public static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    public static func dayName(_ date: Date, _ timeZone: TimeZone) -> String {
        MemoryDirectory.dayName(for: date, timeZone: timeZone)
    }

    public static func parse(_ day: String, _ timeZone: TimeZone) -> Date? {
        MemoryDirectory.day(ofDailyFile: "\(MemoryDirectory.dailyDirectory)/\(day).md", timeZone: timeZone)
    }

    static let weekdaysZh = ["日", "一", "二", "三", "四", "五", "六"]
    static let weekdaysEn = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdaysJa = ["日", "月", "火", "水", "木", "金", "土"]

    public static func weekday(_ day: String, _ timeZone: TimeZone) -> String {
        guard let date = parse(day, timeZone) else { return "" }
        return weekdaysEn[calendar(timeZone).component(.weekday, from: date) - 1]
    }

    /// 某一天相对"现在"的几种说法（指定语言）。不在"现在"之前的日子没有相对说法。
    public static func relativeExpressions(for day: String, now: Date, timeZone: TimeZone, language: String) -> [String] {
        let calendar = calendar(timeZone)
        guard let date = parse(day, timeZone) else { return [] }
        let today = calendar.startOfDay(for: now)
        guard let n = calendar.dateComponents([.day], from: date, to: today).day, n >= 1 else { return [] }
        let weekday = calendar.component(.weekday, from: date) - 1
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: thisWeek)!
        var result: [String] = []
        switch language {
        case "en":
            if n == 1 { result.append("yesterday") }
            if n == 2 { result.append("the day before yesterday") }
            result.append("\(n) days ago")
            if date >= thisWeek { result.append("this \(weekdaysEn[weekday])") }
            else if date >= lastWeek { result.append("last \(weekdaysEn[weekday])") }
        case "ja":
            if n == 1 { result.append("昨日") }
            if n == 2 { result.append("一昨日") }
            result.append("\(n)日前")
            if date >= thisWeek { result.append("今週の\(weekdaysJa[weekday])曜日") }
            else if date >= lastWeek { result.append("先週の\(weekdaysJa[weekday])曜日") }
        default:
            if n == 1 { result.append("昨天") }
            if n == 2 { result.append("前天") }
            result.append("\(n) 天前")
            let name = weekday == 0 ? "日" : weekdaysZh[weekday]
            if date >= thisWeek { result.append("这周\(name)") ; result.append("本周\(name)") }
            else if date >= lastWeek { result.append("上周\(name)") }
        }
        return result
    }

    /// 一个日期在指定语言里的写法（给 noRecordDate 题用：问题里必须指明那一天）。
    public static func absoluteExpressions(for day: String, language: String) -> [String] {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return [day] }
        let (m, d) = (parts[1], parts[2])
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        switch language {
        case "en": return [day, "\(months[m - 1]) \(d)"]
        case "ja": return [day, "\(m)月\(d)日"]
        default: return [day, "\(m) 月 \(d) 日", "\(m)月\(d)日", "\(m) 月 \(d) 号", "\(m)月\(d)号"]
        }
    }
}

// MARK: - Generate

/// 把槽位交给出题模型写成题目，并在本地逐条校验；不合格的带上原因重试。
public struct QAGenerator {
    public struct Options: Sendable {
        /// 每次调用最多几个槽位。
        public var batchSize = 6
        /// 同一组证据最多重试几次；仍不合格就换一组证据再试一轮。
        public var retries = 2
        /// 问题与证据原文的最长公共片段不能超过这么多个字符（归一化后），否则视为照抄原文。
        public var maxOverlap = 8
        /// 问题中照抄部分占问题长度的比例上限。
        public var maxOverlapRatio = 0.5

        public init() {}
    }

    public let catalog: EvidenceCatalog
    public let model: any QAQuestionModel
    public let now: Date
    public let timeZone: TimeZone
    public let options: Options

    public init(catalog: EvidenceCatalog, model: any QAQuestionModel, now: Date, timeZone: TimeZone, options: Options = Options()) {
        self.catalog = catalog
        self.model = model
        self.now = now
        self.timeZone = timeZone
        self.options = options
    }

    struct Draft: Equatable {
        var slot: QASlot
        var turns: [(question: String, answer: String, keyPoints: [String])]
        var absentTerms: [String]
        var maxOverlap: Int

        static func == (a: Draft, b: Draft) -> Bool { a.slot == b.slot && a.turns.map(\.question) == b.turns.map(\.question) }
    }

    public struct Output: Sendable {
        public var items: [QAItem]
        public var egress: QAEgress
        public var unfilled: [QASlot]
        /// 被拒绝的草稿按原因计数（不含内容）。
        public var rejections: [String: Int]
    }

    public func run(_ slots: [QASlot], planner: inout QAPlanner, log: (String) -> Void = { _ in }) async -> Output {
        var egress = QAEgress()
        egress.generator = model.identifier
        egress.sendsDataOffDevice = model.sendsDataOffDevice
        egress.evidenceUnitsTotal = catalog.units.count
        var sentUnits = Set<String>()
        var accepted: [String: Draft] = [:]
        var rejections: [String: Int] = [:]
        var pending = slots.map { ($0, [String]()) }
        var resampled = Set<String>()
        var unfilled: [QASlot] = []

        var round = 0
        while !pending.isEmpty {
            round += 1
            var next: [(QASlot, [String])] = []
            for batch in pending.chunked(options.batchSize) {
                let prompt = userPrompt(batch)
                egress.calls += 1
                egress.charactersSent += prompt.text.count + Self.system.count
                egress.redactions += prompt.redactions
                for (slot, _) in batch { sentUnits.formUnion(slot.evidence + slot.context) }
                var replies: [String: Reply] = [:]
                do {
                    let raw = try await model.generate(system: Self.system, user: prompt.text, schemaJSON: Self.schema)
                    replies = Self.parse(raw)
                } catch {
                    log("出题调用失败：\(String(describing: type(of: error)))")
                }
                for (slot, history) in batch {
                    let result = replies[slot.id].map { validate($0, slot: slot) } ?? .rejected("no reply for slot")
                    switch result {
                    case .accepted(let draft):
                        accepted[slot.id] = draft
                    case .rejected(let reason):
                        rejections[Self.reasonKey(reason), default: 0] += 1
                        let attempts = history + [reason]
                        if attempts.count <= options.retries {
                            next.append((slot, attempts))
                        } else if !resampled.contains(slot.id), let fresh = resample(slot, planner: &planner) {
                            resampled.insert(slot.id)
                            next.append((fresh, []))
                        } else {
                            unfilled.append(slot)
                        }
                    }
                }
            }
            log("第 \(round) 轮：已通过 \(accepted.count)/\(slots.count)，待重试 \(next.count)")
            pending = next
        }
        egress.evidenceUnitsSent = sentUnits.count

        // 按原来的槽位顺序编号。
        var items: [QAItem] = []
        var conversation = 0
        for slot in slots {
            guard let draft = accepted[slot.id] else { continue }
            conversation += 1
            for (turn, t) in draft.turns.enumerated() {
                items.append(QAItem(
                    id: String(format: "Q%03d", items.count + 1), conversation: String(format: "C%03d", conversation),
                    turn: turn, type: draft.slot.type, subtype: draft.slot.subtype, language: draft.slot.language,
                    question: t.question, expectedAnswer: t.answer, keyPoints: t.keyPoints,
                    evidence: draft.slot.evidence, context: draft.slot.context, absentTerms: draft.absentTerms,
                    maxOverlap: draft.maxOverlap
                ))
            }
        }
        return Output(items: items, egress: egress, unfilled: unfilled, rejections: rejections)
    }

    /// 换一组证据（类型不变）。
    func resample(_ slot: QASlot, planner: inout QAPlanner) -> QASlot? {
        var quotas = QAQuotas.zero
        switch (slot.type, slot.subtype) {
        case (.fact, "document"): quotas.factDocument = 1
        case (.fact, _): quotas.factTimeline = 1
        case (.temporal, "relativeDate"): quotas.relativeDate = 1
        case (.temporal, "ordering"): quotas.ordering = 1
        case (.temporal, _): quotas.when = 1
        case (.crossLingual, "english"): quotas.crossLingualEnglish = 1
        case (.crossLingual, _): quotas.crossLingualJapanese = 1
        case (.followUp, _): quotas.followUpConversations = 1; quotas.followUpTurns = slot.turns
        case (.unanswerable, "absentEntity"): quotas.absentEntity = 1
        case (.unanswerable, "falsePremise"): quotas.falsePremise = 1
        case (.unanswerable, _): return nil
        }
        guard var fresh = planner.plan(quotas).first else { return nil }
        fresh.id = slot.id
        return fresh
    }

    static func reasonKey(_ reason: String) -> String {
        String(reason.prefix { $0 != ":" })
    }

    // MARK: Prompt

    static let system = """
    You write evaluation questions for a personal AI assistant that answers questions about its user's own past, using the user's memory notes (long-term notes and daily activity timelines inferred from screen activity).

    You receive slots. Each slot gives a question type, a language, and memory evidence. For each slot, write what the user would naturally type to their assistant, plus the reference answer.

    Rules for every question:
    - Write as the user, in first person ("我…", "I…", "私…"), casually, the way a person really asks. The user does not remember the exact wording of their notes.
    - Paraphrase. Do not copy phrases from the evidence: never reuse more than 6 consecutive characters of the evidence text, except short proper names (project, app, person, place names). Ask about the meaning, not the wording.
    - The question must have one clear answer that follows from the evidence alone. No yes/no questions. Do not put the answer in the question.
    - Do not ask about the memory system itself, file names, section names, confidence or timestamps of notes. If the evidence is only about how the notes are kept (for example "Amai does not edit this file"), skip the slot.
    - Write the question in the slot's language. The reference answer is in the same language, short (one or two sentences), and states the date when the evidence has one and it matters.
    - keyPoints: 1–3 short atomic facts a correct answer must contain (for unanswerable slots: the expected behaviour).
    - If the evidence is too vague or trivial to make a good question (for example a bare app name), return the slot with "skip" set to the reason and no turns.

    Per type:
    - fact: a direct question about one fact in the evidence.
    - temporal/relativeDate: refer to the day only by one of the given relative expressions (no absolute date), and ask what the user did or decided then.
    - temporal/ordering: two pieces of evidence on different days; ask which came first, or how many days apart they were. The answer gives both dates.
    - temporal/when: ask when something happened; the answer is the date.
    - crossLingual: the evidence is in another language; ask in the slot's language, translating names of things naturally.
    - followUp: write exactly `turns` turns of one conversation. Turn 1 stands alone. Later turns are short and depend on earlier turns ("那天还做了什么？", "那个后来怎么样了？", "为什么？"), each answerable from the evidence together with the earlier turns. Each turn has its own answer and keyPoints.
    - unanswerable/absentEntity: the evidence shows what the memory contains nearby. Ask a plausible, specific question about something the memory does NOT contain (a different project, person, purchase, trip, number…). Put 1–3 distinctive words of the missing thing in absentTerms (they will be checked against the whole memory and the question rejected if found). The answer says there is no record of it.
    - unanswerable/noRecordDate: there is no record at all for the given date. Ask what the user did on that date, naming the date with one of the given expressions. The answer says there is no record for that day.
    - unanswerable/falsePremise: ask a question that presupposes something the evidence contradicts or does not support (a wrong outcome, a reversed decision, a wrong date). The answer points out the memory does not support the premise and states what it does say. absentTerms may be empty.
    """

    static let schema = """
    {"type":"object","properties":{"questions":{"type":"array","items":{"type":"object","properties":{"slot":{"type":"string"},"skip":{"type":"string"},"absentTerms":{"type":"array","items":{"type":"string"}},"turns":{"type":"array","items":{"type":"object","properties":{"question":{"type":"string"},"answer":{"type":"string"},"keyPoints":{"type":"array","items":{"type":"string"}}},"required":["question","answer","keyPoints"]}}},"required":["slot","turns"]}}},"required":["questions"]}
    """

    static let languageNames = ["zh": "Chinese (Simplified)", "en": "English", "ja": "Japanese"]

    func userPrompt(_ batch: [(QASlot, [String])]) -> (text: String, redactions: Int) {
        let today = QADates.dayName(now, timeZone)
        var lines = [
            "Today is \(today) (\(QADates.weekday(today, timeZone))), time zone \(timeZone.identifier). Weeks start on Monday.",
            "",
        ]
        var redactions = 0
        func evidenceLine(_ id: String) -> String {
            guard let unit = catalog.unit(id) else { return "- (missing)" }
            let redacted = SecretRedactor.redact(unit.labeled)
            redactions += redacted.count
            var line = "- \(redacted.text)"
            if let date = unit.date { line += "  (\(QADates.weekday(date, timeZone)))" }
            return line
        }
        for (slot, history) in batch {
            lines.append("## Slot \(slot.id)")
            lines.append("type: \(slot.type.rawValue)/\(slot.subtype) · language: \(Self.languageNames[slot.language] ?? slot.language) · turns: \(slot.turns)")
            if !slot.evidence.isEmpty {
                lines.append("Evidence:")
                lines += slot.evidence.map(evidenceLine)
            }
            if !slot.context.isEmpty {
                lines.append(slot.type == .unanswerable && slot.subtype == "absentEntity"
                    ? "What the memory contains nearby (do NOT ask about these):" : "Evidence:")
                lines += slot.context.map(evidenceLine)
            }
            if slot.subtype == "relativeDate", let day = catalog.unit(slot.evidence[0])?.date {
                let options = QADates.relativeExpressions(for: day, now: now, timeZone: timeZone, language: slot.language)
                lines.append("Relative expressions for \(day) (use exactly one, verbatim): " + options.map { "\"\($0)\"" }.joined(separator: ", "))
            }
            if slot.subtype == "noRecordDate", let day = slot.date {
                let options = QADates.relativeExpressions(for: day, now: now, timeZone: timeZone, language: slot.language)
                    + QADates.absoluteExpressions(for: day, language: slot.language)
                lines.append("Date with no record: \(day). Name it with one of: " + options.map { "\"\($0)\"" }.joined(separator: ", "))
            }
            if !history.isEmpty {
                lines.append("Your previous attempts for this slot were rejected: " + history.joined(separator: "; ") + ". Fix this.")
            }
            lines.append("")
        }
        lines.append("Return JSON: {\"questions\": [{\"slot\", \"turns\": [{\"question\", \"answer\", \"keyPoints\"}], \"absentTerms\", \"skip\"}]} with one entry per slot.")
        return (lines.joined(separator: "\n"), redactions)
    }

    // MARK: Parse & validate

    enum Validation {
        case accepted(Draft)
        /// 原因会原样发回给出题模型，让它修正。只描述问题，不含记忆内容（"not absent" 会带上模型自己给的词）。
        case rejected(String)
    }

    struct Reply {
        var turns: [(question: String, answer: String, keyPoints: [String])]
        var absentTerms: [String]
        var skip: String?
    }

    static func parse(_ raw: String) -> [String: Reply] {
        guard let object = QAJSON.object(in: raw), let questions = object["questions"] as? [[String: Any]] else { return [:] }
        var result: [String: Reply] = [:]
        for q in questions {
            guard let slot = q["slot"] as? String else { continue }
            let turns = (q["turns"] as? [[String: Any]] ?? []).map { t in
                (
                    question: (t["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    answer: (t["answer"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    keyPoints: (t["keyPoints"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                )
            }
            let skip = (q["skip"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            result[slot] = Reply(turns: turns, absentTerms: q["absentTerms"] as? [String] ?? [], skip: skip)
        }
        return result
    }

    func validate(_ reply: Reply, slot: QASlot) -> Validation {
        if let skip = reply.skip { return .rejected("skipped: \(skip.prefix(80))") }
        guard reply.turns.count == slot.turns else { return .rejected("wrong turn count: expected \(slot.turns), got \(reply.turns.count)") }
        let sources = (slot.evidence + slot.context).compactMap { catalog.unit($0) }.map { QAText.normalize($0.text) }
        var maxOverlap = 0
        for (index, turn) in reply.turns.enumerated() {
            guard !turn.question.isEmpty, !turn.answer.isEmpty, !turn.keyPoints.isEmpty else {
                return .rejected("empty field: turn \(index + 1) needs question, answer and keyPoints")
            }
            let script = QAText.script(of: turn.question)
            guard script == slot.language else {
                return .rejected("wrong language: turn \(index + 1) must be written in \(Self.languageNames[slot.language] ?? slot.language)")
            }
            let question = QAText.normalize(turn.question)
            let overlap = sources.map { QAText.longestCommonSubstring(question, $0) }.max() ?? 0
            maxOverlap = max(maxOverlap, overlap)
            if overlap > options.maxOverlap || (overlap >= 4 && Double(overlap) > Double(question.count) * options.maxOverlapRatio) {
                return .rejected("copied wording: turn \(index + 1) reuses \(overlap) consecutive characters of the evidence; paraphrase more")
            }
        }
        let first = QAText.normalize(reply.turns[0].question)
        if slot.subtype == "relativeDate", let day = catalog.unit(slot.evidence[0])?.date {
            let options = QADates.relativeExpressions(for: day, now: now, timeZone: timeZone, language: slot.language)
            guard options.contains(where: { first.contains(QAText.normalize($0)) }) else {
                return .rejected("missing relative date: use one of the given relative expressions verbatim")
            }
            guard !first.contains(QAText.normalize(day)) else { return .rejected("absolute date given: use only the relative expression") }
        }
        if slot.subtype == "noRecordDate", let day = slot.date {
            let options = QADates.relativeExpressions(for: day, now: now, timeZone: timeZone, language: slot.language)
                + QADates.absoluteExpressions(for: day, language: slot.language)
            guard options.contains(where: { first.contains(QAText.normalize($0)) }) else {
                return .rejected("missing date: name the day with one of the given expressions")
            }
        }
        var absent = reply.absentTerms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if slot.subtype == "absentEntity" {
            guard !absent.isEmpty else { return .rejected("missing absentTerms: list 1-3 distinctive words of the missing thing") }
            if let found = absent.first(where: catalog.mentions) {
                return .rejected("not absent: the memory does mention \"\(found)\"; ask about something else")
            }
        } else if slot.subtype == "falsePremise" {
            // 可以为空；给了就同样要求不在记忆里，否则这个"假前提"可能其实有记录。
            if let found = absent.first(where: catalog.mentions) {
                return .rejected("not absent: the memory does mention \"\(found)\"")
            }
        } else {
            absent = []
        }
        return .accepted(Draft(slot: slot, turns: reply.turns, absentTerms: absent, maxOverlap: maxOverlap))
    }

}

extension QAQuotas {
    static var zero: QAQuotas {
        var q = QAQuotas()
        q.factDocument = 0; q.factTimeline = 0; q.relativeDate = 0; q.ordering = 0; q.when = 0
        q.crossLingualEnglish = 0; q.crossLingualJapanese = 0; q.followUpConversations = 0
        q.absentEntity = 0; q.noRecordDate = 0; q.falsePremise = 0
        return q
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: Swift.max(1, size)).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// 从模型输出里取出 JSON 对象（容忍前后的说明文字与代码块标记）。
enum QAJSON {
    static func object(in raw: String) -> [String: Any]? {
        if let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8))) as? [String: Any]
    }
}

import AmaiCore
import AmaiMemory
import Foundation

/// 记忆整理评测场景（合成数据，不含任何真实个人信息）。
///
/// 每个场景给出若干天的活动片段与用户笔记，以及期望结果：
/// - `routes`：每天应路由到的分区（测召回与多余调用）；
/// - `facts`：应写入某分区的事实（锚点全部出现在同一条有效条目中即视为命中），可附期望的依据类型；
/// - `forbidden`：不应出现的内容（第三方数据、把关注写成诊断、屏幕上的商品价格等）；
/// - `superseded`：跨天变化。旧信息不应再作为有效条目，新信息（如有）应当有效。
public struct EvalScenario: Codable, Sendable {
    public struct Segment: Codable, Sendable {
        public var start: String
        public var end: String
        public var title: String
        public var summary: String?
        public var category: ActivityCategory?
        public var apps: [String]?
        public var confidence: Double?
    }

    public struct Day: Codable, Sendable {
        public var date: String
        public var notes: String?
        public var segments: [Segment]?
        public var routes: [MemoryCategory]?
    }

    public struct Fact: Codable, Sendable {
        public var id: String
        public var category: MemoryCategory
        public var anchors: [String]
        public var kind: MemoryEntryKind?
        /// 期望所在的小节（例如 Work 的项目名）；写进同一分区的其他小节也算错误归属。
        public var section: String?
    }

    public struct Forbidden: Codable, Sendable {
        public var id: String
        /// nil 表示任何分区都不应出现。
        public var category: MemoryCategory?
        public var anchors: [String]
    }

    public struct Superseded: Codable, Sendable {
        public var id: String
        public var category: MemoryCategory
        public var old: [String]
        public var new: [String]?
    }

    public var name: String
    /// 场景开始前已存在的记忆文件（相对记忆根目录）。
    public var files: [String: String]?
    public var days: [Day]
    public var runGeneral: Bool?
    public var facts: [Fact]?
    public var forbidden: [Forbidden]?
    public var superseded: [Superseded]?
    /// Work 中预期的项目数（检查同一项目是否被拆成多个小节）。
    public var expectedWorkProjects: Int?
}

/// 场景中新写入的一条有效记忆，供逐条人工审计（区分正确、事实错误、错误归属、低价值冗余）。
public struct WrittenItem: Codable, Sendable, Equatable {
    public var category: MemoryCategory
    public var section: String?
    public var text: String
    public var kind: MemoryEntryKind
    public var sources: [String]
    /// 命中的期望事实 ID；未命中为 nil（需人工判断）。
    public var matchedFact: String?
}

/// 单个场景的评测结果。
public struct EvalResult: Codable, Sendable {
    public var scenario: String
    public var written: [WrittenItem] = []
    /// 模型输出不是合格 JSON（缺少必需字段）的次数。
    public var malformedOutputs = 0
    /// 模型提出的操作总数与被拒绝原因分布（依据引用质量）。
    public var operationsProposed = 0
    public var rejectionReasons: [String: Int] = [:]
    /// 因失败而重试整理的次数（与正式运行一样，每天最多 3 次）。
    public var retries = 0
    public var routeExpected = 0
    public var routeHit = 0
    public var routeExtra = 0
    public var routingFallbacks = 0
    public var factsExpected = 0
    public var factsFound = 0
    /// 只在错误的分区找到。
    public var factsMisattributed = 0
    public var kindChecked = 0
    public var kindCorrect = 0
    public var forbiddenChecked = 0
    public var forbiddenHits = 0
    public var supersededChecked = 0
    /// 旧信息已不再有效、新信息（如有）有效。
    public var supersededHandled = 0
    /// 旧信息与新信息同时有效。
    public var contradictions = 0
    /// 场景中新写入的有效条目数。
    public var itemsWritten = 0
    public var workProjects: Int?
    public var expectedWorkProjects: Int?
    public var modelCalls = 0
    public var rejectedOperations = 0
    public var errors: [String] = []
    public var notes: [String] = []
}

public struct EvalSummary: Codable, Sendable {
    public var model: String
    public var results: [EvalResult]

    public init(model: String, results: [EvalResult]) {
        self.model = model
        self.results = results
    }

    public var routingRecall: Double { ratio(\.routeHit, \.routeExpected) }
    public var factRecall: Double { ratio(\.factsFound, \.factsExpected) }
    public var omissionRate: Double { 1 - factRecall }
    public var misattributionRate: Double { ratio(\.factsMisattributed, \.factsExpected) }
    public var kindAccuracy: Double { ratio(\.kindCorrect, \.kindChecked) }
    public var falseMemoryRate: Double { ratio(\.forbiddenHits, \.forbiddenChecked) }
    public var supersededHandledRate: Double { ratio(\.supersededHandled, \.supersededChecked) }
    public var contradictions: Int { results.reduce(0) { $0 + $1.contradictions } }
    public var malformedRate: Double {
        let calls = sum(\.modelCalls)
        return calls == 0 ? 0 : Double(sum(\.malformedOutputs)) / Double(calls)
    }
    /// 有效写入中命中期望事实的比例（其余为未标注或错误内容）。
    public var precision: Double {
        let written = results.reduce(0) { $0 + $1.itemsWritten }
        let found = results.reduce(0) { $0 + $1.factsFound }
        return written == 0 ? 1 : min(1, Double(found) / Double(written))
    }

    private func ratio(_ a: KeyPath<EvalResult, Int>, _ b: KeyPath<EvalResult, Int>) -> Double {
        let total = results.reduce(0) { $0 + $1[keyPath: b] }
        return total == 0 ? 1 : Double(results.reduce(0) { $0 + $1[keyPath: a] }) / Double(total)
    }

    public func report() -> String {
        func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
        var lines = [
            "# 记忆整理评测（\(model)）",
            "",
            "| 指标 | 结果 |",
            "|---|---|",
            "| 类别路由召回率 | \(pct(routingRecall))（\(sum(\.routeHit))/\(sum(\.routeExpected))，多余路由 \(sum(\.routeExtra))，兜底 \(sum(\.routingFallbacks))） |",
            "| 事实召回率（1 − 遗漏率） | \(pct(factRecall))（\(sum(\.factsFound))/\(sum(\.factsExpected))） |",
            "| 错误归属 | \(sum(\.factsMisattributed)) 条（\(pct(misattributionRate))） |",
            "| 依据类型正确率 | \(pct(kindAccuracy))（\(sum(\.kindCorrect))/\(sum(\.kindChecked))） |",
            "| 错误记忆（不应出现的内容） | \(sum(\.forbiddenHits))/\(sum(\.forbiddenChecked))（\(pct(falseMemoryRate))） |",
            "| 跨天变化 / 过时信息正确处理 | \(pct(supersededHandledRate))（\(sum(\.supersededHandled))/\(sum(\.supersededChecked))），新旧同时有效 \(contradictions) 处 |",
            "| 有效写入中命中期望事实的比例 | \(pct(precision))（共写入 \(sum(\.itemsWritten)) 条） |",
            "| 模型调用 | \(sum(\.modelCalls)) 次（重试 \(sum(\.retries)) 次） |",
            "| 结构化输出不合格 | \(sum(\.malformedOutputs)) 次（\(pct(malformedRate))） |",
            "| 提出的操作 / 被代码拒绝 | \(sum(\.operationsProposed)) / \(sum(\.rejectedOperations)) |",
            "",
        ]
        var reasons: [String: Int] = [:]
        for r in results { reasons.merge(r.rejectionReasons, uniquingKeysWith: +) }
        if !reasons.isEmpty {
            lines.append("被拒绝原因：" + reasons.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "；"))
            lines.append("")
        }
        for r in results {
            var line = "- \(r.scenario)：路由 \(r.routeHit)/\(r.routeExpected)，事实 \(r.factsFound)/\(r.factsExpected)，错误记忆 \(r.forbiddenHits)，变化处理 \(r.supersededHandled)/\(r.supersededChecked)"
            if let p = r.workProjects, let e = r.expectedWorkProjects { line += "，Work 项目 \(p)（期望 \(e)）" }
            lines.append(line)
            for n in r.notes + r.errors { lines.append("  - \(n)") }
            for w in r.written {
                let tag = w.matchedFact.map { "✓\($0)" } ?? "?"
                lines.append("  - [\(tag)] \(w.category.rawValue)/\(w.section ?? "-")：\(w.text)（\(w.kind.rawValue)）")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func sum(_ k: KeyPath<EvalResult, Int>) -> Int { results.reduce(0) { $0 + $1[keyPath: k] } }
}

/// 在临时记忆目录中按天运行真实的 Consolidator，然后按期望打分。
public enum MemoryEvaluation {
    static let utc = TimeZone(identifier: "UTC")!

    public static func run(_ scenarios: [EvalScenario], model: any MemoryLanguageModel) async -> EvalSummary {
        var results: [EvalResult] = []
        for s in scenarios { results.append(await run(s, model: model)) }
        return EvalSummary(model: model.identifier, results: results)
    }

    public static func run(_ scenario: EvalScenario, model base: any MemoryLanguageModel) async -> EvalResult {
        var result = EvalResult(scenario: scenario.name)
        let model = InstrumentedModel(base)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("amai-eval-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            let memory = root.appendingPathComponent("memory")
            let store = try MemoryStore(root: memory, timeZone: utc)
            for (path, text) in scenario.files ?? [:] {
                try text.write(to: memory.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            let initial = Set(activeItems(memory).map { "\($0.0.rawValue)|\($0.1.text)" })
            let source = ScenarioSource(scenario)
            guard let last = scenario.days.last.flatMap({ day($0.date) }) else { return result }
            let consolidator = Consolidator(
                store: store, source: source, model: model,
                snapshots: SnapshotStore(root: root.appendingPathComponent("snapshots")),
                stateURL: root.appendingPathComponent("consolidation.json"),
                clock: EvalClock(last.addingTimeInterval(86_400 + 5 * 3600)), timeZone: utc
            )
            for d in scenario.days {
                guard let date = day(d.date) else { continue }
                try await store.writeDailyTimeline(day: date, segments: source.segmentsSync(on: date))
                if let notes = d.notes {
                    let path = memory.appendingPathComponent(MemoryDirectory.dailyFile(for: date, timeZone: utc))
                    let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? "# \(d.date)\n"
                    try (existing + "\n## 我的笔记\n\(notes)\n").write(to: path, atomically: true, encoding: .utf8)
                }
                // 与正式运行一样：失败的分区下一次 tick 重试，每天最多 3 次。
                var attempt = 0
                while true {
                    attempt += 1
                    do {
                        let report = try await consolidator.consolidateDay(date)
                        record(report, day: d, into: &result)
                        break
                    } catch {
                        if attempt >= 3 {
                            // 整天失败：期望的路由全部记为未命中，不让失败抬高召回率。
                            result.routeExpected += d.routes?.count ?? 0
                            result.errors.append("\(d.date)：\(error)")
                            break
                        }
                        result.retries += 1
                    }
                }
            }
            if scenario.runGeneral == true {
                do {
                    _ = try await consolidator.updateGeneral()
                } catch {
                    result.errors.append("General：\(error)")
                }
            }
            result.modelCalls = model.calls
            result.malformedOutputs = model.malformed
            result.operationsProposed = model.operations
            score(scenario, memory: memory, initial: initial, into: &result)
        } catch {
            result.errors.append("场景准备失败：\(error)")
        }
        return result
    }

    static func record(_ report: Consolidator.DayReport, day d: EvalScenario.Day, into result: inout EvalResult) {
        result.rejectedOperations += report.rejected.count
        for r in report.rejected {
            let reason = r.split(separator: "：").last.map(String.init) ?? r
            let key = reason.hasPrefix("新依据") || reason.hasPrefix("依据（") ? "依据弱于已有条目"
                : (reason.hasPrefix("不是用户本人") ? "不是用户本人的数据" : reason)
            result.rejectionReasons[key, default: 0] += 1
        }
        result.notes += report.rejected.map { "\(d.date) 被拒绝：\($0)" }
        if report.routingFallback { result.routingFallbacks += 1 }
        if let expected = d.routes {
            result.routeExpected += expected.count
            result.routeHit += expected.filter(report.routed.contains).count
            result.routeExtra += report.routed.filter { !expected.contains($0) }.count
            let missed = expected.filter { !report.routed.contains($0) }
            if !missed.isEmpty { result.notes.append("\(d.date) 漏路由：\(missed.map(\.rawValue).joined(separator: ","))") }
        }
    }

    // MARK: - Scoring

    static func score(_ scenario: EvalScenario, memory: URL, initial: Set<String>, into result: inout EvalResult) {
        let active = activeItems(memory)
        func matches(_ item: MemoryItem, _ anchors: [String]) -> Bool {
            anchors.allSatisfy { item.text.localizedCaseInsensitiveContains($0) }
        }
        result.written = active.filter { !initial.contains("\($0.0.rawValue)|\($0.1.text)") }.map { c, item in
            WrittenItem(
                category: c, section: item.section, text: item.text, kind: item.kind, sources: item.sources,
                matchedFact: (scenario.facts ?? []).first { $0.category == c && matches(item, $0.anchors) }?.id
            )
        }
        result.itemsWritten = result.written.count
        for fact in scenario.facts ?? [] {
            result.factsExpected += 1
            let inCategory = active.filter { $0.0 == fact.category && matches($0.1, fact.anchors) }
            if let expected = fact.section, !inCategory.isEmpty, !inCategory.contains(where: { $0.1.section == expected }) {
                result.factsMisattributed += 1
                result.notes.append("\(fact.id) 写进了小节 \(inCategory[0].1.section ?? "-")，期望 \(expected)")
            } else if let hit = inCategory.first(where: { fact.section == nil || $0.1.section == fact.section }) {
                result.factsFound += 1
                if let kind = fact.kind {
                    result.kindChecked += 1
                    if hit.1.kind == kind { result.kindCorrect += 1 } else {
                        result.notes.append("\(fact.id) 依据类型为 \(hit.1.kind.rawValue)，期望 \(kind.rawValue)")
                    }
                }
            } else if let elsewhere = active.first(where: { matches($0.1, fact.anchors) }) {
                result.factsMisattributed += 1
                result.notes.append("\(fact.id) 写进了 \(elsewhere.0.rawValue)，期望 \(fact.category.rawValue)")
            } else {
                result.notes.append("\(fact.id) 遗漏")
            }
        }
        for f in scenario.forbidden ?? [] {
            result.forbiddenChecked += 1
            if let hit = active.first(where: { (f.category == nil || $0.0 == f.category) && matches($0.1, f.anchors) }) {
                result.forbiddenHits += 1
                result.notes.append("\(f.id) 不应出现：\(hit.0.rawValue)「\(hit.1.text)」")
            }
        }
        for s in scenario.superseded ?? [] {
            result.supersededChecked += 1
            let oldActive = active.contains { $0.0 == s.category && matches($0.1, s.old) }
            let newActive = s.new.map { n in active.contains { $0.0 == s.category && matches($0.1, n) } } ?? true
            if oldActive && s.new != nil && newActive { result.contradictions += 1 }
            if !oldActive && newActive { result.supersededHandled += 1 } else {
                result.notes.append("\(s.id)：旧信息\(oldActive ? "仍有效" : "已撤下")，新信息\(newActive ? "有效" : "缺失")")
            }
        }
        if let expected = scenario.expectedWorkProjects {
            result.expectedWorkProjects = expected
            result.workProjects = Set(active.filter { $0.0 == .work }.compactMap(\.1.section)).count
        }
    }

    /// 所有分区文件中的有效条目（不含变更记录）。
    static func activeItems(_ memory: URL) -> [(MemoryCategory, MemoryItem)] {
        let library = MemoryLibrary(root: memory, index: nil, timeZone: utc)
        return MemoryCategory.documents.flatMap { c in
            (library.document(c)?.systemItems ?? [])
                .filter { !MemorySchema.isHistory($0.section) }
                .map { (c, $0) }
        }
    }

    static func day(_ name: String) -> Date? {
        MemoryDirectory.day(ofDailyFile: "daily/\(name).md", timeZone: utc)
    }

    public static func load(_ url: URL) throws -> [EvalScenario] {
        try JSONDecoder().decode([EvalScenario].self, from: Data(contentsOf: url))
    }
}

/// 记录调用次数、不合格的结构化输出与提出的操作数。
final class InstrumentedModel: MemoryLanguageModel, @unchecked Sendable {
    let base: any MemoryLanguageModel
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var malformed = 0
    private(set) var operations = 0

    init(_ base: any MemoryLanguageModel) { self.base = base }

    var identifier: String { base.identifier }

    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
        lock.withLock { calls += 1 }
        let text = try await base.complete(system: system, user: user, maxTokens: maxTokens, schema: schema)
        let json = Self.object(text)
        lock.withLock {
            switch schema?.name {
            case "daily_digest":
                if json?["summary"] == nil || json?["routes"] as? [String: Any] == nil { malformed += 1 }
            case "memory_operations":
                if let ops = json?["operations"] as? [Any] { operations += ops.count } else { malformed += 1 }
            default:
                break
            }
        }
        return text
    }

    static func object(_ text: String) -> [String: Any]? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8))) as? [String: Any]
    }
}

/// 把场景转成活动片段与采集元数据观察。
final class ScenarioSource: SegmentSource, @unchecked Sendable {
    private var segmentsByDay: [Date: [ActivitySegment]] = [:]
    private var factsByDay: [Date: [Observation]] = [:]

    init(_ scenario: EvalScenario) {
        for d in scenario.days {
            guard let date = MemoryEvaluation.day(d.date) else { continue }
            var segments: [ActivitySegment] = []
            var facts: [Observation] = []
            for s in d.segments ?? [] {
                guard let start = Self.time(s.start, on: date), let end = Self.time(s.end, on: date), end > start else { continue }
                let obs = (s.apps ?? []).map { app in
                    Observation(
                        timeRange: TimeRange(start: start, end: start.addingTimeInterval(10)), modality: .screen, kind: .fact,
                        content: "", confidence: 1, evidence: [], attributes: ["app": app], provider: "perception"
                    )
                }
                facts += obs
                segments.append(ActivitySegment(
                    timeRange: TimeRange(start: start, end: end), title: s.title, summary: s.summary ?? "",
                    category: s.category ?? .work, apps: s.apps ?? [], observations: obs.map(\.id),
                    confidence: s.confidence ?? 0.85, provider: "eval:scenario", updatedAt: end
                ))
            }
            segmentsByDay[date] = segments
            factsByDay[date] = facts
        }
    }

    func segmentsSync(on day: Date) -> [ActivitySegment] { segmentsByDay[day] ?? [] }

    func daysWithUpdates(after: Date?, endingOn: Date, days: Int) async -> [(day: Date, latestUpdate: Date)] { [] }
    func segments(on day: Date) async -> [ActivitySegment] { segmentsByDay[day] ?? [] }
    func observations(on day: Date) async -> [Observation] { factsByDay[day] ?? [] }

    static func time(_ hhmm: String, on day: Date) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return day.addingTimeInterval(TimeInterval(parts[0] * 3600 + parts[1] * 60))
    }
}

struct EvalClock: AmaiClock {
    let date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
    func monotonicNanoseconds() -> UInt64 { 0 }
}

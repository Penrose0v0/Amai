import AmaiAssistant
import AmaiCore
import AmaiMemory
import Foundation

// 记忆检索的独立评测：不调用回答模型，只看检索给出了什么。
//
// 被测对象都是正式代码，评测不改它们：
// - pipeline：问答实际使用的 `MemoryRecall`（日期规则 + 混合检索 + 按日期筛选 + 去重 + 截断），经 `AssistantSession` 调用，
//   模型换成什么都不回答的占位实现。按对话依次提问，与日常一致；结果是放进提示词的 <memory> 块，按行展开成有序列表。
// - pipeline-8k：同一条管线，记忆预算 8K token。
// - hybrid：`MemoryAPI.search`（关键词 + 向量）取 50 条的排序，与 MemoryRecall 的调用相同。
// - keyword：同一个接口不给向量模型，即没有下载向量模型时的退回路径。
// 优化前（ADR-0011）保存的结果里 hybrid / keyword 的前 6 名是取 6 条那次的结果，之后接取 50 条时的其余结果。

public enum QARetrievalSystem: String, Codable, Sendable, CaseIterable {
    /// 正式配置（默认 4K 预算）。
    case pipeline
    /// 同一条管线，8K 预算。
    case pipeline8k = "pipeline-8k"
    case hybrid
    case keyword

    var isPipeline: Bool { self == .pipeline || self == .pipeline8k }
}

/// 优化前（ADR-0011）的固定值：检索结果最多 6 条、整段最多 5000 字符。只用于解读优化前保存的结果。
enum QALegacyRecall {
    static let maxEntries = 6
    static let maxCharacters = 5000
}

/// 检索结果中的一项（pipeline 是 <memory> 块中的一行）。
public struct QARetrievedItem: Codable, Sendable, Equatable {
    public var text: String
    public var file: String?
    public var date: String?
    public var score: Double?
    public var tokens: Int
    /// 这一项对应的证据目录条目（指纹出现在这一项的文字里，且文件 / 日期一致）。
    public var units: [String]
}

public struct QARetrievalRun: Codable, Sendable, Equatable {
    public var item: String
    public var system: QARetrievalSystem
    public var query: String
    public var ms: Double
    /// pipeline：截至这一轮（含同一段对话之前各轮）的全部项，之前的轮次在前。其余：这一轮的排序结果。
    public var items: [QARetrievedItem]
    /// pipeline：这一轮新给出的项从第几项开始。
    public var turnStart: Int
    /// pipeline：截至这一轮按日期整天取出的时间线、被 1800 字符上限截断的日子、按日期区间列出的日子。
    public var dayTimelines: [String]
    public var truncatedDays: [String]
    public var rangeDays: [String]
    /// pipeline：这一轮的记忆块超过 5000 字符被截断。
    public var capped: Bool
    /// hybrid / keyword：取 50 条时的前 6 名对应的条目（与正式调用的 6 条比较一致性）。
    public var productionTop: [[String]]?
    /// hybrid / keyword：取 50 条那次调用的耗时（`ms` 是正式条数那次）。只在正式条数少于 50 时有。
    public var deepMs: Double?
    /// pipeline：这一轮"Entries found"里放了几条检索结果。优化前保存的结果没有这一项（当时固定最多 6 条）。
    public var searchItems: Int?

    public init(
        item: String, system: QARetrievalSystem, query: String, ms: Double, items: [QARetrievedItem], turnStart: Int,
        dayTimelines: [String], truncatedDays: [String], rangeDays: [String], capped: Bool, productionTop: [[String]]?,
        deepMs: Double? = nil, searchItems: Int? = nil
    ) {
        self.item = item
        self.system = system
        self.query = query
        self.ms = ms
        self.items = items
        self.turnStart = turnStart
        self.dayTimelines = dayTimelines
        self.truncatedDays = truncatedDays
        self.rangeDays = rangeDays
        self.capped = capped
        self.productionTop = productionTop
        self.deepMs = deepMs
        self.searchItems = searchItems
    }
}

/// 估算 token 数，与 `MemoryChunker.estimatedTokens` 相同：汉字等宽字符每字 1，其余每 4 个字符 1。
public enum QATokens {
    public static func estimate(_ text: String) -> Int {
        var wide = 0, narrow = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 { wide += 1 } else { narrow += 1 }
        }
        return wide + (narrow + 3) / 4
    }
}

// MARK: - Matching

/// 把检索结果对应回证据目录的条目：同一文件（daily 同一天），且条目的指纹出现在结果文字中。
public struct QAUnitMatcher: Sendable {
    let byKey: [String: [QAEvidence]]
    public let units: [String: QAEvidence]

    public init(_ units: [QAEvidence]) {
        var byKey: [String: [QAEvidence]] = [:]
        for unit in units { byKey[Self.key(file: unit.file, date: unit.date, daily: unit.category == .daily), default: []].append(unit) }
        self.byKey = byKey
        self.units = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func key(file: String?, date: String?, daily: Bool) -> String {
        daily ? "daily:\(date ?? "")" : "file:\(file ?? "")"
    }

    public func match(file: String?, date: String?, text: String) -> [String] {
        let daily = file?.hasPrefix(MemoryDirectory.dailyDirectory + "/") ?? (date != nil)
        let candidates = byKey[Self.key(file: file, date: date, daily: daily)] ?? []
        let normalized = QAText.normalize(text)
        return candidates.filter { !$0.fingerprint.isEmpty && normalized.contains($0.fingerprint) }.map(\.id)
    }
}

/// 把 `MemoryRecall` 给出的记忆块按行展开成有序的项，并认出其中按日期取出的整天时间线与截断。
public enum QARecallParser {
    public struct Parsed: Sendable {
        public var items: [QARetrievedItem] = []
        public var dayTimelines: [String] = []
        public var truncatedDays: [String] = []
        public var rangeDays: [String] = []
        public var capped = false
        public var searchItems = 0
    }

    static let datePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}"#)

    static func leadingDate(_ text: Substring) -> String? {
        let s = String(text)
        guard let m = datePattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    public static func parse(_ memory: String, matcher: QAUnitMatcher) -> Parsed {
        var parsed = Parsed()
        var day: String?
        var inRange = false
        var inEntries = false
        func add(_ line: String, file: String?, date: String?) {
            parsed.items.append(QARetrievedItem(
                text: line, file: file, date: date, score: nil, tokens: QATokens.estimate(line),
                units: matcher.match(file: file, date: date, text: line)
            ))
        }
        let lines = memory.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("Entries found") { day = nil; inRange = false; inEntries = true; continue }
            if line.hasPrefix("Daily records from") {
                day = nil
                inRange = true
                inEntries = false
                continue
            }
            if line.hasPrefix("Timeline for "), let date = leadingDate(line.dropFirst("Timeline for ".count)) {
                day = date
                inRange = false
                inEntries = false
                parsed.dayTimelines.append(date)
                continue
            }
            if line.hasPrefix("\"That day\"") || line.hasPrefix("The question mentions") { continue }
            // 预算装不下时 MemoryRecall 注明"还有几条没放"；之前给过的也注明。这两行都不是记忆内容。
            if line.hasPrefix("("), line.contains("entries of this day") {
                if let day, line.contains("not shown") { parsed.truncatedDays.append(day) }
                continue
            }
            let truncated = line.hasSuffix(" […]")
            if line.hasPrefix("- [") {
                day = nil
                inRange = false
                if inEntries { parsed.searchItems += 1 }
                guard let close = line.firstIndex(of: "]") else { add(line, file: nil, date: nil); continue }
                let label = line[line.index(line.startIndex, offsetBy: 3)..<close]
                if label.hasPrefix("timeline") {
                    let date = leadingDate(label.dropFirst("timeline ".count))
                    add(line, file: date.map { "\(MemoryDirectory.dailyDirectory)/\($0).md" }, date: date)
                } else {
                    let name = label.prefix { $0 != " " && $0 != "," }
                    let category = MemoryCategory(rawValue: String(name))
                    let date = label.split(separator: ",").last.flatMap { leadingDate($0.drop { $0 == " " }) }
                    add(line, file: category?.file, date: date)
                }
            } else if inRange, line.hasPrefix("- "), let date = leadingDate(line.dropFirst(2)) {
                parsed.rangeDays.append(date)
                add(line, file: "\(MemoryDirectory.dailyDirectory)/\(date).md", date: date)
            } else if let day {
                add(line, file: "\(MemoryDirectory.dailyDirectory)/\(day).md", date: day)
                if truncated, index == lines.count - 1 || lines[index + 1].hasPrefix("Timeline for ") || lines[index + 1].hasPrefix("Daily records") || lines[index + 1].hasPrefix("Entries found") {
                    parsed.truncatedDays.append(day)
                }
            } else {
                add(line, file: nil, date: nil)
            }
        }
        // 整个块超过上限时末尾也是 " […]"；最后一个整天时间线的截断与它无法区分，两者都记。
        parsed.capped = memory.count >= QALegacyRecall.maxCharacters && memory.hasSuffix(" […]")
        return parsed
    }
}

// MARK: - Run

/// 什么都不回答的占位模型：评测只需要会话在调用模型之前组装好的记忆。
public struct QASilentModel: ChatModel {
    public let identifier = "eval:silent"
    public let sendsDataOffDevice = false
    public let supportsImages = false
    public let supportsTools = false

    public init() {}

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(ChatUsage()))
            continuation.finish()
        }
    }
}

public struct QARetrievalRunner {
    public let dataset: QADataset
    public let matcher: QAUnitMatcher
    /// 正式配置：可读分区与向量模型（有的话）。
    public let hybrid: MemoryAPI
    /// 同样的分区，不给向量模型。
    public let keyword: MemoryAPI
    public let builder: ContextBuilder
    public static let depth = 50

    public init(dataset: QADataset, matcher: QAUnitMatcher, hybrid: MemoryAPI, keyword: MemoryAPI, builder: ContextBuilder) {
        self.dataset = dataset
        self.matcher = matcher
        self.hybrid = hybrid
        self.keyword = keyword
        self.builder = builder
    }

    /// 与 `MemoryRecall.format` 相同的写法（那个函数不公开），用于估算放进提示词时的 token 数。
    static func line(_ r: MemorySearchResult) -> String {
        var label: String
        if r.category == .daily {
            label = "timeline" + (r.date.map { " \($0)" } ?? "")
        } else {
            label = r.category.rawValue
            if !r.section.isEmpty { label += " › \(r.section)" }
            if let date = r.date { label += ", \(date)" }
        }
        return "- [\(label)] " + r.content.replacingOccurrences(of: "\n", with: " ")
    }

    /// 与 `MemoryRecall` 相同的查询写法：追问很短（少于 24 个字符）时带上上一个问题。
    static func query(_ question: String, previous: String?) -> String {
        if let previous, question.count < 24 { return previous + "\n" + question }
        return question
    }

    public func run(log: (String) -> Void = { _ in }) async throws -> [QARetrievalRun] {
        await hybrid.prepareSearch()
        await keyword.prepareSearch()
        // 预热：第一次查询会加载向量模型、建立数据库连接，不计入延迟。
        _ = try? await hybrid.search("warm up", limit: 6, now: dataset.now)
        _ = try? await keyword.search("warm up", limit: 6, now: dataset.now)

        func session(_ budget: Int) -> AssistantSession {
            var configuration = AssistantSession.Configuration()
            configuration.memoryTokenBudget = budget
            return AssistantSession(
                model: QASilentModel(), memory: hybrid, live: nil, builder: builder, configuration: configuration,
                clock: QAFixedClock(date: dataset.now)
            )
        }
        let pipelines: [(QARetrievalSystem, AssistantSession)] = [(.pipeline, session(MemoryRecall.defaultTokenBudget)), (.pipeline8k, session(8192))]
        var runs: [QARetrievalRun] = []
        for (index, conversation) in dataset.conversations.enumerated() {
            var cumulative: [QARetrievalSystem: QARecallParser.Parsed] = [:]
            for (_, session) in pipelines { await session.reset() }
            var previous: String?
            for item in conversation {
                for (system, session) in pipelines {
                    for try await _ in session.send(item.question) {}
                    let timings = await session.lastTimings
                    let prompt = await session.transcript.last { $0.role == .user }?.text ?? ""
                    let parsed = QARecallParser.parse(QARunner.memoryBlock(in: prompt), matcher: matcher)
                    var total = cumulative[system] ?? QARecallParser.Parsed()
                    let start = total.items.count
                    total.items += parsed.items
                    total.dayTimelines += parsed.dayTimelines
                    total.truncatedDays += parsed.truncatedDays
                    total.rangeDays += parsed.rangeDays
                    cumulative[system] = total
                    runs.append(QARetrievalRun(
                        item: item.id, system: system, query: item.question, ms: Double(timings.memoryMs),
                        items: total.items, turnStart: start, dayTimelines: total.dayTimelines,
                        truncatedDays: total.truncatedDays, rangeDays: total.rangeDays, capped: parsed.capped,
                        productionTop: nil, searchItems: parsed.searchItems
                    ))
                }

                // hybrid / keyword
                let query = Self.query(item.question, previous: previous)
                for (system, api) in [(QARetrievalSystem.hybrid, hybrid), (.keyword, keyword)] {
                    // 与 MemoryRecall 相同的条数（50）：延迟与排序都与正式调用一致。
                    let started = DispatchTime.now().uptimeNanoseconds
                    let results = (try? await api.search(query, limit: MemoryRecall.searchLimit, now: dataset.now)) ?? []
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                    runs.append(QARetrievalRun(
                        item: item.id, system: system, query: query, ms: ms,
                        items: results.prefix(Self.depth).map { r in
                            let line = Self.line(r)
                            let date = r.category == .daily ? r.date : nil
                            return QARetrievedItem(
                                text: line, file: r.file, date: date, score: r.score, tokens: QATokens.estimate(line),
                                units: matcher.match(file: r.file, date: date, text: r.content)
                            )
                        },
                        turnStart: 0, dayTimelines: [], truncatedDays: [], rangeDays: [], capped: false, productionTop: nil
                    ))
                }
                previous = item.question
            }
            log("对话 \(index + 1)/\(dataset.conversations.count)")
        }
        return runs
    }
}

// MARK: - Ground truth

/// 检索的标准证据。每道可回答的题由若干"必需的信息点"组成；一个信息点可以由几条记录中的任意一条提供
/// （同一件事在 work.md 与当天的时间线里都有记录时，两条都标在同一个信息点下）。
public struct QAGroundTruth: Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// 人工标注（`gt-import` 导入）。
        case human
        /// 临时：出题时代码抽样的种子证据，每条一个信息点，没有替代记录；追问题不适用。未经人工确认。
        case provisionalSeed
    }

    public struct Unit: Codable, Sendable, Equatable {
        public var id: String
        public var file: String
        public var date: String?
        public var fingerprint: String
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var requirements: [[Unit]]
        /// 不参与评测的原因（题目有歧义、记忆里其实没有答案等）。
        public var excluded: String?
        public var note: String?
    }

    public var version = 1
    public var source: Source
    public var annotator: String?
    public var annotatedAt: Date?
    public var memoryDigest: String
    public var items: [String: Entry]

    public init(source: Source, annotator: String?, annotatedAt: Date?, memoryDigest: String, items: [String: Entry]) {
        self.source = source
        self.annotator = annotator
        self.annotatedAt = annotatedAt
        self.memoryDigest = memoryDigest
        self.items = items
    }

    static func unit(_ e: QAEvidence) -> Unit { Unit(id: e.id, file: e.file, date: e.date, fingerprint: e.fingerprint) }

    public static func provisional(_ dataset: QADataset) -> QAGroundTruth {
        let evidence = Dictionary(dataset.evidence.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [String: Entry] = [:]
        for item in dataset.items where item.isAnswerable {
            if item.type == .followUp {
                items[item.id] = Entry(requirements: [], excluded: "provisional: seed evidence is per conversation, not per turn")
            } else {
                items[item.id] = Entry(requirements: item.evidence.compactMap { evidence[$0] }.map { [unit($0)] }, excluded: nil)
            }
        }
        return QAGroundTruth(source: .provisionalSeed, annotator: nil, annotatedAt: nil, memoryDigest: dataset.memoryDigest, items: items)
    }

    /// 导入人工标注表导出的 JSON。条目必须在证据目录里且指纹一致（保证是同一份记忆副本）。
    public static func importAnnotations(
        _ data: Data, dataset: QADataset, catalog: EvidenceCatalog, annotator: String?, scope: Set<String>? = nil
    ) throws -> (gt: QAGroundTruth, incomplete: [String]) {
        struct Sheet: Decodable {
            struct Item: Decodable {
                var labels: [String: String]?
                var excluded: String?
                var note: String?
                var done: Bool?
            }
            var memoryDigest: String
            var items: [String: Item]
        }
        let sheet = try JSONDecoder().decode(Sheet.self, from: data)
        guard sheet.memoryDigest == dataset.memoryDigest else { throw QAEvalError("标注表对应的记忆副本与数据集不一致") }
        let units = Dictionary(catalog.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [String: Entry] = [:]
        var incomplete: [String] = []
        for item in dataset.items where item.isAnswerable && (scope?.contains(item.id) ?? true) {
            guard let marked = sheet.items[item.id], marked.done == true else { incomplete.append(item.id); continue }
            if let reason = marked.excluded, !reason.isEmpty {
                items[item.id] = Entry(requirements: [], excluded: reason, note: marked.note)
                continue
            }
            var groups: [String: [Unit]] = [:]
            for (id, label) in marked.labels ?? [:] where !label.isEmpty && label != "none" {
                guard let unit = units[id] else { throw QAEvalError("\(item.id)：证据目录里没有条目 \(id)") }
                groups[label, default: []].append(Self.unit(unit))
            }
            guard !groups.isEmpty else { incomplete.append(item.id); continue }
            items[item.id] = Entry(
                requirements: groups.keys.sorted().map { groups[$0]!.sorted { $0.id < $1.id } }, excluded: nil, note: marked.note
            )
        }
        return (QAGroundTruth(source: .human, annotator: annotator, annotatedAt: Date(), memoryDigest: dataset.memoryDigest, items: items), incomplete)
    }
}

public struct QAEvalError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - Metrics

public enum QARetrievalMetrics {
    public static let ks = [1, 3, 6, 10, 20]
    public static let budgets = [4096, 8192]

    /// 一道题在一个系统上的得分。
    public struct Score: Codable, Sendable, Equatable {
        public var item: String
        public var system: QARetrievalSystem
        public var requirements: Int
        /// 每个信息点最早在第几项被满足（1 起），没有满足为 nil。
        public var firstHit: [Int?]
        /// 与任一信息点相关的项的名次。
        public var relevantRanks: [Int]
        public var count: Int
        public var tokens: [Int]
        public var ms: Double

        public func recall(at k: Int) -> Double {
            Double(firstHit.filter { ($0 ?? .max) <= k }.count) / Double(max(requirements, 1))
        }

        public func full(at k: Int) -> Bool { firstHit.allSatisfy { ($0 ?? .max) <= k } }

        public func precision(at k: Int) -> Double { Double(relevantRanks.filter { $0 <= k }.count) / Double(k) }

        /// 二值增益：一项让至少一个信息点首次被满足记 1。理想排序是前 min(K, 信息点数) 项各满足一个。
        public func ndcg(at k: Int) -> Double {
            let firsts = Set(firstHit.compactMap { $0 })
            var dcg = 0.0
            for rank in 1...k where firsts.contains(rank) { dcg += 1 / log2(Double(rank) + 1) }
            let ideal = (1...max(1, min(k, requirements))).reduce(0.0) { $0 + 1 / log2(Double($1) + 1) }
            return dcg / ideal
        }

        /// 按顺序装入，直到下一项会超出预算：这个前缀里有几项、满足了多少信息点。
        public func budgetCutoff(_ budget: Int) -> Int {
            var total = 0
            for (index, t) in tokens.enumerated() {
                if total + t > budget { return index }
                total += t
            }
            return tokens.count
        }

        public func recall(budget: Int) -> Double { recall(at: budgetCutoff(budget)) }
        public func full(budget: Int) -> Bool { full(at: budgetCutoff(budget)) }
        public func tokensUsed(budget: Int) -> Int { tokens.prefix(budgetCutoff(budget)).reduce(0, +) }
        public var totalTokens: Int { tokens.reduce(0, +) }
    }

    public static func score(_ run: QARetrievalRun, entry: QAGroundTruth.Entry) -> Score {
        let requirements = entry.requirements.map { Set($0.map(\.id)) }
        let relevantUnits = requirements.reduce(into: Set<String>()) { $0.formUnion($1) }
        var firstHit = [Int?](repeating: nil, count: requirements.count)
        var relevant: [Int] = []
        for (index, item) in run.items.enumerated() {
            let units = Set(item.units)
            if !units.isDisjoint(with: relevantUnits) { relevant.append(index + 1) }
            for (r, set) in requirements.enumerated() where firstHit[r] == nil && !units.isDisjoint(with: set) {
                firstHit[r] = index + 1
            }
        }
        return Score(
            item: run.item, system: run.system, requirements: requirements.count, firstHit: firstHit,
            relevantRanks: relevant, count: run.items.count, tokens: run.items.map(\.tokens), ms: run.ms
        )
    }

    // MARK: Aggregates (content-free)

    public struct Group: Codable, Sendable, Equatable {
        public var questions: Int
        public var recallAtK: [String: Double]
        public var fullAtK: [String: Double]
        public var precisionAtK: [String: Double]
        public var ndcgAtK: [String: Double]
        /// 全部返回项。
        public var recallAll: Double
        public var fullAll: Double
        public var precisionAll: Double
        public var meanItems: Double
        public var meanTokens: Double
        public var recallAtBudget: [String: Double]
        public var fullAtBudget: [String: Double]
        public var meanTokensAtBudget: [String: Double]
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : (values.reduce(0, +) / Double(values.count) * 1000).rounded() / 1000
    }

    public static func group(_ scores: [Score]) -> Group {
        func perK(_ f: (Score, Int) -> Double) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: ks.map { k in ("@\(k)", mean(scores.map { f($0, k) })) })
        }
        func perBudget(_ f: (Score, Int) -> Double) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: budgets.map { b in ("\(b / 1024)K", mean(scores.map { f($0, b) })) })
        }
        return Group(
            questions: scores.count,
            recallAtK: perK { $0.recall(at: $1) },
            fullAtK: perK { $0.full(at: $1) ? 1 : 0 },
            precisionAtK: perK { $0.precision(at: $1) },
            ndcgAtK: perK { $0.ndcg(at: $1) },
            recallAll: mean(scores.map { $0.recall(at: $0.count) }),
            fullAll: mean(scores.map { $0.full(at: $0.count) ? 1 : 0 }),
            precisionAll: mean(scores.map { $0.count == 0 ? 0 : Double($0.relevantRanks.count) / Double($0.count) }),
            meanItems: mean(scores.map { Double($0.count) }),
            meanTokens: mean(scores.map { Double($0.totalTokens) }),
            recallAtBudget: perBudget { $0.recall(budget: $1) },
            fullAtBudget: perBudget { $0.full(budget: $1) ? 1 : 0 },
            meanTokensAtBudget: perBudget { Double($0.tokensUsed(budget: $1)) }
        )
    }

    /// 无法回答的题上的误检。
    public struct FalseRetrieval: Codable, Sendable, Equatable {
        public var questions: Int
        /// 返回了至少一项（pipeline：往提示词里放了记忆；对 noRecordDate，只算别的日子的内容）。
        public var anyRetrieved: Double
        public var meanItems: Double
        public var meanTokens: Double
        /// hybrid / keyword：第一名的得分。
        public var topScore: QADistribution
    }

    /// 可回答与无法回答的题第一名得分的可分程度（AUROC，0.5 等于分不开）：能否靠一个分数门槛拒绝无关问题。
    public static func auroc(positive: [Double], negative: [Double]) -> Double? {
        guard !positive.isEmpty, !negative.isEmpty else { return nil }
        var wins = 0.0
        for p in positive { for n in negative { wins += p > n ? 1 : (p == n ? 0.5 : 0) } }
        return (wins / Double(positive.count * negative.count) * 1000).rounded() / 1000
    }

    // MARK: Bottlenecks

    public enum Cause: String, Codable, Sendable, CaseIterable {
        /// 问题里写了证据所在的那一天，但没有按日期取出那天的时间线（日期写法没被认出）。
        case dateNotRecognized = "date-not-recognized"
        /// 那天的时间线取出来了，但超过 1800 字符被截断，证据在截断之后。
        case dayTruncated = "day-truncated"
        /// 整个记忆块超过 5000 字符被截断。
        case outputCapped = "output-capped"
        /// 问题限定了日期，证据不在那几天，被筛掉（hybrid 前 24 名里有它）。
        case dateScopeFiltered = "date-scope-filtered"
        /// hybrid 能找到，但排在 pipeline 实际放进去的检索结果条数之后（优化前固定 6 条；之后由预算与相对门槛决定）。
        case rankedOut = "ranked-out"
        /// hybrid 的名次在 pipeline 放进去的条数之内，pipeline 却没有给出（排序不同、去重等）。
        case lostInPipeline = "lost-in-pipeline"
        /// hybrid 前 50 名里都没有。
        case notRetrieved = "not-retrieved"
    }

    /// pipeline 漏掉的一个信息点的原因（按顺序取第一个成立的）。
    public static func cause(
        requirement: [QAGroundTruth.Unit], pipeline: QARetrievalRun, hybrid: QARetrievalRun?, item: QAItem,
        previousQuestions: [String], now: Date, timeZone: TimeZone
    ) -> (cause: Cause, hybridRank: Int?) {
        let ids = Set(requirement.map(\.id))
        let hybridRank = hybrid?.items.firstIndex { !Set($0.units).isDisjoint(with: ids) }.map { $0 + 1 }
        let days = Set(requirement.compactMap { $0.file.hasPrefix(MemoryDirectory.dailyDirectory + "/") ? $0.date : nil })
        let fetched = Set(pipeline.dayTimelines)
        let questions = (previousQuestions + [item.question]).map(QAText.normalize)
        for day in days where !fetched.contains(day) {
            let expressions = QADates.relativeExpressions(for: day, now: now, timeZone: timeZone, language: item.language)
                + QADates.absoluteExpressions(for: day, language: item.language)
            if expressions.contains(where: { e in questions.contains { $0.contains(QAText.normalize(e)) } }) {
                return (.dateNotRecognized, hybridRank)
            }
        }
        if !days.isDisjoint(with: Set(pipeline.truncatedDays)) { return (.dayTruncated, hybridRank) }
        if pipeline.capped { return (.outputCapped, hybridRank) }
        let scope = fetched.union(pipeline.rangeDays)
        if !scope.isEmpty, let rank = hybridRank, rank <= (pipeline.searchItems == nil ? QALegacyRecall.maxEntries * 4 : MemoryRecall.searchLimit),
           days.isEmpty || days.isDisjoint(with: scope) {
            return (.dateScopeFiltered, hybridRank)
        }
        guard let rank = hybridRank else { return (.notRetrieved, nil) }
        return (rank > (pipeline.searchItems ?? QALegacyRecall.maxEntries) ? .rankedOut : .lostInPipeline, rank)
    }
}

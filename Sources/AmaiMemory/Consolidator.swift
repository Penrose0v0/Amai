import AmaiCore
import Foundation

/// 记忆层使用的纯文本模型接口。由 App 适配本地模型（抽取层的 ModelProvider）
/// 或云端 API（AmaiCloud），记忆层不依赖任何具体实现（ADR-0004）。
public protocol MemoryLanguageModel: Sendable {
    /// 例如 `mlx:gemma-4-e4b-it-4bit`、`anthropic:claude-opus-5-5`。写入整理日志。
    var identifier: String { get }
    /// `schema` 非空时，支持结构化输出的实现应保证返回符合该 Schema 的 JSON；
    /// 不支持的实现忽略它，由调用方解析。
    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String
}

/// 输出 JSON Schema（序列化字符串，便于跨并发域传递）。
public struct OutputSchema: Sendable, Equatable {
    public let name: String
    public let json: String

    public init(name: String, json: String) {
        self.name = name
        self.json = json
    }
}

/// 记忆整理（ADR-0003 的机制，ADR-0006 的文件与依据规则）：
/// 1. 日终摘要：daily 的 `amai:digest` 区块，同时给出各分区是否需要更新（类别路由）；
/// 2. 分区整理：只对路由到的 Work / Goals / Health / Finance 调用对应整理器；
/// 3. General：每周根据各分区条目与最近的摘要汇总。
///
/// 模型只提出操作（新增、更新、撤下、合并）并引用依据编号；条目的依据类型、来源日期、
/// 能否覆盖已有事实、分区专属校验与防大量丢失都由代码决定（`CategoryUpdater`）。
/// 只写系统区块，用户手写内容永不覆盖；每次改写前存快照。
public actor Consolidator {
    public static let digestBlock = digestBlock(.zhHans)
    public static let memoryBlock = memoryBlock(.zhHans)

    /// 区块按名称识别，说明文字随记忆语言写出（解析不依赖说明）。
    public static func digestBlock(_ lang: MemoryLanguage) -> SystemBlock {
        SystemBlock(name: "digest", note: lang.pick(
            "由 Amai 每日整理自动生成，区块内的修改会被覆盖",
            "Generated daily by Amai; edits inside this block will be overwritten",
            "Amai が毎日自動生成します。このブロック内の編集は上書きされます"
        ))
    }

    public static func memoryBlock(_ lang: MemoryLanguage) -> SystemBlock {
        SystemBlock(name: "memory", note: lang.pick(
            "由 Amai 根据每日记录自动维护；区块内的修改会在下次整理时被覆盖，需要保留的内容请写在区块外",
            "Maintained by Amai from daily records; edits inside this block are overwritten at the next consolidation, so keep your own notes outside it",
            "Amai が日々の記録から自動で管理します。このブロック内の編集は次回の整理で上書きされるため、残したい内容はブロックの外に書いてください"
        ))
    }

    /// daily 文件中日终摘要所在小节的标题。
    public static func digestHeading(_ lang: MemoryLanguage) -> String {
        lang.pick("## 摘要", "## Summary", "## まとめ")
    }

    public static let allDigestHeadings: Set<String> = Set(MemoryLanguage.allCases.map(digestHeading))
    /// 每天整理的分区。
    public static let dailyCategories: [MemoryCategory] = [.work, .goals, .health, .finance]
    /// 实际整理顺序：领域明确的分区在前，Goals 最后。同一句话只写进先整理的分区（跨分区去重），
    /// 避免健康、财务、项目上的陈述被 Goals 抢先收走。
    static let processingOrder: [MemoryCategory] = [.health, .finance, .work, .goals]

    public struct Options: Sendable {
        /// 本地时间几点之后整理前一天。
        public var dailyHour = 4
        public var maxCatchUpDays = 3
        public var generalInterval: TimeInterval = 7 * 86_400
        /// 首次更新 General 之前至少需要的日终摘要天数。
        public var minDigestsForFirstGeneral = 2
        /// 自动整理时每个小节（Work 为每个项目）的条目上限。不作用于迁移。
        public var maxItemsPerSection = 40
        public var maxNewProjectsPerDay = 3
        /// 一次整理后剩余的已有条目比例不得低于此值（OpenClaw 的 maxPriorEntryLossFraction 思路）。
        public var minRetainedFraction = 0.5
        /// 某个分区整理连续失败这么多次后放弃当天，避免反复调用模型。
        public var maxCategoryAttempts = 3
        /// General 汇总时提供给模型的分区条目总字数上限。
        public var generalContextChars = 14_000
        /// 记忆语言：提示词与写入的文字使用的语言（`setLanguage` 可在运行中切换）。
        public var language: MemoryLanguage = .default

        public init() {}
    }

    public struct Status: Sendable, Equatable {
        public var running = false
        public var lastDailyDay: String?
        public var lastGeneralAt: Date?
        public var lastRunAt: Date?
        public var lastError: String?
        /// 累计写入的分区更新次数。
        public var categoriesWritten = 0

        public init() {}
    }

    public struct DayReport: Sendable, Equatable {
        public var digestWritten = false
        /// 路由到的分区（摘要判断或兜底）。
        public var routed: [MemoryCategory] = []
        /// 摘要没有给出可用的路由结果，按兜底整理全部分区。
        public var routingFallback = false
        public var updated: [MemoryCategory] = []
        /// 路由到但不可能有合格依据（Health / Finance 当天没有用户陈述），未调用模型。
        public var skipped: [MemoryCategory] = []
        public var failed: [MemoryCategory] = []
        /// 被代码拒绝的操作及原因（写入日志，也供评测使用）。
        public var rejected: [String] = []
        public var modelCalls = 0
    }

    public enum ConsolidationError: Error, Equatable, CustomStringConvertible {
        public var description: String {
            switch self {
            case .unparsableModelOutput(let task): String(localized: "模型返回的内容无法解析（\(task)）")
            case .tooMuchLoss(let file): String(localized: "本次整理会删除 \(file) 中过多已有记忆，已拒绝")
            case .categoriesFailed(let list):
                String(localized: "部分分区整理失败（\(list.compactMap { MemoryCategory(rawValue: $0)?.localizedName }.joined(separator: "、"))），稍后重试")
            }
        }

        case unparsableModelOutput(String)
        case tooMuchLoss(String)
        case categoriesFailed([String])
    }

    private struct DayProgress: Codable, Equatable {
        var routes: [String]?
        var done: [String] = []
        var attempts: [String: Int] = [:]
    }

    private struct State: Codable {
        var lastDailyDay: String?
        var lastGeneralAt: Date?
        var progress: [String: DayProgress] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey { case lastDailyDay, lastGeneralAt, lastSummaryAt, progress }

        /// Schema v1 之前写的是 `lastSummaryAt`，读入时沿用，避免升级后立即重跑一次 General。
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastDailyDay = try c.decodeIfPresent(String.self, forKey: .lastDailyDay)
            lastGeneralAt = try c.decodeIfPresent(Date.self, forKey: .lastGeneralAt)
                ?? c.decodeIfPresent(Date.self, forKey: .lastSummaryAt)
            progress = (try? c.decodeIfPresent([String: DayProgress].self, forKey: .progress)) ?? [:]
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(lastDailyDay, forKey: .lastDailyDay)
            try c.encodeIfPresent(lastGeneralAt, forKey: .lastGeneralAt)
            if !progress.isEmpty { try c.encode(progress, forKey: .progress) }
        }
    }

    private let store: MemoryStore
    private let source: any SegmentSource
    private var model: any MemoryLanguageModel
    private let snapshots: SnapshotStore
    private let stateURL: URL
    private let clock: any AmaiClock
    private let timeZone: TimeZone
    private let shouldRun: @Sendable () -> Bool
    private var options: Options
    private var lang: MemoryLanguage { options.language }
    private let log = AmaiLog.logger("memory.consolidate")
    private var state: State
    private var loop: Task<Void, Never>?

    public private(set) var status = Status()

    public init(
        store: MemoryStore,
        source: any SegmentSource,
        model: any MemoryLanguageModel,
        snapshots: SnapshotStore,
        stateURL: URL,
        clock: any AmaiClock = SystemClock(),
        timeZone: TimeZone = .current,
        options: Options = .init(),
        shouldRun: @escaping @Sendable () -> Bool = { true }
    ) {
        self.store = store
        self.source = source
        self.model = model
        self.snapshots = snapshots
        self.stateURL = stateURL
        self.clock = clock
        self.timeZone = timeZone
        self.options = options
        self.shouldRun = shouldRun
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.state = (try? Data(contentsOf: stateURL)).flatMap { try? decoder.decode(State.self, from: $0) } ?? State()
        self.status.lastDailyDay = state.lastDailyDay
        self.status.lastGeneralAt = state.lastGeneralAt
    }

    /// 切换整理模型（设置中修改后立即生效）。
    public func setModel(_ model: any MemoryLanguageModel) {
        self.model = model
    }

    public var modelIdentifier: String { model.identifier }

    /// 切换记忆语言：之后新写入或修改的内容使用新语言，已有内容不翻译。
    public func setLanguage(_ language: MemoryLanguage) {
        options.language = language
    }

    // MARK: - Scheduling

    public func start(interval: TimeInterval = 600) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 补整理已结束但未整理的日子（凌晨 `dailyHour` 点之后才算"昨天已结束"），然后按需更新 General。
    public func tick() async {
        guard !status.running, shouldRun() else { return }
        let now = clock.now()
        let calendar = self.calendar
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return }
        let hour = calendar.component(.hour, from: now)

        var day = state.lastDailyDay.flatMap(date(fromDayName:)).flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? yesterday
        var done = 0
        while day < today, done < options.maxCatchUpDays {
            if day == yesterday && hour < options.dailyHour { break }
            do {
                _ = try await consolidateDay(day)
            } catch {
                return
            }
            done += 1
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        if await generalDue(now: now) {
            _ = try? await updateGeneral()
        }
    }

    private func generalDue(now: Date) async -> Bool {
        if let last = state.lastGeneralAt {
            return now.timeIntervalSince(last) >= options.generalInterval
        }
        return await recentDigests(endingOn: now, days: 7).count >= options.minDigestsForFirstGeneral
    }

    // MARK: - 1 + 2. Daily digest, routing and category updates

    /// 整理某一天：生成日终摘要与类别路由，再整理路由到的分区。可重复调用：
    /// 摘要覆盖系统区块；已完成的分区不重复整理（进度保存在状态文件中），失败的分区下次重试。
    @discardableResult
    public func consolidateDay(_ day: Date) async throws -> DayReport {
        status.running = true
        status.lastRunAt = clock.now()
        defer { status.running = false }
        let dayName = MemoryDirectory.dayName(for: day, timeZone: timeZone)
        let file = MemoryDirectory.dailyFile(for: day, timeZone: timeZone)
        var report = DayReport()

        do {
            let daily = await store.read(file)
            let hasTimeline = daily.flatMap(TimelineBlock.block.content(in:))?.isEmpty == false
            let hasNotes = !EvidenceLedger.userLines(inDaily: daily ?? "").isEmpty
            guard let daily, hasTimeline || hasNotes else {
                // 没有活动记录也没有笔记的日子：直接标记为已整理。
                try markDaily(dayName)
                return report
            }

            let segments = await source.segments(on: day)
            let ledger = EvidenceLedger.forDay(
                day: dayName, daily: daily, segments: segments,
                observations: await source.observations(on: day), timeZone: timeZone, language: lang
            )
            let stats = Self.stats(for: segments)
            var progress = state.progress[dayName] ?? DayProgress()

            // 1. 日终摘要与类别路由（每次都重写摘要；路由只在第一次成功时确定，续跑沿用）。
            let digestRaw = try await model.complete(
                system: Prompts.digestSystem(lang),
                user: Prompts.digestUser(day: dayName, stats: stats, ledger: ledger, language: lang),
                maxTokens: 1200,
                schema: Schemas.digest
            )
            report.modelCalls += 1
            guard let digest = ModelJSON.decode(DigestOutput.self, from: digestRaw) else {
                throw ConsolidationError.unparsableModelOutput("digest")
            }
            let digestBody = Self.renderDigest(stats: stats, digest: digest, timeZone: timeZone, language: lang)
            report.digestWritten = try await store.writeBlock(
                Self.digestBlock(lang), body: digestBody, file: file, newFileTitle: dayName,
                heading: Self.digestHeading(lang), insertBeforeHeading: TimelineBlock.heading(in: daily) ?? TimelineBlock.heading(lang),
                snapshots: snapshots, task: "daily-digest", model: model.identifier, itemCount: digest.highlights?.count ?? 0
            )
            if progress.routes == nil {
                if let routes = digest.routes?.categories {
                    progress.routes = routes.map(\.rawValue)
                } else {
                    // 路由结果缺失或无法解析：宁可多整理（各整理器本身有依据门槛），也不漏掉。
                    progress.routes = Self.dailyCategories.map(\.rawValue)
                    report.routingFallback = true
                    log.info("routing missing, falling back to all categories")
                }
                try saveProgress(progress, for: dayName)
            }
            report.routed = Self.dailyCategories.filter { progress.routes?.contains($0.rawValue) == true }

            // 2. 分区整理
            for category in Self.processingOrder where report.routed.contains(category) && !progress.done.contains(category.rawValue) {
                let policy = CategoryPolicy.policy(for: category, language: lang)
                if !policy.allowsInferred && !ledger.hasUserStatements {
                    report.skipped.append(category)
                    progress.done.append(category.rawValue)
                    try saveProgress(progress, for: dayName)
                    continue
                }
                do {
                    report.modelCalls += 1
                    let outcome = try await updateCategory(category, dayName: dayName, ledger: ledger)
                    report.rejected += outcome.rejected.map { "\(category.rawValue)：\($0)" }
                    if outcome.written { report.updated.append(category) }
                    progress.done.append(category.rawValue)
                } catch {
                    let attempts = (progress.attempts[category.rawValue] ?? 0) + 1
                    progress.attempts[category.rawValue] = attempts
                    log.error("category \(category.rawValue, privacy: .public) failed (\(attempts)): \(String(describing: error), privacy: .public)")
                    if attempts >= options.maxCategoryAttempts {
                        progress.done.append(category.rawValue)
                    }
                    report.failed.append(category)
                }
                try saveProgress(progress, for: dayName)
            }
            status.categoriesWritten += report.updated.count
            for r in report.rejected { log.info("rejected operation: \(r, privacy: .private)") }

            if report.routed.contains(where: { !progress.done.contains($0.rawValue) }) {
                throw ConsolidationError.categoriesFailed(report.failed.map(\.rawValue))
            }
            try markDaily(dayName)
            status.lastError = report.failed.isEmpty ? nil
                : String(localized: "整理 \(dayName) 的\(report.failed.map(\.localizedName).joined(separator: "、"))记忆多次失败，已跳过")
            log.info("daily consolidated: digest=\(report.digestWritten) routed=\(report.routed.count) updated=\(report.updated.count) rejected=\(report.rejected.count)")
            return report
        } catch {
            status.lastError = String(localized: "整理 \(dayName) 失败：\(String(describing: error))")
            log.error("daily consolidation failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    struct CategoryOutcome {
        var written = false
        var rejected: [String] = []
    }

    /// 整理一个分区：把当天依据、分区手写内容（U）与已有条目交给模型，按代码规则应用返回的操作。
    private func updateCategory(_ category: MemoryCategory, dayName: String, ledger base: EvidenceLedger) async throws -> CategoryOutcome {
        let path = category.file!
        let policy = CategoryPolicy.policy(for: category, language: lang)
        let text = await store.read(path)
        let body = text.flatMap(Self.memoryBlock.content(in:)) ?? ""
        let all = MemoryItems.parse(body)
        var meta = Dictionary(MemoryItems.sections(body).map { ($0.name, $0.meta) }, uniquingKeysWith: { a, _ in a })
        let (items, history) = CategoryUpdater.split(all)
        if policy.sections == nil { meta = CategoryUpdater.ensureProjectIDs(items, meta: meta) }

        var ledger = base
        for line in EvidenceLedger.contentLines(text.map { Self.memoryBlock.removing(from: $0) } ?? "") {
            ledger.append(.userStatement, prefix: "U", day: dayName, text: line)
        }
        let raw = try await model.complete(
            system: Prompts.categorySystem(policy),
            user: Prompts.categoryUser(day: dayName, ledger: ledger, items: items, history: history, projects: policy.sections == nil ? meta : nil, language: lang),
            maxTokens: 2400,
            schema: Schemas.operations
        )
        guard let output = ModelJSON.decode(OperationsOutput.self, from: raw) else {
            throw ConsolidationError.unparsableModelOutput(category.rawValue)
        }
        var updater = CategoryUpdater(policy: policy, ledger: ledger, day: dayName)
        updater.maxItemsPerSection = options.maxItemsPerSection
        updater.maxNewProjects = options.maxNewProjectsPerDay
        for other in Self.dailyCategories where other != category {
            guard let t = await store.read(other.file!), let b = Self.memoryBlock.content(in: t) else { continue }
            updater.otherCategories += CategoryUpdater.split(MemoryItems.parse(b)).items.map { (other, $0.text) }
        }
        updater.minRetainedFraction = options.minRetainedFraction
        let result = updater.apply(output.operations ?? [], to: all, sectionMeta: meta)
        var outcome = CategoryOutcome(rejected: result.rejected)
        guard result.changed else { return outcome }
        outcome.written = try await store.writeBlock(
            Self.memoryBlock(lang), body: Self.renderCategory(result.items, policy: policy, meta: result.sectionMeta),
            file: path, newFileTitle: MemorySchema.title(for: category, language: lang), heading: MemorySchema.blockHeading(lang),
            snapshots: snapshots, task: category.rawValue, model: model.identifier, itemCount: result.items.count
        )
        return outcome
    }

    /// 小节顺序：推荐小节 → 其他已有小节（迁移来的、Work 的项目）→ 变更记录。
    /// 推荐小节与变更记录的标题换成当前记忆语言（任一语言的写法都认得），条目文字不变。
    static func renderCategory(_ items: [MemoryItem], policy: CategoryPolicy, meta: [String: [String: String]]) -> String {
        let other = MemorySchema.localizedSection("其他", in: MemorySchema.generalSectionList, to: policy.language)
        let normalized = items.map { item -> MemoryItem in
            var item = item
            item.section = policy.localize(item.section ?? other)
            return item
        }
        var order = policy.sections ?? []
        for s in normalized.compactMap(\.section) where !order.contains(s) && !MemorySchema.isHistory(s) {
            order.append(s)
        }
        order.append(policy.historySection)
        return MemoryItems.render(normalized, sections: order, sectionMeta: meta)
    }

    // MARK: - 3. general.md

    /// 用各分区条目（带依据类型）与最近 7 天的日终摘要更新 general.md 的系统区块。
    @discardableResult
    public func updateGeneral() async throws -> Bool {
        status.running = true
        status.lastRunAt = clock.now()
        defer { status.running = false }
        let path = MemoryCategory.general.file!
        do {
            let now = clock.now()
            let today = MemoryDirectory.dayName(for: now, timeZone: timeZone)
            let digests = await recentDigests(endingOn: now, days: 7)
            guard !digests.isEmpty else { return false }

            var ledger = EvidenceLedger()
            for d in digests {
                ledger.append(.digest, day: d.day, text: String(d.text.replacingOccurrences(of: "\n", with: " ").prefix(600)))
            }
            ledger = await addCategoryEvidence(to: ledger, today: today)
            let current = await store.read(path)
            for line in EvidenceLedger.contentLines(current.map { Self.memoryBlock.removing(from: $0) } ?? "") {
                ledger.append(.userStatement, prefix: "U", day: today, text: line)
            }
            let body = current.flatMap(Self.memoryBlock.content(in:)) ?? ""
            let all = MemoryItems.parse(body)
            let (items, history) = CategoryUpdater.split(all)
            let policy = CategoryPolicy.policy(for: .general, language: lang)

            let raw = try await model.complete(
                system: Prompts.categorySystem(policy),
                user: Prompts.categoryUser(day: today, ledger: ledger, items: items, history: history, projects: nil, language: lang),
                maxTokens: 3000,
                schema: Schemas.operations
            )
            guard let output = ModelJSON.decode(OperationsOutput.self, from: raw) else {
                throw ConsolidationError.unparsableModelOutput("general")
            }
            var updater = CategoryUpdater(policy: policy, ledger: ledger, day: today)
            updater.maxItemsPerSection = options.maxItemsPerSection
            updater.minRetainedFraction = options.minRetainedFraction
            let result = updater.apply(output.operations ?? [], to: all, sectionMeta: [:])
            if result.lossGuardTripped { throw ConsolidationError.tooMuchLoss(path) }
            for r in result.rejected { log.info("general rejected: \(r, privacy: .private)") }
            var changed = false
            if result.changed {
                changed = try await store.writeBlock(
                    Self.memoryBlock(lang), body: Self.renderCategory(result.items, policy: policy, meta: [:]),
                    file: path, newFileTitle: MemorySchema.title(for: .general, language: lang), heading: MemorySchema.blockHeading(lang),
                    snapshots: snapshots, task: "general", model: model.identifier, itemCount: result.items.count
                )
            }
            state.lastGeneralAt = now
            try saveState()
            status.lastGeneralAt = now
            status.lastError = nil
            return changed
        } catch {
            status.lastError = String(localized: "更新综合档案失败：\(String(describing: error))")
            log.error("general update failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// 把各分区条目作为 M 依据加入清单。超出字数预算时按"依据更强、来源更新"排序选取，
    /// 而不是按文件顺序截取前几条；每个分区先保底几条，避免条目多的分区占满预算。
    private func addCategoryEvidence(to base: EvidenceLedger, today: String) async -> EvidenceLedger {
        var ledger = base
        struct Candidate: Equatable { let category: MemoryCategory; let item: MemoryItem }
        var candidates: [Candidate] = []
        for category in Self.dailyCategories {
            guard let text = await store.read(category.file!), let body = Self.memoryBlock.content(in: text) else { continue }
            candidates += CategoryUpdater.split(MemoryItems.parse(body)).items.map { Candidate(category: category, item: $0) }
        }
        let ranked = candidates.sorted {
            ($0.item.kind.rank, $0.item.sources.max() ?? "") > ($1.item.kind.rank, $1.item.sources.max() ?? "")
        }
        var chosen: [Candidate] = []
        for category in Self.dailyCategories {
            chosen += ranked.filter { $0.category == category }.prefix(5)
        }
        var used = chosen.reduce(0) { $0 + $1.item.text.count }
        for c in ranked where !chosen.contains(c) {
            guard used + c.item.text.count <= options.generalContextChars else { continue }
            chosen.append(c)
            used += c.item.text.count
        }
        let prefixes: [MemoryCategory: String] = [.work: "MW", .goals: "MG", .health: "MH", .finance: "MF"]
        for category in Self.dailyCategories {
            for c in chosen where c.category == category {
                let name = MemorySchema.title(for: category, language: lang)
                let label = c.item.section.map { "[\(name)·\($0)] " } ?? "[\(name)] "
                ledger.append(
                    .memory, prefix: prefixes[category], day: c.item.sources.max() ?? today, text: label + c.item.text,
                    memoryKind: c.item.kind, sourceDays: c.item.sources
                )
            }
        }
        return ledger
    }

    // MARK: - Helpers

    private func recentDigests(endingOn date: Date, days: Int) async -> [(day: String, text: String)] {
        var result: [(String, String)] = []
        for offset in (0..<days).reversed() {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            let file = MemoryDirectory.dailyFile(for: d, timeZone: timeZone)
            if let text = await store.read(file), let digest = Self.digestBlock.content(in: text), !digest.isEmpty {
                result.append((MemoryDirectory.dayName(for: d, timeZone: timeZone), digest))
            }
        }
        return result
    }

    private func saveProgress(_ progress: DayProgress, for dayName: String) throws {
        state.progress[dayName] = progress
        try saveState()
    }

    /// 只把已经结束的日子记为已整理；手动整理今天不影响日终的正式整理（也不保留今天的路由与进度）。
    private func markDaily(_ dayName: String) throws {
        state.progress.removeValue(forKey: dayName)
        let today = MemoryDirectory.dayName(for: clock.now(), timeZone: timeZone)
        if dayName < today, state.lastDailyDay.map({ $0 < dayName }) ?? true {
            state.lastDailyDay = dayName
        }
        try saveState()
        status.lastDailyDay = state.lastDailyDay
    }

    private func saveState() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    private func date(fromDayName name: String) -> Date? {
        MemoryDirectory.day(ofDailyFile: "\(MemoryDirectory.dailyDirectory)/\(name).md", timeZone: timeZone)
    }

    static func titleFromPath(_ path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    /// 项目名会成为 Markdown 小节标题：去掉换行、标题符号与注释符号，限制长度。
    static func projectName(_ raw: String) -> String? {
        let name = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#")))
        guard !name.isEmpty, !MemorySchema.isHistory(name) else { return nil }
        return String(name.prefix(40))
    }

    // MARK: - Digest

    struct DayStats: Equatable {
        var activeMinutes = 0
        var byCategory: [(ActivityCategory, Int)] = []
        var first: Date?
        var last: Date?

        static func == (a: DayStats, b: DayStats) -> Bool {
            a.activeMinutes == b.activeMinutes && a.first == b.first && a.last == b.last
                && a.byCategory.map(\.0) == b.byCategory.map(\.0) && a.byCategory.map(\.1) == b.byCategory.map(\.1)
        }
    }

    static func stats(for segments: [ActivitySegment]) -> DayStats {
        let active = segments.filter(TimelineBlock.includes)
        var stats = DayStats()
        var minutes: [ActivityCategory: Int] = [:]
        for s in active {
            let m = Int((s.timeRange.duration / 60).rounded())
            stats.activeMinutes += m
            minutes[s.category, default: 0] += m
        }
        stats.byCategory = minutes.sorted { $0.value > $1.value }
        stats.first = active.map(\.timeRange.start).min()
        stats.last = active.map(\.timeRange.end).max()
        return stats
    }

    struct DigestOutput: Decodable {
        let summary: String?
        let highlights: [String]?
        let routes: Routes?

        private enum CodingKeys: String, CodingKey { case summary, highlights, routes }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = try? c.decodeIfPresent(String.self, forKey: .summary)
            highlights = try? c.decodeIfPresent([String].self, forKey: .highlights)
            // 路由格式不对不影响摘要本身，由调用方兜底。
            routes = try? c.decodeIfPresent(Routes.self, forKey: .routes)
        }
    }

    /// 类别路由：四个分区逐一给出判断。任一分区缺失或无法解析时视为整体无效，由调用方兜底。
    struct Routes: Decodable {
        struct Route: Decodable {
            let update: Bool

            private enum CodingKeys: String, CodingKey { case update }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let b = try? c.decode(Bool.self, forKey: .update) {
                    update = b
                    return
                }
                let s = try c.decode(String.self, forKey: .update).lowercased()
                guard ["true", "false", "yes", "no"].contains(s) else {
                    throw DecodingError.dataCorruptedError(forKey: .update, in: c, debugDescription: "not a boolean")
                }
                update = s == "true" || s == "yes"
            }
        }
        let work: Route?
        let health: Route?
        let finance: Route?
        let goals: Route?

        var categories: [MemoryCategory]? {
            guard let work, let health, let finance, let goals else { return nil }
            return [(MemoryCategory.work, work), (.goals, goals), (.health, health), (.finance, finance)]
                .filter { $0.1.update }.map(\.0)
        }

        private enum CodingKeys: String, CodingKey { case work, health, finance, goals }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            work = try? c.decodeIfPresent(Route.self, forKey: .work)
            health = try? c.decodeIfPresent(Route.self, forKey: .health)
            finance = try? c.decodeIfPresent(Route.self, forKey: .finance)
            goals = try? c.decodeIfPresent(Route.self, forKey: .goals)
        }
    }

    struct OperationsOutput: Decodable {
        let operations: [MemoryOperation]?
    }

    static func statsLine(_ stats: DayStats, timeZone: TimeZone, language lang: MemoryLanguage = .zhHans) -> String {
        guard stats.activeMinutes > 0 else { return "" }
        let cats = stats.byCategory.prefix(4).map { "\(categoryLabel($0.0, lang)) \(hm($0.1, lang))" }.joined(separator: " · ")
        var line = lang.pick("活跃 \(hm(stats.activeMinutes, lang))（\(cats)）", "Active \(hm(stats.activeMinutes, lang)) (\(cats))", "アクティブ \(hm(stats.activeMinutes, lang))（\(cats)）")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let first = stats.first, let last = stats.last {
            let f = calendar.dateComponents([.hour, .minute], from: first)
            let l = calendar.dateComponents([.hour, .minute], from: last)
            line += String(format: lang.pick("，%02d:%02d–%02d:%02d", ", %02d:%02d–%02d:%02d", "、%02d:%02d–%02d:%02d"), f.hour ?? 0, f.minute ?? 0, l.hour ?? 0, l.minute ?? 0)
        }
        return line + lang.pick("。", ".", "。")
    }

    nonisolated static func renderDigest(stats: DayStats, digest: DigestOutput, timeZone: TimeZone = .current, language: MemoryLanguage = .zhHans) -> String {
        var parts: [String] = []
        let line = statsLine(stats, timeZone: timeZone, language: language)
        if !line.isEmpty { parts.append(line) }
        if let summary = digest.summary.map(clean), !summary.isEmpty { parts.append(summary) }
        let highlights = (digest.highlights ?? []).map(clean).filter { !$0.isEmpty }.prefix(6)
        if !highlights.isEmpty { parts.append(highlights.map { "- \($0)" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    private nonisolated static func clean(_ s: String) -> String {
        SecretRedactor.redact(
            s.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "<!--", with: "")
                .replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespaces)
        ).text
    }

    private nonisolated static func hm(_ minutes: Int, _ lang: MemoryLanguage) -> String {
        minutes >= 60
            ? lang.pick("\(minutes / 60) 小时 \(minutes % 60) 分", "\(minutes / 60) h \(minutes % 60) min", "\(minutes / 60) 時間 \(minutes % 60) 分")
            : lang.pick("\(minutes) 分", "\(minutes) min", "\(minutes) 分")
    }

    nonisolated static func categoryLabel(_ c: ActivityCategory, _ lang: MemoryLanguage = .zhHans) -> String {
        switch c {
        case .work: lang.pick("工作", "work", "仕事")
        case .research: lang.pick("研究", "research", "調査")
        case .communication: lang.pick("沟通", "communication", "連絡")
        case .reading: lang.pick("阅读", "reading", "読書")
        case .entertainment: lang.pick("娱乐", "entertainment", "娯楽")
        case .idle: lang.pick("空闲", "idle", "離席")
        case .other: lang.pick("其他", "other", "その他")
        }
    }
}

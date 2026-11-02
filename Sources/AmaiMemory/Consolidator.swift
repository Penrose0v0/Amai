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

/// 记忆整理（ADR-0003，参考 OpenClaw 的 Markdown 记忆；文件布局见 ADR-0006）：
/// 1. 日终摘要：daily 的 `amai:digest` 区块；
/// 2. Work：work.md 的 `amai:memory` 区块，按项目 / 研究方向分 `### 小节`；
/// 3. General：general.md 的 `amai:memory` 区块，按推荐小节分组。
///
/// 由 LLM 决定保存、更新、舍弃哪些条目；代码只负责来源标注、去重、依据类型校验、快照、
/// 防止一次改写丢失过多已有条目，以及只写系统区块、不碰用户手写内容。
public actor Consolidator {
    public static let digestBlock = SystemBlock(
        name: "digest", note: "由 Amai 每日整理自动生成，区块内的修改会被覆盖"
    )
    public static let memoryBlock = SystemBlock(
        name: "memory", note: "由 Amai 根据每日记录自动维护；区块内的修改会在下次整理时被覆盖，需要保留的内容请写在区块外"
    )

    public struct Options: Sendable {
        /// 本地时间几点之后整理前一天。
        public var dailyHour = 4
        public var maxCatchUpDays = 3
        public var generalInterval: TimeInterval = 7 * 86_400
        /// 首次更新 General 之前至少需要的日终摘要天数。
        public var minDigestsForFirstGeneral = 2
        /// 一次整理写入单个目标（General 全文件、Work 的一个项目）的条目上限。不作用于迁移。
        public var maxItemsPerTarget = 40
        public var maxNewProjectsPerDay = 3
        /// 一次改写后剩余的已有条目比例不得低于此值（OpenClaw 的 maxPriorEntryLossFraction 思路）。
        public var minRetainedFraction = 0.5
        public var dailyContextChars = 6000

        public init() {}
    }

    public struct Status: Sendable, Equatable {
        public var running = false
        public var lastDailyDay: String?
        public var lastGeneralAt: Date?
        public var lastRunAt: Date?
        public var lastError: String?
        public var projectsWritten = 0

        public init() {}
    }

    public struct DayReport: Sendable, Equatable {
        public var digestWritten = false
        /// Work 中被更新的项目（小节名）。
        public var projectsUpdated: [String] = []
        public var projectsRejected: [String] = []
    }

    public enum ConsolidationError: Error, Equatable {
        case unparsableModelOutput(String)
        case tooMuchLoss(String)
    }

    private struct State: Codable {
        var lastDailyDay: String?
        var lastGeneralAt: Date?

        init() {}

        private enum CodingKeys: String, CodingKey { case lastDailyDay, lastGeneralAt, lastSummaryAt }

        /// Schema v1 之前写的是 `lastSummaryAt`，读入时沿用，避免升级后立即重跑一次 General。
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastDailyDay = try c.decodeIfPresent(String.self, forKey: .lastDailyDay)
            lastGeneralAt = try c.decodeIfPresent(Date.self, forKey: .lastGeneralAt)
                ?? c.decodeIfPresent(Date.self, forKey: .lastSummaryAt)
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(lastDailyDay, forKey: .lastDailyDay)
            try c.encodeIfPresent(lastGeneralAt, forKey: .lastGeneralAt)
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
    private let options: Options
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

    // MARK: - 1 + 2. Daily digest and Work

    /// 整理某一天：生成日终摘要，再更新 work.md。可重复调用，结果覆盖系统区块。
    @discardableResult
    public func consolidateDay(_ day: Date) async throws -> DayReport {
        status.running = true
        status.lastRunAt = clock.now()
        defer { status.running = false }
        let dayName = MemoryDirectory.dayName(for: day, timeZone: timeZone)
        let file = MemoryDirectory.dailyFile(for: day, timeZone: timeZone)
        var report = DayReport()

        do {
            guard let daily = await store.read(file),
                  TimelineBlock.block.content(in: daily)?.isEmpty == false
            else {
                // 没有活动记录的日子：直接标记为已整理。
                try markDaily(dayName)
                return report
            }

            let stats = Self.stats(for: await source.segments(on: day))
            let context = String(Self.digestBlock.removing(from: daily).prefix(options.dailyContextChars))

            // 1. 日终摘要
            let digestRaw = try await model.complete(
                system: Prompts.digestSystem,
                user: Prompts.digestUser(day: dayName, stats: stats, daily: context),
                maxTokens: 700,
                schema: Schemas.digest
            )
            guard let digest = ModelJSON.decode(DigestOutput.self, from: digestRaw) else {
                throw ConsolidationError.unparsableModelOutput("digest")
            }
            let digestBody = Self.renderDigest(stats: stats, digest: digest, timeZone: timeZone)
            report.digestWritten = try await store.writeBlock(
                Self.digestBlock, body: digestBody, file: file, newFileTitle: dayName,
                heading: "## 摘要", insertBeforeHeading: TimelineBlock.heading,
                snapshots: snapshots, task: "daily-digest", model: model.identifier, itemCount: digest.highlights?.count ?? 0
            )

            // 2. Work（work.md 按项目分小节）
            let workPath = MemoryCategory.work.file!
            let workText = await store.read(workPath)
            let workItems = workText.flatMap(Self.memoryBlock.content(in:)).map(MemoryItems.parse) ?? []
            let projects = Self.projects(from: workItems)
            let topicRaw = try await model.complete(
                system: Prompts.topicsSystem,
                user: Prompts.topicsUser(day: dayName, daily: (await store.read(file)).map { String($0.prefix(options.dailyContextChars)) } ?? context, projects: projects),
                maxTokens: 1600,
                schema: Schemas.topics
            )
            guard let output = ModelJSON.decode(TopicsOutput.self, from: topicRaw) else {
                throw ConsolidationError.unparsableModelOutput("topics")
            }
            var updatedItems = workItems
            var created = 0
            for update in output.updates ?? [] {
                guard let name = Self.projectName(update.project) else {
                    report.projectsRejected.append(update.project)
                    continue
                }
                let existing = projects.first { $0.name == name }
                if existing == nil {
                    guard created < options.maxNewProjectsPerDay else { report.projectsRejected.append(name); continue }
                }
                let previous = existing?.items ?? []
                // 阶段 1：模型输出还不带依据类型，旧条目沿用原依据，新条目一律记为推断。
                let proposed = update.items.map { var i = $0; i.kind = .unknown; i.section = name; return i }
                var items = MemoryItems.sanitize(proposed, fallbackSource: dayName, limit: options.maxItemsPerTarget)
                items = MemoryItems.reconcileKinds(items, previous: previous, defaultKind: .inferred)
                guard !items.isEmpty else { continue }
                if !retainsEnough(old: previous.count, new: items.count) {
                    log.error("project update rejected: too many entries dropped")
                    report.projectsRejected.append(name)
                    continue
                }
                guard items != previous else { continue }
                updatedItems = Self.replacingSection(name, in: updatedItems, with: items)
                report.projectsUpdated.append(name)
                if existing == nil { created += 1 }
            }
            if !report.projectsUpdated.isEmpty {
                let changed = try await store.writeBlock(
                    Self.memoryBlock, body: MemoryItems.render(updatedItems), file: workPath,
                    newFileTitle: MemorySchema.title(for: .work), heading: MemorySchema.blockHeading,
                    snapshots: snapshots, task: "work", model: model.identifier, itemCount: updatedItems.count
                )
                if !changed { report.projectsUpdated = [] }
            }
            status.projectsWritten += report.projectsUpdated.count
            try markDaily(dayName)
            status.lastError = nil
            log.info("daily consolidated: digest=\(report.digestWritten) projects=\(report.projectsUpdated.count) rejected=\(report.projectsRejected.count)")
            return report
        } catch {
            status.lastError = "整理 \(dayName) 失败：\(error)"
            log.error("daily consolidation failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - 3. general.md

    /// 用最近 7 天的日终摘要与 Work 更新 general.md 的系统区块。
    @discardableResult
    public func updateGeneral() async throws -> Bool {
        status.running = true
        status.lastRunAt = clock.now()
        defer { status.running = false }
        let path = MemoryCategory.general.file!
        do {
            let now = clock.now()
            let digests = await recentDigests(endingOn: now, days: 7)
            guard !digests.isEmpty else { return false }
            let current = await store.read(path)
            let userPart = current.map { Self.memoryBlock.removing(from: $0) } ?? ""
            let existing = current.flatMap { Self.memoryBlock.content(in: $0) }.map(MemoryItems.parse) ?? []
            let workItems = (await store.read(MemoryCategory.work.file!)).flatMap(Self.memoryBlock.content(in:)).map(MemoryItems.parse) ?? []

            let raw = try await model.complete(
                system: Prompts.generalSystem,
                user: Prompts.generalUser(userWritten: userPart, existing: existing, digests: digests, projects: Self.projects(from: workItems)),
                maxTokens: 1800,
                schema: Schemas.general
            )
            guard let output = ModelJSON.decode(GeneralOutput.self, from: raw) else {
                throw ConsolidationError.unparsableModelOutput("general")
            }
            let proposed = (output.items ?? []).map { item in
                var item = item
                item.kind = .unknown
                item.section = MemorySchema.generalSection(forLegacy: item.section)
                return item
            }
            var items = MemoryItems.sanitize(proposed, fallbackSource: nil, limit: options.maxItemsPerTarget)
            items = MemoryItems.reconcileKinds(items, previous: existing, defaultKind: .inferred)
            guard retainsEnough(old: existing.count, new: items.count) else {
                throw ConsolidationError.tooMuchLoss(path)
            }
            let changed = try await store.writeBlock(
                Self.memoryBlock, body: MemoryItems.render(items, sections: MemorySchema.generalSections),
                file: path, newFileTitle: MemorySchema.title(for: .general), heading: MemorySchema.blockHeading,
                snapshots: snapshots, task: "general", model: model.identifier, itemCount: items.count
            )
            state.lastGeneralAt = now
            try saveState()
            status.lastGeneralAt = now
            status.lastError = nil
            return changed
        } catch {
            status.lastError = "更新 General 失败：\(error)"
            log.error("general update failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Helpers

    /// Work 中的一个项目或研究方向，对应 work.md 系统区块里的一个 `### 小节`。
    struct Project: Equatable {
        let name: String
        let items: [MemoryItem]
    }

    static func projects(from items: [MemoryItem]) -> [Project] {
        var order: [String] = []
        var grouped: [String: [MemoryItem]] = [:]
        for item in items {
            let name = item.section ?? "其他"
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(item)
        }
        return order.map { Project(name: $0, items: grouped[$0]!) }
    }

    /// 替换某个项目的条目，其他项目原样保留；新项目追加在末尾。
    static func replacingSection(_ name: String, in items: [MemoryItem], with replacement: [MemoryItem]) -> [MemoryItem] {
        guard let first = items.firstIndex(where: { ($0.section ?? "其他") == name }) else { return items + replacement }
        var result = items.filter { ($0.section ?? "其他") != name }
        let insertAt = items[..<first].filter { ($0.section ?? "其他") != name }.count
        result.insert(contentsOf: replacement, at: insertAt)
        return result
    }

    /// 项目名会成为 Markdown 小节标题：去掉换行、标题符号与注释符号，限制长度。
    static func projectName(_ raw: String) -> String? {
        let name = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#")))
        guard !name.isEmpty else { return nil }
        return String(name.prefix(40))
    }

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

    private func retainsEnough(old: Int, new: Int) -> Bool {
        guard old >= 4 else { return true }
        return Double(new) >= Double(old) * options.minRetainedFraction
    }

    /// 只把已经结束的日子记为已整理；手动整理今天不影响日终的正式整理。
    private func markDaily(_ dayName: String) throws {
        let today = MemoryDirectory.dayName(for: clock.now(), timeZone: timeZone)
        guard dayName < today else { return }
        if state.lastDailyDay.map({ $0 < dayName }) ?? true {
            state.lastDailyDay = dayName
            try saveState()
        }
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
    }

    struct TopicsOutput: Decodable {
        struct Update: Decodable {
            let project: String
            let items: [MemoryItem]
        }
        let updates: [Update]?
    }

    struct GeneralOutput: Decodable {
        let items: [MemoryItem]?
    }

    static func statsLine(_ stats: DayStats, timeZone: TimeZone) -> String {
        guard stats.activeMinutes > 0 else { return "" }
        let cats = stats.byCategory.prefix(4).map { "\(categoryLabel($0.0)) \(hm($0.1))" }.joined(separator: " · ")
        var line = "活跃 \(hm(stats.activeMinutes))（\(cats)）"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let first = stats.first, let last = stats.last {
            let f = calendar.dateComponents([.hour, .minute], from: first)
            let l = calendar.dateComponents([.hour, .minute], from: last)
            line += String(format: "，%02d:%02d–%02d:%02d", f.hour ?? 0, f.minute ?? 0, l.hour ?? 0, l.minute ?? 0)
        }
        return line + "。"
    }

    nonisolated static func renderDigest(stats: DayStats, digest: DigestOutput, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        let line = statsLine(stats, timeZone: timeZone)
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

    private nonisolated static func hm(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分"
    }

    private nonisolated static func categoryLabel(_ c: ActivityCategory) -> String {
        switch c {
        case .work: "工作"
        case .research: "研究"
        case .communication: "沟通"
        case .reading: "阅读"
        case .entertainment: "娱乐"
        case .idle: "空闲"
        case .other: "其他"
        }
    }
}

// MARK: - Prompts

enum Prompts {
    static let digestSystem = """
    你在为用户整理一天的电脑活动记录。下面是当天的 daily 记录，其中时间线由系统根据屏幕活动推断生成，用户也可能手写了内容。
    请输出 JSON：{"summary": "...", "highlights": ["...", "..."]}
    - summary：2 到 3 句中文，概括这一天主要做了什么。
    - highlights：3 到 5 条要点，每条一句话，写具体的项目、文档、事情，不要写泛泛的"处理了一些工作"。
    - 用户手写的内容优先于系统推断；只依据记录内容，不要编造。
    - 不写密码、密钥、验证码等敏感信息。
    只输出 JSON。
    """

    static func digestUser(day: String, stats: Consolidator.DayStats, daily: String) -> String {
        """
        日期：\(day)
        统计（代码计算）：活跃 \(stats.activeMinutes) 分钟；\(stats.byCategory.map { "\($0.0.rawValue) \($0.1) 分钟" }.joined(separator: "，"))
        daily 记录：
        \(daily)
        """
    }

    static let topicsSystem = """
    你在维护用户的工作与研究记忆 work.md。文件按项目或研究方向分组，每组是一个小节。
    根据今天的 daily 记录，决定哪些项目需要更新、是否需要新建项目。
    规则：
    - 只记录有长期价值的研究、项目进展、重要决策和未解决问题；琐碎的操作（打开文件、切换窗口、查看邮件）不要记录。
    - 决策可以写成"〔决策〕…"，未解决的问题写成"〔待解决〕…"。
    - 已有项目：返回该项目更新后的完整条目列表。保留仍然有效的旧条目（连同它们的 sources），合并重复的，改写已过时的，删除确实无用的。
    - 新项目：只在今天的记录明确体现了一个持续进行的项目或研究方向时才新建。project 用简短的项目名，已有项目必须沿用原名。
    - 每条一句中文，写清楚是什么、进展到哪里。sources 写依据的日期（YYYY-MM-DD），新条目写今天的日期。
    - 没有值得更新的内容时返回 {"updates": []}。
    - 只依据记录内容，不要编造；不写敏感信息。
    输出 JSON：{"updates": [{"project": "Amai", "items": [{"text": "...", "sources": ["2026-10-20"]}]}]}
    只输出 JSON。
    """

    static func topicsUser(day: String, daily: String, projects: [Consolidator.Project]) -> String {
        var parts = ["今天：\(day)", "今天的 daily 记录：", daily, "", "已有项目："]
        if projects.isEmpty { parts.append("（无）") }
        for p in projects {
            parts.append("项目「\(p.name)」：")
            parts.append(p.items.map { "  - \($0.text) [sources: \($0.sources.joined(separator: ","))]" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    static let generalSystem = """
    你在维护用户的综合档案 general.md：个人基本信息、教育背景、偏好、当前状态，以及工作、健康、财务、目标等方面的高层概况。
    根据最近几天的日终摘要和工作记忆，更新档案中由系统维护的条目。
    规则：
    - 只保留稳定、长期有价值的信息。一天内的琐事、一次性事件不要写入。
    - 各方面只写高层概况，不要复制工作记忆里的具体进展。
    - 返回更新后的完整条目列表：保留仍然成立的旧条目（连同 sources），合并重复的，修正已经变化的，删除不再成立的。
    - 用户手写的内容是确定事实：不要重复，也不要与之矛盾。
    - 姓名、生日、邮箱、住址等基本信息，只在记录中明确出现时才写；没有就不写，不要编造或为了填满小节而猜测。
    - 区分事实与推测：根据活动推测出的习惯、偏好要写成"似乎""经常"等措辞，不要写成确定事实。
    - section 取值：\(MemorySchema.generalSections.joined(separator: "、"))。
    - 每条一句中文。sources 写依据的日期（YYYY-MM-DD）。
    - 不写敏感信息。
    输出 JSON：{"items": [{"section": "工作概况", "text": "...", "sources": ["2026-10-19", "2026-10-20"]}]}
    只输出 JSON。
    """

    static func generalUser(userWritten: String, existing: [MemoryItem], digests: [(day: String, text: String)], projects: [Consolidator.Project]) -> String {
        var parts: [String] = []
        let written = userWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("用户手写的档案内容：")
        parts.append(written.isEmpty ? "（无）" : written)
        parts.append("\n当前系统条目：")
        parts.append(existing.isEmpty ? "（无）" : existing.map { "- [\($0.section ?? "其他")] \($0.text) [sources: \($0.sources.joined(separator: ","))]" }.joined(separator: "\n"))
        parts.append("\n最近的日终摘要：")
        for d in digests { parts.append("【\(d.day)】\n\(d.text)") }
        parts.append("\n工作记忆（work.md）：")
        if projects.isEmpty { parts.append("（无）") }
        for p in projects {
            parts.append("\(p.name)：" + p.items.prefix(8).map(\.text).joined(separator: "；"))
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Output schemas

/// 三个整理任务的输出 Schema。所有字段必填、不允许额外字段，
/// 同时满足 Anthropic `output_config.format` 与 OpenAI strict `json_schema` 的要求。
enum Schemas {
    private static let item = #"{"type":"object","properties":{"text":{"type":"string"},"sources":{"type":"array","items":{"type":"string"}}},"required":["text","sources"],"additionalProperties":false}"#

    static let digest = OutputSchema(name: "daily_digest", json: #"""
    {"type":"object","properties":{"summary":{"type":"string"},"highlights":{"type":"array","items":{"type":"string"}}},"required":["summary","highlights"],"additionalProperties":false}
    """#)

    static let topics = OutputSchema(name: "work_topics", json: #"""
    {"type":"object","properties":{"updates":{"type":"array","items":{"type":"object","properties":{"project":{"type":"string"},"items":{"type":"array","items":\#(item)}},"required":["project","items"],"additionalProperties":false}}},"required":["updates"],"additionalProperties":false}
    """#)

    static let general = OutputSchema(name: "general_profile", json: #"""
    {"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"section":{"type":"string","enum":[\#(sectionEnum)]},"text":{"type":"string"},"sources":{"type":"array","items":{"type":"string"}}},"required":["section","text","sources"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}
    """#)

    private static var sectionEnum: String {
        MemorySchema.generalSections.map { "\"\($0)\"" }.joined(separator: ",")
    }
}

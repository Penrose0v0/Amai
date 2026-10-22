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

/// 记忆整理（ADR-0003，参考 OpenClaw 的 Markdown 记忆）：
/// 1. 日终摘要：daily 的 `amai:digest` 区块；
/// 2. work/ 专题：每个文件"## 记录"下的 `amai:memory` 区块；
/// 3. summary.md：`amai:memory` 区块，按小节分组。
///
/// 由 LLM 决定保存、更新、舍弃哪些条目；代码只负责来源标注、去重、快照、
/// 防止一次改写丢失过多已有条目，以及只写系统区块、不碰用户手写内容。
public actor Consolidator {
    public static let digestBlock = SystemBlock(
        name: "digest", note: "由 Amai 每日整理自动生成，区块内的修改会被覆盖"
    )
    public static let memoryBlock = SystemBlock(
        name: "memory", note: "由 Amai 根据每日记录自动维护；区块内的修改会在下次整理时被覆盖，需要保留的内容请写在区块外"
    )
    public static let summarySections = ["基本背景", "工作与研究", "习惯与偏好", "长期目标", "重要关系", "其他"]

    public struct Options: Sendable {
        /// 本地时间几点之后整理前一天。
        public var dailyHour = 4
        public var maxCatchUpDays = 3
        public var summaryInterval: TimeInterval = 7 * 86_400
        /// 首次更新 summary 之前至少需要的日终摘要天数。
        public var minDigestsForFirstSummary = 2
        public var maxItemsPerFile = 40
        public var maxNewTopicsPerDay = 3
        /// 一次改写后剩余的已有条目比例不得低于此值（OpenClaw 的 maxPriorEntryLossFraction 思路）。
        public var minRetainedFraction = 0.5
        public var dailyContextChars = 6000

        public init() {}
    }

    public struct Status: Sendable, Equatable {
        public var running = false
        public var lastDailyDay: String?
        public var lastSummaryAt: Date?
        public var lastRunAt: Date?
        public var lastError: String?
        public var topicsWritten = 0

        public init() {}
    }

    public struct DayReport: Sendable, Equatable {
        public var digestWritten = false
        public var topicsUpdated: [String] = []
        public var topicsRejected: [String] = []
    }

    public enum ConsolidationError: Error, Equatable {
        case unparsableModelOutput(String)
        case tooMuchLoss(String)
    }

    private struct State: Codable {
        var lastDailyDay: String?
        var lastSummaryAt: Date?
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
        self.status.lastSummaryAt = state.lastSummaryAt
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

    /// 补整理已结束但未整理的日子（凌晨 `dailyHour` 点之后才算"昨天已结束"），然后按需更新 summary。
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

        if await summaryDue(now: now) {
            _ = try? await updateSummary()
        }
    }

    private func summaryDue(now: Date) async -> Bool {
        if let last = state.lastSummaryAt {
            return now.timeIntervalSince(last) >= options.summaryInterval
        }
        return await recentDigests(endingOn: now, days: 7).count >= options.minDigestsForFirstSummary
    }

    // MARK: - 1 + 2. Daily digest and work topics

    /// 整理某一天：生成日终摘要，再更新 work/ 专题。可重复调用，结果覆盖系统区块。
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

            // 2. work/ 专题
            let topics = await existingTopics()
            let topicRaw = try await model.complete(
                system: Prompts.topicsSystem,
                user: Prompts.topicsUser(day: dayName, daily: (await store.read(file)).map { String($0.prefix(options.dailyContextChars)) } ?? context, topics: topics),
                maxTokens: 1600,
                schema: Schemas.topics
            )
            guard let output = ModelJSON.decode(TopicsOutput.self, from: topicRaw) else {
                throw ConsolidationError.unparsableModelOutput("topics")
            }
            var created = 0
            for update in output.updates ?? [] {
                guard let path = Self.validTopicPath(update.file) else {
                    report.topicsRejected.append(update.file)
                    continue
                }
                let existing = topics.first { $0.file == path }
                if existing == nil {
                    guard created < options.maxNewTopicsPerDay else { report.topicsRejected.append(path); continue }
                }
                let items = MemoryItems.sanitize(update.items, fallbackSource: dayName, limit: options.maxItemsPerFile)
                guard !items.isEmpty else { continue }
                if let existing, !retainsEnough(old: existing.items.count, new: items.count) {
                    log.error("topic update rejected: too many entries dropped")
                    report.topicsRejected.append(path)
                    continue
                }
                let title = (update.title?.isEmpty == false ? update.title! : existing?.title) ?? Self.titleFromPath(path)
                if try await store.writeBlock(
                    Self.memoryBlock, body: MemoryItems.render(items), file: path,
                    newFileTitle: title, heading: "## 记录",
                    snapshots: snapshots, task: "work-topic", model: model.identifier, itemCount: items.count
                ) {
                    report.topicsUpdated.append(path)
                    if existing == nil { created += 1 }
                }
            }
            status.topicsWritten += report.topicsUpdated.count
            try markDaily(dayName)
            status.lastError = nil
            log.info("daily consolidated: digest=\(report.digestWritten) topics=\(report.topicsUpdated.count) rejected=\(report.topicsRejected.count)")
            return report
        } catch {
            status.lastError = "整理 \(dayName) 失败：\(error)"
            log.error("daily consolidation failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - 3. summary.md

    /// 用最近 7 天的日终摘要与 work/ 专题更新 summary.md 的系统区块。
    @discardableResult
    public func updateSummary() async throws -> Bool {
        status.running = true
        status.lastRunAt = clock.now()
        defer { status.running = false }
        do {
            let now = clock.now()
            let digests = await recentDigests(endingOn: now, days: 7)
            guard !digests.isEmpty else { return false }
            let current = await store.read(MemoryDirectory.summary)
            let userPart = current.map { Self.memoryBlock.removing(from: $0) } ?? ""
            let existing = current.flatMap { Self.memoryBlock.content(in: $0) }.map(MemoryItems.parse) ?? []
            let topics = await existingTopics()

            let raw = try await model.complete(
                system: Prompts.summarySystem,
                user: Prompts.summaryUser(userWritten: userPart, existing: existing, digests: digests, topics: topics),
                maxTokens: 1800,
                schema: Schemas.summary
            )
            guard let output = ModelJSON.decode(SummaryOutput.self, from: raw) else {
                throw ConsolidationError.unparsableModelOutput("summary")
            }
            var items = MemoryItems.sanitize(output.items ?? [], fallbackSource: nil, limit: options.maxItemsPerFile)
            items = items.map { item in
                var item = item
                if item.section.map(Self.summarySections.contains) != true { item.section = "其他" }
                return item
            }
            guard retainsEnough(old: existing.count, new: items.count) else {
                throw ConsolidationError.tooMuchLoss(MemoryDirectory.summary)
            }
            let changed = try await store.writeBlock(
                Self.memoryBlock, body: MemoryItems.render(items, sections: Self.summarySections),
                file: MemoryDirectory.summary, newFileTitle: "用户档案", heading: "## Amai 整理的长期记忆",
                snapshots: snapshots, task: "summary", model: model.identifier, itemCount: items.count
            )
            state.lastSummaryAt = now
            try saveState()
            status.lastSummaryAt = now
            status.lastError = nil
            return changed
        } catch {
            status.lastError = "更新 summary 失败：\(error)"
            log.error("summary update failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Helpers

    struct Topic: Equatable {
        let file: String
        let title: String
        let items: [MemoryItem]
    }

    private func existingTopics() async -> [Topic] {
        var topics: [Topic] = []
        for file in await store.markdownFiles() where file.hasPrefix("work/") {
            guard let text = await store.read(file) else { continue }
            let title = text.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
                ?? Self.titleFromPath(file)
            let items = Self.memoryBlock.content(in: text).map(MemoryItems.parse) ?? []
            topics.append(Topic(file: file, title: title, items: items))
        }
        return topics
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

    /// 只接受 `work/` 下的 `.md`，不允许 `..`、隐藏文件或空段。
    static func validTopicPath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("/") { path.removeFirst() }
        guard path.hasPrefix("work/"), path.hasSuffix(".md"), path.count < 120 else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." && !$0.hasPrefix(".") }) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        guard path.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return path
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
            let file: String
            let title: String?
            let items: [MemoryItem]
        }
        let updates: [Update]?
    }

    struct SummaryOutput: Decodable {
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
    你在维护用户的工作与研究记忆，存放在 work/ 目录下的 Markdown 文件中，一个文件对应一个项目或研究方向。
    根据今天的 daily 记录，决定哪些专题需要更新、是否需要新建专题。
    规则：
    - 只记录有长期价值的进展、决定、问题和结论；琐碎的操作（打开文件、切换窗口、查看邮件）不要记录。
    - 已有专题：返回该文件更新后的完整条目列表。保留仍然有效的旧条目（连同它们的 sources），合并重复的，改写已过时的，删除确实无用的。
    - 新专题：只在今天的记录明确体现了一个持续进行的项目或研究方向时才新建。文件名用英文小写和连字符，例如 work/projects/amai.md、work/research/consistency-metrics.md。
    - 每条一句中文，写清楚是什么、进展到哪里。sources 写依据的日期（YYYY-MM-DD），新条目写今天的日期。
    - 没有值得更新的内容时返回 {"updates": []}。
    - 只依据记录内容，不要编造；不写敏感信息。
    输出 JSON：{"updates": [{"file": "work/projects/amai.md", "title": "Amai", "items": [{"text": "...", "sources": ["2026-10-20"]}]}]}
    只输出 JSON。
    """

    static func topicsUser(day: String, daily: String, topics: [Consolidator.Topic]) -> String {
        var parts = ["今天：\(day)", "今天的 daily 记录：", daily, "", "已有专题："]
        if topics.isEmpty { parts.append("（无）") }
        for t in topics {
            parts.append("文件 \(t.file)（\(t.title)）：")
            parts.append(t.items.isEmpty ? "  （无条目）" : t.items.map { "  - \($0.text) [sources: \($0.sources.joined(separator: ","))]" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    static let summarySystem = """
    你在维护用户的长期记忆档案 summary.md，它是对用户的综合理解：背景、工作与研究、习惯与偏好、长期目标、重要关系。
    根据最近几天的日终摘要和工作专题，更新档案中由系统维护的条目。
    规则：
    - 只保留稳定、长期有价值的信息。一天内的琐事、一次性事件不要写入。
    - 返回更新后的完整条目列表：保留仍然成立的旧条目（连同 sources），合并重复的，修正已经变化的，删除不再成立的。
    - 用户手写的内容是确定事实：不要重复，也不要与之矛盾。
    - 区分事实与推测：根据活动推测出的习惯、偏好要写成"似乎""经常"等措辞，不要写成确定事实。
    - section 取值：基本背景、工作与研究、习惯与偏好、长期目标、重要关系、其他。
    - 每条一句中文。sources 写依据的日期（YYYY-MM-DD）。
    - 不写敏感信息。
    输出 JSON：{"items": [{"section": "工作与研究", "text": "...", "sources": ["2026-10-19", "2026-10-20"]}]}
    只输出 JSON。
    """

    static func summaryUser(userWritten: String, existing: [MemoryItem], digests: [(day: String, text: String)], topics: [Consolidator.Topic]) -> String {
        var parts: [String] = []
        let written = userWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("用户手写的档案内容：")
        parts.append(written.isEmpty ? "（无）" : written)
        parts.append("\n当前系统条目：")
        parts.append(existing.isEmpty ? "（无）" : existing.map { "- [\($0.section ?? "其他")] \($0.text) [sources: \($0.sources.joined(separator: ","))]" }.joined(separator: "\n"))
        parts.append("\n最近的日终摘要：")
        for d in digests { parts.append("【\(d.day)】\n\(d.text)") }
        parts.append("\n工作专题：")
        if topics.isEmpty { parts.append("（无）") }
        for t in topics {
            parts.append("\(t.title)（\(t.file)）：" + t.items.prefix(8).map(\.text).joined(separator: "；"))
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
    {"type":"object","properties":{"updates":{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"title":{"type":"string"},"items":{"type":"array","items":\#(item)}},"required":["file","title","items"],"additionalProperties":false}}},"required":["updates"],"additionalProperties":false}
    """#)

    static let summary = OutputSchema(name: "long_term_summary", json: #"""
    {"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"section":{"type":"string","enum":["基本背景","工作与研究","习惯与偏好","长期目标","重要关系","其他"]},"text":{"type":"string"},"sources":{"type":"array","items":{"type":"string"}}},"required":["section","text","sources"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}
    """#)
}

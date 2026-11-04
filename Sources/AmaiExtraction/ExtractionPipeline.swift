import AmaiCore
import Foundation

public enum ExtractionState: String, Sendable, Equatable {
    case idle
    case running
    /// 电源档位不允许重计算（电池 / 过热），稍后再试。
    case deferred
    /// 窗口内有帧所在的视频分段仍在写入。
    case waitingForFrames
    /// 本地模型未安装或无法加载。
    case modelUnavailable
    /// 本轮处理失败，下一轮重试。
    case retrying
    case disabled
}

/// 供 App 显示的状态。不含任何内容字段。
public struct ExtractionStatus: Sendable, Equatable {
    public var state: ExtractionState = .idle
    public var processedUntil: Date?
    public var batchesProcessed = 0
    public var segmentsWritten = 0
    public var framesDescribed = 0
    public var fallbackBatches = 0
    public var pendingBatches = 0
    public var lastBatchSeconds: Double?
    public var lastRunAt: Date?
    public var lastError: String?
    public var progressDone: Int?
    public var progressTotal: Int?

    public init() {}
}

public enum ExtractionError: Error, Equatable {
    case framesPending
    case invalidModelOutput
}

/// 屏幕抽取流水线（M2 MVP）：
/// 窗口 → 隐私 / 空闲规则 → 帧筛选 → 每帧 OCR（事实）+ VLM 描述（推断）→ 活动切分 → 存储。
///
/// - 增量：以 `processedUntil` 水位线推进，重启后从断点继续；
/// - 稳定：同一窗口失败 `maxAttempts` 次后按前台应用生成低置信度兜底片段，不让流程卡住；
/// - 可追溯：观察与片段都带证据引用（事件 id、视频分段、帧号）。
public actor ExtractionPipeline {
    public struct Dependencies: Sendable {
        public var reader: any PerceptionReading
        public var model: any ModelProvider
        public var ocr: any TextRecognizer
        public var store: ExtractionStore
        public var clock: any AmaiClock
        public var timeZone: TimeZone
        /// 是否允许在当前电源状态下做重计算。手动触发时忽略。
        public var shouldRun: @Sendable () -> Bool

        public init(
            reader: any PerceptionReading,
            model: any ModelProvider,
            ocr: any TextRecognizer,
            store: ExtractionStore,
            clock: any AmaiClock = SystemClock(),
            timeZone: TimeZone = .current,
            shouldRun: @escaping @Sendable () -> Bool = { true }
        ) {
            self.reader = reader
            self.model = model
            self.ocr = ocr
            self.store = store
            self.clock = clock
            self.timeZone = timeZone
            self.shouldRun = shouldRun
        }
    }

    public struct Options: Sendable {
        public var batching = BatchingOptions()
        public var selection = FrameSelector.Options()
        public var pollInterval: TimeInterval = 60
        public var maxBatchesPerRun = 4
        public var maxAttempts = 3
        /// 首次运行时向前追溯多久（与 RawSpool 的默认 TTL 一致）。
        public var lookback: TimeInterval = 72 * 3600
        public var frameMaxHeight = 1080
        public var descriptionMaxTokens = 160
        public var segmentationMaxTokens = 1200
        public var ocrPromptChars = 600
        /// 记忆语言：提示词与写入的片段文字使用的语言。运行中可用 `setLanguage` 切换。
        public var language: MemoryLanguage = .default
        public var ocrStoreChars = 4000
        public var evidencePerSegment = 24
        /// 短于此时长的模型片段并入相邻片段（小模型常常切得过碎）。
        public var minSegmentDuration: TimeInterval = 180

        public init() {}
    }

    private let deps: Dependencies
    private var options: Options
    private var enabled = true
    private let log = AmaiLog.logger("extraction")

    private var loop: Task<Void, Never>?
    private var busy = false
    private var attempts: [String: Int] = [:]
    /// 同一窗口重试时复用已生成的帧描述，避免重复推理。成功后清空。
    private var descriptionCache: [UUID: String] = [:]

    public private(set) var status = ExtractionStatus()

    public init(dependencies: Dependencies, options: Options = .init()) {
        self.deps = dependencies
        self.options = options
    }

    /// 切换记忆语言：只影响之后处理的窗口，已写入的片段不变。
    public func setLanguage(_ language: MemoryLanguage) {
        options.language = language
        descriptionCache.removeAll()
    }

    private var text: ExtractionText { ExtractionText(lang: options.language) }

    public func apply(_ configuration: ExtractionConfiguration) {
        enabled = configuration.enabled
        options.selection.maxFrames = configuration.maxFramesPerBatch
    }

    // MARK: - Loop

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.runOnce()
                try? await Task.sleep(for: .seconds(await self.options.pollInterval))
            }
        }
        log.info("extraction pipeline started")
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 处理所有已就绪的窗口（每轮最多 `maxBatchesPerRun` 个）。返回成功处理的窗口数。
    @discardableResult
    public func runOnce(force: Bool = false) async -> Int {
        guard enabled else {
            status.state = .disabled
            return 0
        }
        guard !busy else { return 0 }
        if !force && !deps.shouldRun() {
            status.state = .deferred
            return 0
        }
        busy = true
        defer {
            busy = false
            status.progressDone = nil
            status.progressTotal = nil
        }

        let now = deps.clock.now()
        status.state = .running
        status.lastRunAt = now
        var state = await deps.store.loadState()
        let since = state.processedUntil ?? now.addingTimeInterval(-options.lookback)

        let batches: [ExtractionBatch]
        do {
            let events = try await deps.reader.events(after: since, until: now)
            batches = Batcher.readyBatches(events: events, now: now, options: options.batching)
        } catch {
            status.state = .retrying
            status.lastError = "读取感知数据失败"
            log.error("reading events failed: \(String(describing: error), privacy: .public)")
            return 0
        }
        status.pendingBatches = batches.count

        var processed = 0
        for batch in batches.prefix(options.maxBatchesPerRun) {
            let started = Date()
            do {
                let written = try await process(batch)
                try await advance(&state, to: batch, written: written, started: started)
                processed += 1
            } catch ExtractionError.framesPending {
                status.state = .waitingForFrames
                break
            } catch let error as ModelProviderError {
                if case .modelNotInstalled(let tag) = error {
                    // 模型缺失是配置问题，不计入重试次数，也不退化为兜底结果。
                    status.state = .modelUnavailable
                    status.lastError = "本地模型未安装：\(tag)"
                    break
                }
                if await handleFailure(batch, error: error, state: &state, started: started) { processed += 1 } else { break }
            } catch {
                if await handleFailure(batch, error: error, state: &state, started: started) { processed += 1 } else { break }
            }
        }
        status.pendingBatches = max(0, batches.count - processed)
        if status.state == .running { status.state = .idle }
        return processed
    }

    // MARK: - Batch processing

    private func process(_ batch: ExtractionBatch) async throws -> Int {
        if batch.frames.isEmpty {
            return try await writeRuleSegment(batch, kind: .privacy(reason: dominantSkipReason(batch)))
        }
        if IdleClassifier.isIdle(batch) {
            return try await writeRuleSegment(batch, kind: .idle)
        }

        let selected = FrameSelector.select(batch.frames, options: options.selection)
        let displays = DisplayLabels(batch.frames, text: text)
        var observations: [Observation] = []
        var timeline: [(Date, String)] = []

        for (i, frame) in selected.enumerated() {
            status.progressDone = i
            status.progressTotal = selected.count
            var jpeg: Data?
            switch await deps.reader.frame(for: frame, maxHeight: options.frameMaxHeight) {
            case .pending: throw ExtractionError.framesPending
            case .expired: jpeg = nil
            case .available(let data): jpeg = data
            }

            let (facts, ocrText) = await factObservation(for: frame, jpeg: jpeg)
            observations.append(facts)

            var description: String?
            if let jpeg {
                description = try await describe(frame, jpeg: jpeg, ocrText: ocrText)
                if let description, !description.isEmpty {
                    observations.append(Observation(
                        timeRange: frameRange(frame),
                        modality: .screen,
                        kind: .inference,
                        content: description,
                        confidence: 0.7,
                        evidence: [Evidence(event: frame)],
                        attributes: appAttributes(frame),
                        provider: deps.model.identifier
                    ))
                }
            }
            timeline.append((frame.wallTime, timelineLine(frame, displays: displays, description: description, ocrText: ocrText)))
        }
        timeline += contextLines(batch)
        timeline += displayOverview(batch, displays: displays)
        timeline.sort { $0.0 < $1.0 }

        let previous = await mergeablePrevious(before: batch.range.start)
        let parsed = try await segment(batch, timeline: timeline.map(\.1), previous: previous)

        try await deps.store.append(observations)
        return try await writeModelSegments(parsed, batch: batch, selected: selected, observations: observations, previous: previous)
    }

    private func factObservation(for frame: PerceptionEvent, jpeg: Data?) async -> (Observation, String) {
        var attributes = appAttributes(frame)
        attributes["frameAvailable"] = jpeg == nil ? "false" : "true"
        if let display = frame.metadata.displayId, frame.metadata.focusDisplayId != nil {
            attributes["displayId"] = String(display)
            attributes["focusDisplay"] = frame.metadata.isOnFocusDisplay ? "true" : "false"
        }
        if let idle = frame.metadata.idleSeconds { attributes["idleSeconds"] = String(Int(idle)) }

        var text = ""
        var confidence = 1.0
        var provider = "perception"
        if let jpeg {
            do {
                let result = try await deps.ocr.recognize(jpeg: jpeg)
                let redacted = SecretRedactor.redact(result.text)
                text = String(redacted.text.prefix(options.ocrStoreChars))
                attributes["ocrLines"] = String(result.lines.count)
                if redacted.count > 0 { attributes["redactions"] = String(redacted.count) }
                if !result.lines.isEmpty {
                    confidence = result.meanConfidence
                    provider = "vision-ocr"
                }
            } catch {
                // OCR 失败不影响流程，只是少了文字线索。
                attributes["ocrError"] = "true"
            }
        }
        let observation = Observation(
            timeRange: frameRange(frame),
            modality: .screen,
            kind: .fact,
            content: text,
            confidence: confidence,
            evidence: [Evidence(event: frame)],
            attributes: attributes,
            provider: provider
        )
        return (observation, text)
    }

    private func describe(_ frame: PerceptionEvent, jpeg: Data, ocrText: String) async throws -> String {
        if let cached = descriptionCache[frame.id] { return cached }
        let excerpt = String(ocrText.prefix(options.ocrPromptChars))
        let request = ModelRequest(
            cacheable: Prompts.frameDescriptionSystem(options.language),
            dynamic: Prompts.frameDescriptionUser(
                time: clock(frame.wallTime),
                app: frame.metadata.app,
                idleSeconds: frame.metadata.idleSeconds,
                onFocusDisplay: frame.metadata.isOnFocusDisplay,
                ocrExcerpt: excerpt,
                language: options.language
            ),
            images: [jpeg],
            maxTokens: options.descriptionMaxTokens
        )
        let response = try await deps.model.generate(request)
        let text = SecretRedactor.redact(response.text).text
        descriptionCache[frame.id] = text
        status.framesDescribed += 1
        return text
    }

    private func segment(_ batch: ExtractionBatch, timeline: [String], previous: ActivitySegment?) async throws -> [ParsedSegment] {
        let previousText = previous.map {
            "\(clock($0.timeRange.start))–\(clock($0.timeRange.end))「\($0.title)」\($0.summary)"
        }
        let user = Prompts.segmentationUser(
            previous: previousText,
            rangeText: "\(clock(batch.range.start))–\(clock(batch.range.end))",
            timeline: timeline,
            language: options.language
        )
        for attempt in 0..<2 {
            let response = try await deps.model.generate(ModelRequest(
                cacheable: Prompts.segmentationSystem(options.language),
                dynamic: user,
                maxTokens: options.segmentationMaxTokens,
                temperature: attempt == 0 ? 0.2 : 0
            ))
            if let parsed = try? SegmentParser.parse(response.text, window: batch.range, timeZone: deps.timeZone) {
                return SegmentParser.mergeShort(parsed, minDuration: options.minSegmentDuration)
            }
            log.error("segmentation output unparsable (attempt \(attempt + 1))")
        }
        throw ExtractionError.invalidModelOutput
    }

    private func writeModelSegments(
        _ parsed: [ParsedSegment],
        batch: ExtractionBatch,
        selected: [PerceptionEvent],
        observations: [Observation],
        previous: ActivitySegment?
    ) async throws -> Int {
        let now = deps.clock.now()
        var written = 0
        for (i, p) in parsed.enumerated() {
            let isLast = i == parsed.count - 1
            func inside(_ d: Date) -> Bool {
                d >= p.range.start && (d < p.range.end || (isLast && d <= p.range.end))
            }
            let obsIds = observations.filter { inside($0.timeRange.start) }.map(\.id)
            let evidence = selected.filter { inside($0.wallTime) }.map(Evidence.init(event:))
            let apps = uniqueApps(batch.frames.filter { inside($0.wallTime) })

            let segment: ActivitySegment
            if i == 0, p.continuesPrevious, let prev = previous {
                segment = ActivitySegment(
                    id: prev.id,
                    timeRange: TimeRange(start: prev.timeRange.start, end: max(prev.timeRange.end, p.range.end)),
                    title: p.title,
                    summary: p.summary,
                    category: p.category,
                    apps: union(prev.apps, apps),
                    observations: prev.observations + obsIds,
                    evidence: capped(prev.evidence + evidence),
                    confidence: (prev.confidence + p.confidence) / 2,
                    provider: deps.model.identifier,
                    updatedAt: now
                )
            } else {
                segment = ActivitySegment(
                    timeRange: p.range,
                    title: p.title,
                    summary: p.summary,
                    category: p.category,
                    apps: apps,
                    observations: obsIds,
                    evidence: capped(evidence),
                    confidence: p.confidence,
                    provider: deps.model.identifier,
                    updatedAt: now
                )
            }
            try await deps.store.upsert(segment)
            written += 1
        }
        return written
    }

    // MARK: - Rule & fallback segments

    private enum RuleKind {
        case idle
        case privacy(reason: SkipReasonLabel)
    }

    private enum SkipReasonLabel: String {
        case userPaused, secureInput, excludedApp, other
    }

    private func dominantSkipReason(_ batch: ExtractionBatch) -> SkipReasonLabel {
        let counts = Dictionary(grouping: batch.skipped.compactMap(\.metadata.skipReason)) { $0 }.mapValues(\.count)
        let top = counts.max { $0.value < $1.value }?.key
        return top.flatMap(SkipReasonLabel.init(rawValue:)) ?? .other
    }

    private func writeRuleSegment(_ batch: ExtractionBatch, kind: RuleKind) async throws -> Int {
        let (title, summary, category, confidence, provider): (String, String, ActivityCategory, Double, String)
        switch kind {
        case .idle:
            // 副屏画面变化单独记一笔，不影响"离开"的判定。
            let secondary = (IdleClassifier.secondaryChangeFraction(batch) ?? 0) >= 0.5
                ? text.otherScreensChanging : ""
            (title, summary, category, confidence, provider) =
                (text.awayTitle, text.awaySummary + secondary, .idle, 0.8, "rule:idle")
        case .privacy(let reason):
            (title, summary, category, confidence, provider) =
                (text.skipTitle(reason.rawValue), text.privacySummary, .other, 1, "rule:privacy")
        }
        let evidence = batch.frames.first.map { [Evidence(event: $0)] } ?? []
        let apps = uniqueApps(batch.frames)
        let now = deps.clock.now()

        if let prev = await mergeablePrevious(before: batch.range.start),
           prev.provider == provider, prev.title == title {
            try await deps.store.upsert(ActivitySegment(
                id: prev.id,
                timeRange: TimeRange(start: prev.timeRange.start, end: max(prev.timeRange.end, batch.range.end)),
                title: title, summary: summary, category: category,
                apps: union(prev.apps, apps), observations: prev.observations,
                evidence: capped(prev.evidence + evidence),
                confidence: confidence, provider: provider, updatedAt: now
            ))
        } else {
            try await deps.store.upsert(ActivitySegment(
                timeRange: batch.range, title: title, summary: summary, category: category,
                apps: apps, observations: [], evidence: evidence,
                confidence: confidence, provider: provider, updatedAt: now
            ))
        }
        return 1
    }

    /// 模型多次失败后的兜底：按前台应用连续段生成低置信度片段，明确标注来源。
    private func processFallback(_ batch: ExtractionBatch) async throws -> Int {
        // 多屏时同一时刻每块屏幕各有一帧、前台应用相同，只看焦点屏即可。
        let focus = batch.frames.filter(\.metadata.isOnFocusDisplay)
        let frames = (focus.isEmpty ? batch.frames : focus).sorted { $0.wallTime < $1.wallTime }
        guard !frames.isEmpty else {
            return try await writeRuleSegment(batch, kind: .privacy(reason: dominantSkipReason(batch)))
        }
        var raw: [[PerceptionEvent]] = []
        for frame in frames {
            if let last = raw.last?.last, last.metadata.bundleId == frame.metadata.bundleId {
                raw[raw.count - 1].append(frame)
            } else {
                raw.append([frame])
            }
        }
        // 不足一分钟的短暂切换并入前一段。
        var runs: [[PerceptionEvent]] = []
        for run in raw {
            let span = (run.last?.wallTime.timeIntervalSince(run.first?.wallTime ?? .distantPast)) ?? 0
            if span < 60, !runs.isEmpty {
                runs[runs.count - 1] += run
            } else {
                runs.append(run)
            }
        }
        let now = deps.clock.now()
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            let name = first.metadata.app ?? first.metadata.bundleId ?? text.unknownApp
            try await deps.store.upsert(ActivitySegment(
                timeRange: TimeRange(start: first.wallTime, end: last.wallTime.addingTimeInterval(options.batching.frameSpan)),
                title: text.fallbackTitle(name),
                summary: text.fallbackSummary,
                category: .other,
                apps: uniqueApps(run),
                observations: [],
                evidence: [first, last].map(Evidence.init(event:)),
                confidence: 0.3,
                provider: "fallback:metadata",
                updatedAt: now
            ))
        }
        return runs.count
    }

    private func handleFailure(
        _ batch: ExtractionBatch, error: Error, state: inout ExtractionStore.State, started: Date
    ) async -> Bool {
        let n = attempts[batch.id, default: 0] + 1
        attempts[batch.id] = n
        status.lastError = "窗口处理失败（第 \(n) 次）：\(String(describing: error))"
        log.error("batch failed attempt \(n): \(String(describing: error), privacy: .public)")
        guard n >= options.maxAttempts else {
            status.state = .retrying
            return false
        }
        do {
            let written = try await processFallback(batch)
            status.fallbackBatches += 1
            try await advance(&state, to: batch, written: written, started: started)
            return true
        } catch {
            status.state = .retrying
            status.lastError = "兜底写入失败：\(String(describing: error))"
            return false
        }
    }

    private func advance(_ state: inout ExtractionStore.State, to batch: ExtractionBatch, written: Int, started: Date) async throws {
        state.processedUntil = batch.lastEventTime
        try await deps.store.saveState(state)
        attempts[batch.id] = nil
        descriptionCache.removeAll()
        status.processedUntil = batch.lastEventTime
        status.batchesProcessed += 1
        status.segmentsWritten += written
        status.lastBatchSeconds = Date().timeIntervalSince(started)
        status.lastError = nil
        log.info("batch processed: \(written) segment(s) in \(Int(Date().timeIntervalSince(started))) s")
    }

    // MARK: - Helpers

    /// 结束时间与 `date` 相距不超过 `maxGap` 的上一个片段才允许合并 / 延续。
    private func mergeablePrevious(before date: Date) async -> ActivitySegment? {
        guard let prev = await deps.store.latestSegment(endingAtOrBefore: date.addingTimeInterval(options.batching.frameSpan)),
              date.timeIntervalSince(prev.timeRange.end) <= options.batching.maxGap
        else { return nil }
        return prev
    }

    private func contextLines(_ batch: ExtractionBatch) -> [(Date, String)] {
        var lines: [(Date, String)] = []
        var lastApp: String?
        for event in batch.focusChanges.sorted(by: { $0.wallTime < $1.wallTime }) {
            let app = event.metadata.app ?? event.metadata.bundleId
            guard let app, app != lastApp else { continue }
            lastApp = app
            lines.append((event.wallTime, "\(clock(event.wallTime)) \(text.switchedTo(app))"))
        }
        // 连续的隐私跳过合并成一个时段。
        var runStart: PerceptionEvent?
        var runEnd: PerceptionEvent?
        func flush() {
            guard let s = runStart, let e = runEnd else { return }
            let reason = SkipReasonLabel(rawValue: s.metadata.skipReason ?? "") ?? .other
            let span = s.id == e.id ? clock(s.wallTime) : "\(clock(s.wallTime))–\(clock(e.wallTime))"
            lines.append((s.wallTime, "\(span) \(text.privacySkipped) \(text.skipTitle(reason.rawValue))"))
        }
        for event in batch.skipped.sorted(by: { $0.wallTime < $1.wallTime }) {
            if let e = runEnd, event.metadata.skipReason == e.metadata.skipReason,
               event.wallTime.timeIntervalSince(e.wallTime) <= options.batching.frameSpan * 2 {
                runEnd = event
            } else {
                flush()
                runStart = event
                runEnd = event
            }
        }
        flush()
        return lines
    }

    /// 多显示器窗口的屏幕编号：按显示器 id 排序后依次称为屏幕1、屏幕2…；单屏时不加标注。
    private struct DisplayLabels {
        private let names: [UInt32: String]

        private let text: ExtractionText

        init(_ frames: [PerceptionEvent], text: ExtractionText) {
            self.text = text
            let ids = Set(frames.compactMap(\.metadata.displayId)).sorted()
            names = ids.count > 1
                ? Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, text.displayName($0 + 1)) })
                : [:]
        }

        var isMulti: Bool { !names.isEmpty }
        var all: [(UInt32, String)] { names.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }

        func tag(_ frame: PerceptionEvent) -> String? {
            guard let id = frame.metadata.displayId, let name = names[id] else { return nil }
            return text.displayTag(name, focused: frame.metadata.isOnFocusDisplay)
        }
    }

    /// 多屏时每块屏幕一行概况：焦点时长与画面变化。画面变化只是事实记录，不代表用户在操作那块屏幕。
    private func displayOverview(_ batch: ExtractionBatch, displays: DisplayLabels) -> [(Date, String)] {
        guard displays.isMulti else { return [] }
        let frames = batch.frames
        let ticks = Set(frames.map(\.wallTime)).count
        var parts: [String] = []
        for (id, name) in displays.all {
            let own = frames.filter { $0.metadata.displayId == id }
            let focused = Set(own.filter(\.metadata.isOnFocusDisplay).map(\.wallTime)).count
            let comparable = own.filter { $0.metadata.changeDistance != nil }
            let changed = comparable.filter { $0.metadata.duplicateOf == nil }.count
            parts.append(text.overview(
                name, focusPercent: Int((Double(focused) / Double(max(1, ticks)) * 100).rounded()),
                changed: comparable.isEmpty ? nil : changed, of: comparable.count
            ))
        }
        return [(batch.range.start, "\(clock(batch.range.start)) \(text.overviewTag) " + parts.joined(separator: text.overviewSeparator))]
    }

    private func timelineLine(_ frame: PerceptionEvent, displays: DisplayLabels, description: String?, ocrText: String) -> String {
        var line = clock(frame.wallTime)
        if let tag = displays.tag(frame) { line += " \(tag)" }
        // 前台应用只对焦点屏有意义；副屏上显示的通常是别的应用。
        if frame.metadata.isOnFocusDisplay {
            line += " [\(frame.metadata.app ?? text.unknownApp)]"
        }
        if let description, !description.isEmpty {
            line += text.screen(description)
        } else if !ocrText.isEmpty {
            let hint = ocrText.replacingOccurrences(of: "\n", with: " ").prefix(120)
            line += text.expiredWithText(String(hint))
        } else {
            line += frame.metadata.isOnFocusDisplay ? text.expiredFocused : text.expired
        }
        if frame.metadata.isOnFocusDisplay, let idle = frame.metadata.idleSeconds, idle >= 60 {
            line += text.idleFor(Int(idle))
        }
        return line
    }

    private func frameRange(_ frame: PerceptionEvent) -> TimeRange {
        TimeRange(start: frame.wallTime, end: frame.wallTime.addingTimeInterval(options.batching.frameSpan))
    }

    private func appAttributes(_ frame: PerceptionEvent) -> [String: String] {
        var a: [String: String] = [:]
        if let app = frame.metadata.app { a["app"] = app }
        if let id = frame.metadata.bundleId { a["bundleId"] = id }
        return a
    }

    private func uniqueApps(_ frames: [PerceptionEvent]) -> [String] {
        var seen = Set<String>()
        return frames.compactMap(\.metadata.bundleId).filter { seen.insert($0).inserted }
    }

    private func union(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set(a)
        return a + b.filter { seen.insert($0).inserted }
    }

    /// 证据过多时保留首尾并均匀抽样。
    private func capped(_ evidence: [Evidence]) -> [Evidence] {
        let limit = options.evidencePerSegment
        guard evidence.count > limit else { return evidence }
        let idx = FrameSelector.uniform(Array(evidence.indices), count: limit)
        return idx.map { evidence[$0] }
    }

    private func clock(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = deps.timeZone
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

import AmaiCore
import AmaiMemory
import Foundation

/// 一段对话。每一轮是一条固定的流水线，全部由后端完成，模型只负责最后一步：
///
///   读屏幕上下文 ─┐
///                 ├→ 组装提示词 → 模型流式生成
///   检索记忆 ─────┘
///
/// - 不依赖工具调用：记忆由 `MemoryRecall` 在调用模型之前检索好放进提示词，
///   所以不会调用工具的本地小模型、没有工具能力的云端来源都能完整地做记忆问答；
/// - 模型无关：只面向 `ChatModel`，本地 MLX 与云端 Provider 走同一条路径；
/// - 消息列表只追加：每一轮在末尾加上"上下文 + 记忆 + 问题"和模型的回复，已发出的内容不改写；
/// - 提前准备：`prepare()` 在面板唤出时就读屏幕、预热模型，并把屏幕上下文预先算进模型的缓存，
///   提交时只剩记忆和问题要处理；
/// - 只读：不写记忆、不操作其他应用。
///
/// 今后要加 Agent 能力（让模型自己决定调用工具）时，`ChatModel` 的工具调用契约与各 Provider 的实现都还在，
/// 在这条流水线之上加一个循环即可；普通问答不需要它。
public actor AssistantSession {
    public struct Configuration: Sendable {
        public var maxTokens = 2048
        public var temperature: Float = 0.3
        /// 历史超过这个字符数时丢掉最早的轮次（会让缓存从头重建一次）。
        public var maxHistoryCharacters = 80_000
        /// 面板唤出时准备的上下文最多用多久。屏幕没变也有上限：上下文里的时间是准备时的时间。
        public var preparedContextMaxAge: TimeInterval = 600

        public init() {}
    }

    public struct TurnOptions: Sendable {
        /// 是否带上实时上下文（应用、选区、屏幕文字、最近状态）。
        public var includeLiveContext = true
        /// 用户明确要求随这条消息带上屏幕截图。
        public var attachScreen: ScreenScope?
        /// 已经读好的焦点信息（打开面板时经复制读到的选区：面板出现前就读了）。
        public var focus: FocusSnapshot?
        /// 是否检索记忆。翻译、润色这类只处理选中文字的请求不需要记忆，检索只会带来无关的来源。
        public var includeMemory = true

        public init(
            includeLiveContext: Bool = true, attachScreen: ScreenScope? = nil, focus: FocusSnapshot? = nil,
            includeMemory: Bool = true
        ) {
            self.includeLiveContext = includeLiveContext
            self.attachScreen = attachScreen
            self.focus = focus
            self.includeMemory = includeMemory
        }
    }

    /// 最近一轮各阶段的耗时（性能检查与日志用）。
    public struct Timings: Sendable, Equatable {
        /// 从提交到开始调用模型：确认屏幕上下文、检索记忆、组装提示词。
        public var preparationMs = 0
        /// 其中记忆检索花的时间。
        public var memoryMs = 0
        /// 从提交到模型输出第一段文字。
        public var firstTextMs: Int?
        public var usedPreparedContext = false
    }

    private let model: any ChatModel
    private let recall: MemoryRecall?
    private let live: (any LiveContextReading)?
    private let builder: ContextBuilder
    private let configuration: Configuration
    private let clock: any AmaiClock
    private let system: String

    /// 发给模型的消息（含上下文块与记忆块）。
    public private(set) var transcript: [ChatMessage] = []
    public private(set) var lastTimings = Timings()
    private var busy = false
    private var lastScreenText: String?
    private var lastRecentSeen: Date?
    private var lastQuestion: String?
    /// 最近一个提到日期的问题指向的日期（下一个问题说"那天"时沿用）。
    private var lastDays: [String] = []
    /// 这段对话里已经放进过提示词的记忆。
    private var shownMemory = Set<String>()

    /// 读好的一份屏幕上下文，以及采用它之后要记下的状态。
    private struct Collected: Sendable {
        var context: ContextBuilder.LiveContext
        var summary = TurnContextSummary()
        var block: String
        var screenText: String?
        var recentSeen: Date?
    }

    private var prepared: Collected?
    private var collecting: Task<Collected, Never>?
    /// 每次 `prepare` 或发送都加一：较早的 `prepare` 醒来后发现自己过期，就不再往下做。
    private var generation = 0

    public init(
        model: any ChatModel,
        memory: MemoryAPI?,
        live: (any LiveContextReading)?,
        builder: ContextBuilder,
        configuration: Configuration = Configuration(),
        clock: any AmaiClock = SystemClock()
    ) {
        self.model = model
        self.live = live
        self.builder = builder
        self.configuration = configuration
        self.clock = clock
        let recall = memory.map { MemoryRecall(api: $0, timeZone: builder.timeZone) }
        self.recall = recall?.isEnabled == true ? recall : nil
        self.system = builder.systemPrompt(hasMemory: self.recall != nil)
    }

    public nonisolated var modelIdentifier: String { model.identifier }
    public nonisolated var sendsDataOffDevice: Bool { model.sendsDataOffDevice }

    /// 从保存的会话恢复：只恢复用户与助手的文字（当时的上下文块与记忆块不保存）。
    public func restore(_ messages: [DisplayMessage]) async {
        transcript = messages.map { $0.role == .user ? .user($0.text) : .assistant($0.text) }
        lastQuestion = messages.last { $0.role == .user }?.text
        await clearTurnState()
    }

    /// 开始新对话，释放与旧对话绑定的缓存。
    public func reset() async {
        transcript = []
        lastQuestion = nil
        await clearTurnState()
    }

    private func clearTurnState() async {
        generation += 1
        prepared = nil
        collecting = nil
        lastScreenText = nil
        lastRecentSeen = nil
        lastDays = []
        shownMemory = []
        await model.resetConversation()
    }

    // MARK: - Prepare

    /// 在用户提交问题之前做好能做的事。面板唤出、用户换了窗口、上一轮结束后调用；可以反复调用。
    ///
    /// 三件事同时开始：加载模型并预热系统提示词与历史；更新记忆索引、加载向量模型；读焦点并对当前窗口做 OCR。
    /// 屏幕上下文读好后，再把它预先算进模型的缓存。返回读到的上下文摘要（界面上显示"正在看…"）。
    @discardableResult
    public func prepare(focus: FocusSnapshot? = nil) async -> TurnContextSummary? {
        guard !busy else { return nil }
        generation += 1
        let mine = generation
        let history = transcript
        let recall = recall
        async let warmed: Void = model.prepare(request(history))
        async let indexed: Void = { await recall?.prepare() }()

        let task = Task { await self.collect(focus: focus) }
        collecting = task
        let collected = await task.value
        if collecting == task { collecting = nil }
        if mine == generation, !busy { prepared = collected }
        _ = await (warmed, indexed)
        guard mine == generation, !busy else { return collected.summary }
        await model.prepare(request(history + [.user(collected.block)]))
        return collected.summary
    }

    private func request(_ messages: [ChatMessage]) -> ChatRequest {
        ChatRequest(
            system: system, messages: messages,
            maxTokens: configuration.maxTokens, temperature: configuration.temperature
        )
    }

    // MARK: - Send

    /// 发送一条消息。取消：终止对返回流的迭代。出错或取消时这一轮从历史中撤回。
    public nonisolated func send(_ text: String, options: TurnOptions = TurnOptions()) -> AsyncThrowingStream<AssistantEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AssistantEvent, Error>.makeStream()
        let task = Task {
            do {
                try await self.runTurn(text, options: options, continuation: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func runTurn(
        _ text: String, options: TurnOptions, continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async throws {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AssistantError.emptyMessage }
        guard !busy else { throw AssistantError.busy }
        busy = true
        defer { busy = false }
        generation += 1

        let checkpoint = (transcript, lastScreenText, lastRecentSeen, lastQuestion, shownMemory, lastDays)
        do {
            try await turn(question, options: options, continuation: continuation)
        } catch {
            // 这一轮没有完整结束：撤回，保持历史与界面上保存的内容一致。本地缓存由模型实现按实际内容对齐。
            (transcript, lastScreenText, lastRecentSeen, lastQuestion, shownMemory, lastDays) = checkpoint
            throw error
        }
    }

    private func turn(
        _ question: String, options: TurnOptions, continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    ) async throws {
        let started = Date()
        var timings = Timings()
        trimHistory()
        // 旧消息里的截图不再发送：屏幕早就变了，留着只会占上下文。
        for index in transcript.indices { transcript[index].images = [] }

        // 记忆检索与屏幕上下文的确认同时进行。
        let recall = options.includeMemory ? recall : nil
        let (previous, days, shown, now) = (lastQuestion, lastDays, shownMemory, clock.now())
        async let recalling: (memory: RecalledMemory?, ms: Int) = {
            let started = Date()
            let memory = await recall?.recall(
                question: question, previousQuestion: previous, previousDays: days, shown: shown, now: now
            )
            return (memory, Int(Date().timeIntervalSince(started) * 1000))
        }()

        // 面板唤出时的读取如果还没结束，等它（它的 OCR 结果马上就能用上）。
        var ahead = prepared
        if let collecting {
            ahead = await collecting.value
            self.collecting = nil
        }
        prepared = nil

        var collected: Collected
        if options.includeLiveContext {
            // 再读一次做确认。屏幕没变时这一步很快（截图一次，OCR 用缓存），并且沿用准备好的那一份——
            // 它的文字已经在模型的缓存里了。
            let fresh = await collect(focus: options.focus)
            if let ahead, ahead.context.showsSameScreen(as: fresh.context),
               now.timeIntervalSince(ahead.context.time) <= configuration.preparedContextMaxAge {
                collected = ahead
                collected.summary.usedPreparedContext = true
            } else {
                collected = fresh
            }
        } else {
            var context = ContextBuilder.LiveContext(time: now)
            context.focus = options.focus
            collected = Collected(context: context, block: builder.contextBlock(context))
            collected.summary.appName = options.focus?.appName
            collected.summary.hasSelection = !(options.focus?.selectedText ?? "").isEmpty
        }

        var images: [ChatImage] = []
        var screenNote: String?
        if let scope = options.attachScreen, let live {
            let look = await ScreenLook.look(live: live, scope: scope, modelSeesImages: model.supportsImages)
            images = look.images
            screenNote = look.note
            collected.summary.includesScreenshot = true
        }

        let recalled = await recalling
        try Task.checkCancellation()
        let sources = recalled.memory?.sources ?? []
        collected.summary.memorySourceCount = sources.count
        timings.memoryMs = recalled.ms
        timings.usedPreparedContext = collected.summary.usedPreparedContext

        if let text = collected.screenText { lastScreenText = text }
        if let seen = collected.recentSeen { lastRecentSeen = seen }
        shownMemory.formUnion(recalled.memory?.keys ?? [])
        if let days = recalled.memory?.days, !days.isEmpty { lastDays = days }
        lastQuestion = question
        transcript.append(.user(
            builder.userMessage(
                contextBlock: collected.block, memory: recalled.memory?.text.nilIfEmpty, screenNote: screenNote, question: question
            ),
            images: images
        ))
        timings.preparationMs = Int(Date().timeIntervalSince(started) * 1000)
        continuation.yield(.context(collected.summary))

        var answer = ""
        for try await event in model.stream(request(transcript)) {
            guard case .text(let delta) = event else { continue }
            if timings.firstTextMs == nil { timings.firstTextMs = Int(Date().timeIntervalSince(started) * 1000) }
            answer += delta
            continuation.yield(.text(delta))
        }
        try Task.checkCancellation()
        lastTimings = timings
        transcript.append(.assistant(answer))
        continuation.yield(.finished(text: answer.trimmingCharacters(in: .whitespacesAndNewlines), sources: sources))
    }

    // MARK: - Context

    /// 读一份实时上下文。任何一项读不到都只是缺这一项。不修改会话状态：采用与否由调用方决定。
    private func collect(focus given: FocusSnapshot?) async -> Collected {
        var context = ContextBuilder.LiveContext(time: clock.now())
        var summary = TurnContextSummary()
        var screenText: String?
        var recentSeen: Date?
        guard let live else {
            context.focus = given
            return Collected(context: context, summary: summary, block: builder.contextBlock(context))
        }
        // 焦点（辅助功能）与屏幕文字（截图 + OCR）互不依赖，同时读。
        async let reading: Result<String, LiveContextError> = {
            do {
                return .success(try await live.screenText(.focusedWindow, maxAge: 2))
            } catch let error as LiveContextError {
                return .failure(error)
            } catch {
                return .failure(.unavailable("capture failed"))
            }
        }()
        let focus: FocusSnapshot
        if let given { focus = given } else { focus = await live.focus() }
        context.focus = focus
        summary.appName = focus.appName
        summary.windowTitle = focus.windowTitle
        summary.hasSelection = !(focus.selectedText ?? "").isEmpty

        switch await reading {
        case .success(let text):
            if let last = lastScreenText, ContextBuilder.isSameScreenText(last, text) {
                context.screenUnchanged = true
            } else if !text.isEmpty {
                context.screenText = text
                screenText = text
                summary.includesScreenText = true
            }
        case .failure(.blocked(let reason)):
            context.blockedReason = reason
            summary.blockedReason = reason
        case .failure:
            // 没有屏幕录制权限或截图失败：不带屏幕文字。
            break
        }

        // 最近状态：只带上一轮之后新出现的，并去掉与当前屏幕基本相同的那个。
        let current = context.screenText ?? lastScreenText ?? ""
        let recent = await live.recentStates().filter { state in
            if let seen = lastRecentSeen, state.lastSeen <= seen { return false }
            return !ContextBuilder.isSameScreenText(state.text, current, threshold: 0.7)
        }
        context.recent = recent
        summary.recentStateCount = min(recent.count, ContextBuilder.maxRecentStates)
        recentSeen = recent.map(\.lastSeen).max()
        return Collected(
            context: context, summary: summary, block: builder.contextBlock(context),
            screenText: screenText, recentSeen: recentSeen
        )
    }

    /// 历史过长时丢掉最早的完整轮次（从一条 user 消息到下一条 user 消息之前）。
    private func trimHistory() {
        func size() -> Int { transcript.reduce(0) { $0 + $1.text.count } }
        var trimmed = false
        while size() > configuration.maxHistoryCharacters {
            guard let next = transcript.dropFirst().firstIndex(where: { $0.role == .user }) else { break }
            transcript.removeFirst(next)
            trimmed = true
        }
        // 被丢掉的轮次里可能有之前给过的记忆：清空记录，需要时重新给。
        if trimmed { shownMemory = [] }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import AmaiCore
import CoreImage
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import os
import Tokenizers

/// 本机已加载模型的登记处：同一个模型标签在进程内只有一个 `LocalModelHost`，
/// 抽取、记忆整理、Agent 选了同一个本地模型时共用一份权重。
public enum LocalModelRuntime {
    private static let hosts = OSAllocatedUnfairLock(initialState: [String: LocalModelHost]())

    public static func host(for modelTag: String) -> LocalModelHost {
        hosts.withLock { table in
            if let host = table[modelTag] { return host }
            let host = LocalModelHost(modelTag: modelTag)
            table[modelTag] = host
            return host
        }
    }

    /// 交互式请求要加载 `modelTag` 之前调用：如果它与已加载的其他模型加起来超过本机内存的六成，
    /// 先卸载其他模型（此时闸门在调用方手里，其他模型都没有在生成）。
    static func makeRoom(for modelTag: String) async {
        let others = hosts.withLock { $0.filter { $0.key != modelTag }.map(\.value) }
        var loaded: [LocalModelHost] = []
        for host in others where await host.isLoaded { loaded.append(host) }
        guard !loaded.isEmpty else { return }
        func memory(_ tag: String) -> Int { LocalModelCatalog.option(for: tag)?.memoryGB ?? 8 }
        let total = memory(modelTag) + loaded.map { memory($0.modelTag) }.reduce(0, +)
        guard Double(total) > Double(LocalModelCatalog.machineMemoryGB) * 0.6 else { return }
        for host in loaded { await host.unload(reason: "making room for \(modelTag)") }
    }
}

/// 一个本地 MLX 模型的唯一持有者（mlx-swift-lm 嵌入式，ADR-0002；会话缓存部分移植自 Eira 的 MLXClient）。
///
/// - 按需加载，空闲一段时间后卸载；设为常驻（助手的对话模型，参考 Eira）时不做空闲卸载；
///   macOS 内存压力达到 critical 时照样卸载（用户正在对话时暂缓）；
/// - 模型未在本地时直接报错，绝不在后台自动下载；
/// - 所有生成都经过 `InferenceGate`，交互式请求优先于后台；
/// - 单次调用（抽取、整理）每次新建会话；对话保留 KV cache，下一轮只需处理新增的部分。
///
/// 对话有两条路径：
/// - **前缀缓存**（纯文字、不带工具的请求，即普通问答）：自己持有 KV cache 和"缓存里是哪些 token"的账本。
///   每次把完整的提示词渲染成 token，与账本比较，只把多出来的部分喂给模型。因为比较的是 token 而不是消息，
///   所以可以在用户还没写完问题时先把已知的前缀算进去（`prefill`），提交时接着算剩下的；
/// - **会话**（带图片、带工具或一次性的请求）：交给 mlx-swift-lm 的 `ChatSession`，它负责图片与工具调用的细节。
public actor LocalModelHost {
    public nonisolated let modelTag: String

    /// 与 LocalModelCatalog 保持一致。
    private static let knownConfigurations: [String: ModelConfiguration] = [
        "mlx-community/gemma-4-e2b-it-4bit": VLMRegistry.gemma4_E2B_it_4bit,
        "mlx-community/gemma-4-e4b-it-4bit": VLMRegistry.gemma4_E4B_it_4bit,
        "mlx-community/gemma-3-12b-it-qat-4bit": VLMRegistry.gemma3_12B_qat_4bit,
        "mlx-community/gemma-4-26b-a4b-it-4bit": VLMRegistry.gemma4_26BA4B_it_4bit,
    ]

    /// 限制 MLX 的缓冲复用池，图像 prefill 的临时缓冲在调用结束后归还系统（Eira 实测）。
    private static let cacheLimitBytes = 1024 * 1_048_576
    /// 用户最近一次对话后的这段时间内，内存压力不卸载模型：否则下一句要等 10–30 秒冷启动。
    private static let chatActivityGrace: TimeInterval = 120
    /// dHash 汉明距离不超过此值视为"同一屏"（光标闪烁、时钟跳动不算变化）。
    private static let sameScreenThreshold = 5

    private let configuration: ModelConfiguration
    private let gate: InferenceGate
    /// 空闲多久后卸载；nil 表示常驻。
    private var idleUnloadAfter: TimeInterval? = 300
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var unloadTask: Task<Void, Never>?
    private let memoryPressure: any DispatchSourceMemoryPressure
    private var lastChatActivity: Date?
    private let log = AmaiLog.logger("inference.model")

    /// 保留着 KV cache 的对话。`signature` 是已经进入缓存的消息（含模型自己的回复）的指纹序列：
    /// 下一个请求的消息列表以它为前缀时，只需把多出来的消息喂给同一个会话。
    private final class HeldSession {
        let id = UUID()
        let key: Int
        let session: MLXLMCommon.ChatSession
        var signature: [Int]
        var lastImageHash: UInt64?

        init(key: Int, session: MLXLMCommon.ChatSession, signature: [Int]) {
            self.key = key
            self.session = session
            self.signature = signature
        }
    }

    private var held: HeldSession?

    /// 前缀缓存：一份 KV cache 加上它里面依次是哪些 token。只在持有闸门时读写。
    private final class PrefixCache: @unchecked Sendable {
        var cache: [KVCache]
        var tokens: [Int]

        init(cache: [KVCache], tokens: [Int] = []) {
            self.cache = cache
            self.tokens = tokens
        }

        func copy() -> PrefixCache {
            PrefixCache(cache: cache.map { $0.copy() }, tokens: tokens)
        }

        /// 各层缓存实际处理过的 token 数（与账本对不上就说明缓存不可信）。
        var processed: Int { cache.map(\.offset).max() ?? 0 }
    }

    /// 上一轮完整结束后的缓存：系统提示词、历史和上一个回答。
    private var committed: PrefixCache?
    /// 在 `committed` 的副本上预先算进了"下一条消息的开头"（屏幕上下文）的缓存。
    /// 用副本是因为这段开头可能作废（用户换了窗口、最后没有提问）：Gemma 的滑动窗口层超过窗口长度后不能回退，
    /// 直接算在 `committed` 上的话，一旦作废就得把整段历史重算。
    private var speculative: PrefixCache?

    /// 最近一次前缀缓存请求的统计（测试、日志与性能检查用）。
    public struct PrefixStats: Sendable, Equatable {
        /// 提示词的总 token 数。
        public var promptTokens = 0
        /// 其中已经在缓存里、不需要再算的。
        public var cachedTokens = 0
        /// 处理新增 token 花的时间（毫秒）。对话请求里这就是"提交到第一个字"之前模型侧的等待。
        public var prefillMs = 0
    }

    public private(set) var lastPrefill = PrefixStats()
    public private(set) var lastChat = PrefixStats()

    /// 最近一次对话请求是否复用了 KV cache（测试与日志用）。
    public private(set) var lastChatReusedCache = false
    /// 最近一次对话请求是否因为屏幕没变而跳过了图片（测试与日志用）。
    public private(set) var lastChatSkippedImage = false

    init(modelTag: String, gate: InferenceGate = .shared) {
        self.modelTag = modelTag
        self.gate = gate
        self.configuration = Self.knownConfigurations[modelTag] ?? ModelConfiguration(id: modelTag)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global(qos: .utility))
        self.memoryPressure = source
        source.setEventHandler { [weak self] in
            Task { await self?.unloadUnderPressure() }
        }
        source.resume()
    }

    public var isLoaded: Bool { container != nil }

    /// 空闲卸载的时长；nil 表示常驻（只有 critical 内存压力才释放）。
    public func setIdleUnload(after seconds: TimeInterval?) {
        idleUnloadAfter = seconds
        if seconds == nil {
            unloadTask?.cancel()
            unloadTask = nil
        } else if container != nil {
            scheduleUnload()
        }
    }

    /// 在后台提前加载权重，让第一次对话直接进入预填充（冷加载 5–15 秒）。模型没下载时什么也不做，
    /// 绝不触发下载。
    public func warmUp() async {
        guard container == nil, LocalInferenceBackend.isInstalled(tag: modelTag) else { return }
        do {
            _ = try await loadContainer(priority: .interactive)
            scheduleUnload()
        } catch {
            log.error("warm up failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: - 单次调用

    public func generate(
        _ request: ModelRequest, identifier: String, priority: InferencePriority
    ) async throws -> ModelResponse {
        guard LocalInferenceBackend.isInstalled(tag: modelTag) else {
            throw ModelProviderError.modelNotInstalled(modelTag)
        }
        try await gate.acquire(priority)
        defer { gate.release(priority) }
        unloadTask?.cancel()
        defer { scheduleUnload() }
        let started = Date()
        let container = try await loadContainer(priority: priority)

        var params = GenerateParameters()
        params.maxTokens = request.maxTokens
        params.temperature = request.temperature
        let session = MLXLMCommon.ChatSession(
            container,
            instructions: request.cacheable.isEmpty ? nil : request.cacheable,
            generateParameters: params
        )
        let images: [UserInput.Image] = request.images
            .compactMap { CIImage(data: $0) }
            .map { .ciImage($0) }

        let raw: String
        do {
            raw = try await session.respond(to: request.dynamic, images: images, videos: [], audios: [])
        } catch {
            throw ModelProviderError.generationFailed(String(describing: type(of: error)))
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return ModelResponse(text: ThinkingFilter.clean(raw), provider: identifier, latencyMs: ms)
    }

    // MARK: - 对话

    public nonisolated func chat(
        _ request: ChatRequest, priority: InferencePriority = .interactive
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        let gate = self.gate
        let task = Task {
            do {
                try await gate.acquire(priority)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            defer { gate.release(priority) }
            if Self.usesPrefixCache(request) {
                await self.runPrefixChat(request, priority: priority, continuation: continuation)
            } else {
                await self.runChat(request, priority: priority, continuation: continuation)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func resetChat() {
        held = nil
        committed = nil
        speculative = nil
    }

    // MARK: - 前缀缓存

    private static func usesPrefixCache(_ request: ChatRequest) -> Bool {
        !request.ephemeral && request.tools.isEmpty && request.messages.last?.images.isEmpty != false
    }

    /// 提前处理一个对话请求的前缀：加载模型，并把能确定的部分算进 KV cache。
    ///
    /// `request.messages` 的最后一条如果是 user 消息，表示"下一条消息会以这段文字开头"（之后只会在末尾追加）；
    /// 否则只预热系统提示词与历史。返回这次新算进缓存的 token 数；请求带工具或图片时不做预填充，返回 0。
    @discardableResult
    public func prefill(_ request: ChatRequest, priority: InferencePriority = .interactive) async -> Int {
        guard Self.usesPrefixCache(request), LocalInferenceBackend.isInstalled(tag: modelTag) else { return 0 }
        do {
            try await gate.acquire(priority)
        } catch {
            return 0
        }
        defer { gate.release(priority) }
        unloadTask?.cancel()
        defer { scheduleUnload() }
        if priority == .interactive { lastChatActivity = Date() }
        do {
            let container = try await loadContainer(priority: priority)
            guard !Task.isCancelled else { return 0 }
            let bases = [speculative, committed].compactMap { $0 }
            let started = Date()
            let result: (cache: PrefixCache, stats: PrefixStats)? = try await container.perform { context in
                // 最后一条消息还会变长，所以它的结尾（以及模板在它后面加的内容）不能进缓存。
                // 用两个不同的后续渲染两遍，取公共部分，再退几个 token：分词器可能把边界两侧的字符合并成一个 token。
                var messages = request.messages
                if messages.last?.role != .user { messages.append(.user("")) }
                let last = messages.count - 1
                func render(_ suffix: String) async throws -> [Int] {
                    var probe = messages
                    probe[last].text += suffix
                    return try await Self.promptTokens(system: request.system, messages: probe, context: context)
                }
                let a = try await render("\n\nA")
                let b = try await render("\n\n1")
                let target = Array(a.prefix(max(0, Self.commonPrefix(a, b) - 3)))
                guard !target.isEmpty else { return nil }

                // 从已有的缓存里选一个能直接接着算的；用它的副本，原件留给"这段前缀作废"的情况。
                var base: PrefixCache?
                for candidate in bases.sorted(by: { $0.tokens.count > $1.tokens.count })
                where candidate.tokens.count <= target.count && Self.commonPrefix(candidate.tokens, target) == candidate.tokens.count {
                    base = candidate
                    break
                }
                let cache = try base?.copy() ?? PrefixCache(cache: context.model.newCache(parameters: GenerateParameters()))
                let reused = cache.tokens.count
                let suffix = Array(target[reused...])
                if !suffix.isEmpty {
                    // 构造迭代器就会把这些 token 算进缓存（并采样出下一个 token，这里不用它）。
                    _ = try TokenIterator(
                        input: LMInput(tokens: MLXArray(suffix)), model: context.model, cache: cache.cache,
                        parameters: GenerateParameters(maxTokens: 1)
                    )
                    eval(cache.cache.flatMap { $0.state })
                    cache.tokens = target
                }
                guard cache.processed == cache.tokens.count else { return nil }
                return (cache, PrefixStats(promptTokens: target.count, cachedTokens: reused, prefillMs: 0))
            }
            guard let result else { return 0 }
            speculative = result.cache
            var stats = result.stats
            stats.prefillMs = Int(Date().timeIntervalSince(started) * 1000)
            lastPrefill = stats
            log.info("prefill: \(stats.promptTokens - stats.cachedTokens) new of \(stats.promptTokens) tokens in \(stats.prefillMs) ms")
            return stats.promptTokens - stats.cachedTokens
        } catch {
            log.error("prefill failed: \(String(describing: type(of: error)), privacy: .public)")
            return 0
        }
    }

    private func runPrefixChat(
        _ request: ChatRequest, priority: InferencePriority,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        if priority == .interactive { lastChatActivity = Date() }
        // 这条路径不用会话缓存；留着只占内存。
        held = nil
        do {
            guard LocalInferenceBackend.isInstalled(tag: modelTag) else {
                throw ModelProviderError.modelNotInstalled(modelTag)
            }
            guard !request.messages.isEmpty else {
                throw ModelProviderError.generationFailed("empty request")
            }
            let container = try await loadContainer(priority: priority)
            let bases = [speculative, committed].compactMap { $0 }
            // 生成期间两份缓存都当作已交出：正常结束后新的缓存成为 `committed`，否则都作废。
            committed = nil
            speculative = nil
            let started = Date()
            let outcome: (cache: PrefixCache?, stats: PrefixStats, output: Int, completed: Bool) = try await container.perform { context in
                let prompt = try await Self.promptTokens(system: request.system, messages: request.messages, context: context)
                var params = GenerateParameters()
                params.maxTokens = request.maxTokens
                params.temperature = request.temperature

                // 选公共前缀最长的缓存。账本整个是提示词的前缀时直接接着算；否则试着把缓存回退到公共前缀
                // （超过滑动窗口后退不了），都不行就从头算。
                var chosen: PrefixCache?
                for candidate in bases.sorted(by: { Self.commonPrefix($0.tokens, prompt) > Self.commonPrefix($1.tokens, prompt) }) {
                    let common = Self.commonPrefix(candidate.tokens, prompt)
                    guard common > 0, common < prompt.count else { continue }
                    let extra = candidate.tokens.count - common
                    if extra > 0 {
                        guard canTrimPromptCache(candidate.cache) else { continue }
                        _ = trimPromptCache(candidate.cache, numTokens: extra)
                        guard candidate.processed == common else { continue }
                        candidate.tokens = Array(candidate.tokens.prefix(common))
                    }
                    chosen = candidate
                    break
                }
                let cache = try chosen ?? PrefixCache(cache: context.model.newCache(parameters: params))
                let reused = cache.tokens.count
                var stats = PrefixStats(promptTokens: prompt.count, cachedTokens: reused, prefillMs: 0)

                var iterator = try TokenIterator(
                    input: LMInput(tokens: MLXArray(Array(prompt[reused...]))), model: context.model,
                    cache: cache.cache, parameters: params
                )
                stats.prefillMs = Int(Date().timeIntervalSince(started) * 1000)

                let stops = Self.stopTokens(context)
                var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                var filter = ThinkingFilter()
                var fed = prompt
                var output = 0
                var completed = true
                // `next()` 返回的 token 此时已经喂进了缓存（包括结束符），所以账本逐个跟着记。
                while let token = iterator.next() {
                    fed.append(token)
                    if stops.contains(token) { break }
                    if Task.isCancelled {
                        completed = false
                        break
                    }
                    output += 1
                    detokenizer.append(token: token)
                    if let piece = detokenizer.next() {
                        let visible = filter.feed(piece)
                        if !visible.isEmpty { continuation.yield(.text(visible)) }
                    }
                }
                if completed {
                    let rest = filter.finish()
                    if !rest.isEmpty { continuation.yield(.text(rest)) }
                }
                eval(cache.cache.flatMap { $0.state })
                // 账本与缓存实际处理的 token 数对不上（例如达到 maxTokens 时最后一个 token 还没喂进去）：按实际的截断。
                // 被取消的一轮也留着缓存：账本如实记录了里面有什么，下一个请求会按公共前缀回退或重建。
                cache.tokens = Array(fed.prefix(cache.processed))
                return (cache.processed <= fed.count ? cache : nil, stats, output, completed)
            }
            lastChat = outcome.stats
            lastChatReusedCache = outcome.stats.cachedTokens > 0
            lastChatSkippedImage = false
            log.info("chat: \(outcome.stats.cachedTokens) of \(outcome.stats.promptTokens) prompt tokens cached, prefill \(outcome.stats.prefillMs) ms")
            committed = outcome.cache
            guard outcome.completed else {
                continuation.finish(throwing: CancellationError())
                return
            }
            if priority == .interactive { lastChatActivity = Date() }
            continuation.yield(.finished(ChatUsage(
                inputTokens: outcome.stats.promptTokens, outputTokens: outcome.output,
                cachedInputTokens: outcome.stats.cachedTokens
            )))
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
        } catch let error as ModelProviderError {
            continuation.finish(throwing: error)
        } catch {
            log.error("chat failed: \(String(describing: type(of: error)), privacy: .public)")
            continuation.finish(throwing: ModelProviderError.generationFailed(error.localizedDescription))
        }
    }

    /// 把 system 与消息按模型的对话模板渲染成 token。system 作为第一条消息。
    private static func promptTokens(system: String, messages: [ChatMessage], context: ModelContext) async throws -> [Int] {
        var chat: [Chat.Message] = system.isEmpty ? [] : [.system(system)]
        chat += messages.map { convert($0, includeImages: false) }
        let input = try await context.processor.prepare(input: UserInput(chat: chat))
        return input.text.tokens.asArray(Int.self)
    }

    private static func stopTokens(_ context: ModelContext) -> Set<Int> {
        var stops = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { stops.insert(eos) }
        if let unknown = context.tokenizer.unknownTokenId { stops.insert(unknown) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { stops.insert(id) }
        }
        return stops
    }

    static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var index = 0
        let limit = min(a.count, b.count)
        while index < limit, a[index] == b[index] { index += 1 }
        return index
    }

    private func runChat(
        _ request: ChatRequest, priority: InferencePriority,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        if priority == .interactive { lastChatActivity = Date() }
        var turn: UUID?
        do {
            guard LocalInferenceBackend.isInstalled(tag: modelTag) else {
                throw ModelProviderError.modelNotInstalled(modelTag)
            }
            guard !request.messages.isEmpty else {
                throw ModelProviderError.generationFailed("empty request")
            }
            let container = try await loadContainer(priority: priority)
            let prepared = prepare(request, container: container)
            turn = prepared.turn

            var filter = ThinkingFilter()
            var text = ""
            var calls: [ChatToolCall] = []
            var usage = ChatUsage(cachedInputTokens: prepared.reused ? 1 : 0)
            for try await event in prepared.stream {
                if Task.isCancelled { break }
                switch event {
                case .chunk(let chunk):
                    let visible = filter.feed(chunk)
                    if !visible.isEmpty {
                        text += visible
                        continuation.yield(.text(visible))
                    }
                case .toolCall(let call):
                    let converted = Self.convert(call)
                    calls.append(converted)
                    continuation.yield(.toolCall(converted))
                case .rejectedToolCall(let rejected):
                    log.info("tool call rejected: \(rejected.reason.rawValue, privacy: .public)")
                case .info(let info):
                    usage.inputTokens = info.promptTokenCount
                    usage.outputTokens = info.generationTokenCount
                }
            }
            if Task.isCancelled {
                // 生成到一半：缓存里的内容与界面保存的历史对不上，不能再用。
                invalidate(turn)
                continuation.finish(throwing: CancellationError())
                return
            }
            let rest = filter.finish()
            if !rest.isEmpty {
                text += rest
                continuation.yield(.text(rest))
            }
            if let turn, let held, held.id == turn {
                held.signature = request.messages.map(Self.fingerprint)
                    + [Self.fingerprint(.assistant(text, toolCalls: calls))]
            }
            if priority == .interactive { lastChatActivity = Date() }
            continuation.yield(.finished(usage))
            continuation.finish()
        } catch is CancellationError {
            invalidate(turn)
            continuation.finish(throwing: CancellationError())
        } catch let error as ModelProviderError {
            invalidate(turn)
            continuation.finish(throwing: error)
        } catch {
            invalidate(turn)
            log.error("chat failed: \(String(describing: type(of: error)), privacy: .public)")
            continuation.finish(throwing: ModelProviderError.generationFailed(error.localizedDescription))
        }
    }

    private struct Prepared {
        let stream: AsyncThrowingStream<Generation, Error>
        /// 持有会话的标识；一次性请求为 nil。
        let turn: UUID?
        let reused: Bool
    }

    /// 决定复用还是重建会话，并开始生成。
    ///
    /// 复用条件：system 与工具定义相同，且缓存里的消息指纹是本次消息列表的真前缀。
    /// 重建时把最后一条之前的消息作为历史一次性 prefill。system 作为历史的第一条消息而不是 `instructions`：
    /// MLXLMCommon 会在每一轮前重新插入 `instructions`，复用缓存时相当于在对话中间又塞了一遍 system（Eira 的做法）。
    private func prepare(_ request: ChatRequest, container: ModelContainer) -> Prepared {
        var params = GenerateParameters()
        params.maxTokens = request.maxTokens
        params.temperature = request.temperature

        let key = Self.sessionKey(request)
        let fingerprints = request.messages.map(Self.fingerprint)
        var tail: [ChatMessage]
        let session: MLXLMCommon.ChatSession
        var reused = false
        var holder: HeldSession?

        if !request.ephemeral, let held, held.key == key,
           held.signature.count < fingerprints.count,
           Array(fingerprints.prefix(held.signature.count)) == held.signature {
            session = held.session
            session.generateParameters = params
            tail = Array(request.messages[held.signature.count...])
            reused = true
            holder = held
        } else {
            var history: [Chat.Message] = request.system.isEmpty ? [] : [.system(request.system)]
            // 历史里的旧图片不再编码：只有本轮新增的消息带图。
            history += request.messages.dropLast().map { Self.convert($0, includeImages: false) }
            let tools = request.tools.isEmpty ? nil : request.tools.map(Self.toolSpec)
            session = MLXLMCommon.ChatSession(
                container, instructions: nil, history: history, generateParameters: params, tools: tools
            )
            tail = [request.messages[request.messages.count - 1]]
            if !request.ephemeral {
                // 先丢掉旧会话再建新的，让旧的 KV cache 能被释放。
                held = nil
                let fresh = HeldSession(key: key, session: session, signature: Array(fingerprints.dropLast()))
                held = fresh
                holder = fresh
            }
        }

        // 屏幕没变时不重复发送截图：复用的缓存里已经有上一张（重建时一定会发，避免模型"失明"）。
        var skippedImage = false
        if let holder {
            for index in tail.indices {
                tail[index].images.removeAll { image in
                    guard reused, let hash = image.perceptualHash, let last = holder.lastImageHash,
                          (hash ^ last).nonzeroBitCount <= Self.sameScreenThreshold
                    else { return false }
                    skippedImage = true
                    return true
                }
                if let hash = tail[index].images.last?.perceptualHash { holder.lastImageHash = hash }
            }
        }
        lastChatReusedCache = reused
        lastChatSkippedImage = skippedImage
        log.info("chat: \(reused ? "reuse KV cache" : "rebuild", privacy: .public), \(tail.count) new of \(request.messages.count) messages")

        let stream = session.streamDetails(to: tail.map { Self.convert($0, includeImages: true) })
        return Prepared(stream: stream, turn: holder?.id, reused: reused)
    }

    private func invalidate(_ turn: UUID?) {
        if let turn, held?.id == turn { held = nil }
    }

    // MARK: - 加载与卸载

    public func unload(reason: String) {
        guard container != nil || loadTask != nil else { return }
        loadTask?.cancel()
        loadTask = nil
        // 会话强引用着模型容器，也占着 KV cache，一并丢掉才能真正释放内存。
        held = nil
        committed = nil
        speculative = nil
        container = nil
        MLX.Memory.clearCache()
        log.info("model unloaded (\(reason, privacy: .public))")
    }

    private func unloadUnderPressure() {
        if let last = lastChatActivity, Date().timeIntervalSince(last) < Self.chatActivityGrace {
            log.notice("memory pressure: deferring unload, chat active recently")
            return
        }
        unload(reason: "memory pressure")
    }

    private func loadContainer(priority: InferencePriority) async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        if priority == .interactive { await LocalModelRuntime.makeRoom(for: modelTag) }
        let config = configuration
        let tag = modelTag
        // 只用 VLM 工厂加载：通用的 loadModelContainer 会在 VLM 加载失败时静默改用 LLM 工厂，
        // 得到一个能回答文字、却看不到截图的模型（Gemma 4 E4B 曾因此只靠 OCR 文字描述屏幕）。
        // 屏幕理解必须有视觉能力，所以 VLM 加载失败就明确报错。
        let task = Task<ModelContainer, Error> {
            do {
                return try await VLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: config
                )
            } catch {
                throw ModelProviderError.loadFailed("\(tag) could not be loaded as a vision model: \(error)")
            }
        }
        loadTask = task
        let started = Date()
        do {
            let loaded = try await task.value
            container = loaded
            loadTask = nil
            MLX.Memory.cacheLimit = Self.cacheLimitBytes
            log.info("model loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return loaded
        } catch {
            loadTask = nil
            throw error
        }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        guard let delay = idleUnloadAfter else {
            unloadTask = nil
            return
        }
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.unload(reason: "idle")
        }
    }

    // MARK: - 转换

    private static func sessionKey(_ request: ChatRequest) -> Int {
        var hasher = Hasher()
        hasher.combine(request.system)
        for tool in request.tools {
            hasher.combine(tool.name)
            hasher.combine(tool.description)
            hasher.combine(tool.parametersJSON)
        }
        return hasher.finalize()
    }

    /// 消息指纹。不含图片：旧消息里的图片会被调用方去掉，而它们仍在缓存中，不应因此判定为不连续。
    /// 只在进程内使用（缓存不落盘）。
    static func fingerprint(_ message: ChatMessage) -> Int {
        var hasher = Hasher()
        hasher.combine(message.role)
        hasher.combine(message.text)
        hasher.combine(message.toolCallId)
        for call in message.toolCalls {
            hasher.combine(call.id)
            hasher.combine(call.name)
            hasher.combine(call.argumentsJSON)
        }
        return hasher.finalize()
    }

    private static func convert(_ message: ChatMessage, includeImages: Bool) -> Chat.Message {
        let images: [UserInput.Image] = includeImages
            ? message.images.compactMap { CIImage(data: $0.jpeg) }.map { .ciImage($0) }
            : []
        switch message.role {
        case .user:
            return .user(message.text, images: images)
        case .assistant:
            let calls = message.toolCalls.map { call in
                ToolCall(function: .init(name: call.name, arguments: sendable(call.arguments)), id: call.id)
            }
            return .assistant(message.text, toolCalls: calls.isEmpty ? nil : calls)
        case .tool:
            return Chat.Message(
                role: .tool, content: message.text, images: images,
                tool: message.toolCallId.map { .result(id: $0, name: message.toolName) }
            )
        }
    }

    private static func convert(_ call: ToolCall) -> ChatToolCall {
        let arguments = (try? JSONEncoder().encode(call.function.arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // 模型不一定给出调用 id；补一个，供工具结果对应。
        let id = call.id ?? "call_" + UUID().uuidString.prefix(8).lowercased()
        return ChatToolCall(id: id, name: call.function.name, argumentsJSON: arguments)
    }

    private static func toolSpec(_ tool: ChatToolSpec) -> ToolSpec {
        let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) as? [String: Any]
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": sendable(parameters ?? ["type": "object", "properties": [String: Any]()]),
            ] as [String: any Sendable],
        ]
    }

    private static func sendable(_ dictionary: [String: Any]) -> [String: any Sendable] {
        dictionary.mapValues(sendable)
    }

    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let v as String: return v
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return v.boolValue }
            if CFNumberIsFloatType(v) { return v.doubleValue }
            return v.intValue
        case let v as [Any]: return v.map(sendable)
        case let v as [String: Any]: return sendable(v)
        default: return String(describing: value)
        }
    }
}

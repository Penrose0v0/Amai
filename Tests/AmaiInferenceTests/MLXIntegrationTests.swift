import AmaiCore
import Foundation
import Testing
@testable import AmaiInference

/// 用磁盘上的真实模型验证对话路径：流式输出、跨轮复用 KV cache、工具调用往返。
/// 很重，且需要 xctest 可执行文件旁有 mlx.metallib，所以默认跳过：
///
///   cp .build/arm64-apple-macosx/debug/mlx.metallib \
///      .build/arm64-apple-macosx/debug/AmaiPackageTests.xctest/Contents/MacOS/
///   AMAI_MLX_INTEGRATION=1 swift test --filter MLXIntegration
///
/// 模型用 AMAI_MLX_MODEL 指定，默认 Gemma 4 E4B。
@Suite("MLX integration", .enabled(if: ProcessInfo.processInfo.environment["AMAI_MLX_INTEGRATION"] == "1"), .serialized)
struct MLXIntegrationTests {
    static let tag = ProcessInfo.processInfo.environment["AMAI_MLX_MODEL"] ?? LocalInferenceBackend.defaultModelTag

    static func run(_ model: MLXChatModel, _ request: ChatRequest) async throws -> (text: String, calls: [ChatToolCall], seconds: Double) {
        let started = Date()
        var text = ""
        var calls: [ChatToolCall] = []
        for try await event in model.stream(request) {
            switch event {
            case .text(let delta): text += delta
            case .toolCall(let call): calls.append(call)
            case .finished, .providerState: break
            }
        }
        return (text, calls, Date().timeIntervalSince(started))
    }

    @Test("a follow-up turn reuses the KV cache; a diverging history rebuilds")
    func kvCacheReuse() async throws {
        try #require(LocalInferenceBackend.isInstalled(tag: Self.tag))
        let model = MLXChatModel(modelTag: Self.tag)
        await model.resetConversation()
        let system = "You are Amai, a concise assistant. Answer in one short sentence.\n"
            + String(repeating: "The unified memory architecture shares one pool between CPU and GPU. ", count: 150)

        var messages = [ChatMessage.user("What is 2 + 3?")]
        let first = try await Self.run(model, ChatRequest(system: system, messages: messages, maxTokens: 64))
        #expect(!first.text.isEmpty)
        #expect(await model.lastRequestReusedCache == false)

        messages += [.assistant(first.text), .user("And times 4?")]
        let second = try await Self.run(model, ChatRequest(system: system, messages: messages, maxTokens: 64))
        #expect(!second.text.isEmpty)
        #expect(await model.lastRequestReusedCache)
        print("turn 1: \(first.seconds)s, turn 2 (reused): \(second.seconds)s")

        // 历史被改写（不是追加）：必须重建，不能错用缓存。
        let diverged = [ChatMessage.user("What is 7 + 1?"), .assistant("8."), .user("Minus 2?")]
        let third = try await Self.run(model, ChatRequest(system: system, messages: diverged, maxTokens: 64))
        #expect(!third.text.isEmpty)
        // 只有公共前缀（系统提示词）可以复用，而且只在缓存还能回退时；改写的那部分一定是重新算的。
        let stats = await model.prefixStats.chat
        print("diverged: \(stats.cachedTokens) of \(stats.promptTokens) tokens cached")
        #expect(stats.promptTokens - stats.cachedTokens >= 20)

        // 一次性请求不碰会话缓存：之后接着上面的对话仍能复用。
        _ = try await Self.run(model, ChatRequest(system: "Translate to French.", messages: [.user("Good morning")], maxTokens: 32, ephemeral: true))
        let continued = diverged + [.assistant(third.text), .user("Thanks. Say bye.")]
        _ = try await Self.run(model, ChatRequest(system: system, messages: continued, maxTokens: 32))
        #expect(await model.lastRequestReusedCache)
    }

    @Test("prefilling the start of the next message makes the submitted turn start from the cache")
    func prefill() async throws {
        try #require(LocalInferenceBackend.isInstalled(tag: Self.tag))
        let model = MLXChatModel(modelTag: Self.tag)
        let system = "You are Amai, a concise assistant. Answer in one short sentence."
        // 约 1500 token 的"屏幕上下文"。
        let screen = (1...60).map { "Line \($0): the quarterly report lists revenue of \($0 * 13) thousand yen for store number \($0)." }
            .joined(separator: "\n")
        let context = "<context>\nActive app: Numbers\nScreen text:\n\(screen)\n</context>"
        let question = "\n\nUser's message:\nWhat revenue does line 7 list? Reply with the number only."
        func request(_ messages: [ChatMessage]) -> ChatRequest {
            ChatRequest(system: system, messages: messages, maxTokens: 24, temperature: 0)
        }

        // 冷启动基线：不预填充，整段提示词在提交后处理。
        await model.resetConversation()
        _ = try await Self.run(model, request([.user("Say OK.")]))
        await model.resetConversation()
        let cold = try await Self.run(model, request([.user(context + question)]))
        let coldStats = await model.prefixStats.chat
        #expect(coldStats.cachedTokens == 0)

        // 预填充：面板唤出时先算上下文，提交时只剩问题。
        await model.resetConversation()
        await model.prepare(request([.user(context)]))
        let prefilled = await model.prefixStats.prefill
        let warm = try await Self.run(model, request([.user(context + question)]))
        let warmStats = await model.prefixStats.chat
        print("prefill: cold \(coldStats.promptTokens) tokens in \(coldStats.prefillMs) ms; prefilled \(prefilled.promptTokens) tokens in \(prefilled.prefillMs) ms, then \(warmStats.promptTokens - warmStats.cachedTokens) tokens in \(warmStats.prefillMs) ms")
        print("prefill: cold answer \(cold.text) | warm answer \(warm.text)")
        #expect(prefilled.promptTokens > 1000)
        #expect(warmStats.cachedTokens == prefilled.promptTokens)
        #expect(warmStats.promptTokens == coldStats.promptTokens)
        #expect(warmStats.prefillMs < coldStats.prefillMs / 2)
        // 接着缓存算出的结果与从头算一致（temperature 0）。
        #expect(warm.text == cold.text)
        #expect(warm.text.contains("91"))

        // 下一轮：历史在缓存里；预填充的上下文作废（用户换了窗口）时退回到上一轮结束的缓存，而不是整段重算。
        var messages = [ChatMessage.user(context + question), .assistant(warm.text)]
        await model.prepare(request(messages + [.user("<context>\nActive app: Mail\n</context>")]))
        messages.append(.user("<context>\nActive app: Safari\n</context>\n\nUser's message:\nAnd line 8?"))
        let next = try await Self.run(model, request(messages))
        let nextStats = await model.prefixStats.chat
        print("prefill: follow-up with a discarded prefill: \(nextStats.cachedTokens) of \(nextStats.promptTokens) cached, answer \(next.text)")
        #expect(nextStats.cachedTokens >= warmStats.promptTokens)
        #expect(!next.text.isEmpty)
    }

    @Test("the model calls a tool and uses its result, reusing the cache for the tool turn")
    func toolCalling() async throws {
        try #require(LocalInferenceBackend.isInstalled(tag: Self.tag))
        let model = MLXChatModel(modelTag: Self.tag)
        await model.resetConversation()
        let tool = ChatToolSpec(
            name: "search_memory",
            description: "Search the user's personal memory. Use it for any question about what the user did or said in the past.",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Words to search for."}},"required":["query"]}"#
        )
        let system = "You are Amai. Use the search_memory tool to answer questions about the user's past. Be concise."
        var messages = [ChatMessage.user("Which conference did I submit my paper to last week?")]
        let first = try await Self.run(model, ChatRequest(system: system, tools: [tool], messages: messages, maxTokens: 256))
        print("tool turn text: \(first.text) calls: \(first.calls)")
        let call = try #require(first.calls.first)
        #expect(call.name == "search_memory")
        #expect(call.arguments["query"] is String)

        messages.append(.assistant(first.text, toolCalls: first.calls))
        messages.append(.tool(#"[{"content":"Submitted the Amai paper to CHI 2027 on 2026-11-10.","sources":["2026-11-10"]}]"#, call: call))
        let second = try await Self.run(model, ChatRequest(system: system, tools: [tool], messages: messages, maxTokens: 256))
        print("answer: \(second.text)")
        #expect(second.text.contains("CHI"))
        #expect(await model.lastRequestReusedCache)
    }
}

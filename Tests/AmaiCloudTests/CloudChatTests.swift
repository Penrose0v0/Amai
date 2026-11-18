import AmaiCore
import Foundation
import Testing
@testable import AmaiCloud

private func sse(_ events: [String]) -> String {
    events.map { "data: \($0)\n\n" }.joined()
}

private let memoryTool = ChatToolSpec(
    name: "search_memory", description: "Search memory.",
    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
)

private func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

// 走 URLProtocol 桩的测试放进同一个串行 Suite（桩是全局状态）。
extension CloudClientTests {
    @Test("Anthropic chat: streamed text, thinking and tool call; request carries tools, caching and no sampling params")
    func anthropicChatStream() async throws {
        MockURLProtocol.reset([.init(status: 200, body: sse([
            #"{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":5}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"我查"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"一下。"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_memory","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"que"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"ry\":\"论文\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
            #"{"type":"message_stop"}"#,
        ]))])
        let client = AnthropicClient(apiKey: "sk-test", model: "claude-opus-5-5", effort: "medium", transport: mockTransport())
        let events = try await collect(client.stream(ChatRequest(
            system: "sys", tools: [memoryTool], messages: [.user("上周投了哪个会议？")], maxTokens: 1000
        )))

        #expect(events.prefix(2) == [.text("我查"), .text("一下。")])
        guard case .toolCall(let call) = events[2] else { Issue.record("expected a tool call"); return }
        #expect(call.id == "toolu_1" && call.name == "search_memory")
        #expect(call.arguments["query"] as? String == "论文")
        guard case .providerState(let state) = events[3] else { Issue.record("expected provider state"); return }
        #expect(state.contains("sig123") && state.contains("toolu_1"))
        #expect(events[4] == .finished(ChatUsage(inputTokens: 325, outputTokens: 42, cachedInputTokens: 300)))

        let body = MockURLProtocol.lastBody()
        #expect(body["stream"] as? Bool == true)
        #expect((body["cache_control"] as? [String: String])?["type"] == "ephemeral")
        #expect((body["output_config"] as? [String: String])?["effort"] == "medium")
        #expect(body["temperature"] == nil && body["thinking"] == nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "search_memory")
        #expect((tools.first?["input_schema"] as? [String: Any])?["type"] as? String == "object")

        // 下一轮：assistant 的内容块原样带回，工具结果（含图片）放在一条 user 消息里。
        let followUp = AnthropicClient.chatMessages([
            .user("上周投了哪个会议？"),
            ChatMessage(role: .assistant, text: "我查一下。", toolCalls: [call], providerState: state),
            .tool("CHI 2027", call: call, images: [ChatImage(jpeg: Data([0xFF, 0xD8]))]),
        ])
        #expect(followUp.count == 3)
        let assistant = try #require(followUp[1]["content"] as? [[String: Any]])
        #expect(assistant.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
        #expect(assistant[0]["signature"] as? String == "sig123")
        let result = try #require((followUp[2]["content"] as? [[String: Any]])?.first)
        #expect(result["type"] as? String == "tool_result" && result["tool_use_id"] as? String == "toolu_1")
        #expect((result["content"] as? [[String: Any]])?.map { $0["type"] as? String } == ["text", "image"])
    }

    @Test("Anthropic chat: HTTP errors and refusals surface as CloudError without the key")
    func anthropicChatErrors() async throws {
        MockURLProtocol.reset([.init(status: 401, body: #"{"error":{"message":"invalid x-api-key"}}"#)])
        let client = AnthropicClient(apiKey: "sk-secret", transport: mockTransport())
        do {
            _ = try await collect(client.stream(ChatRequest(system: "", messages: [.user("hi")])))
            Issue.record("expected an error")
        } catch let error as CloudError {
            #expect(error == .unauthorized("invalid x-api-key"))
            #expect(!error.description.contains("sk-secret"))
        }

        MockURLProtocol.reset([.init(status: 200, body: sse([
            #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, #"{"type":"message_stop"}"#,
        ]))])
        await #expect(throws: CloudError.refusal(nil)) {
            _ = try await collect(client.stream(ChatRequest(system: "", messages: [.user("hi")])))
        }
    }

    @Test("OpenAI chat: streamed text and a tool call split across chunks; tool images follow as a user message")
    func openAIChatStream() async throws {
        MockURLProtocol.reset([.init(status: 200, body: sse([
            #"{"choices":[{"delta":{"role":"assistant","content":"好"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"get_timeline","arguments":"{\"da"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"te\":\"today\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":32}}}"#,
            "[DONE]",
        ]))])
        let client = OpenAIClient(apiKey: "sk-test", model: "gpt-test", transport: mockTransport())
        let call = ChatToolCall(id: "call_1", name: "look_at_screen", argumentsJSON: "{}")
        let events = try await collect(client.stream(ChatRequest(system: "sys", tools: [memoryTool], messages: [
            .user("看看屏幕"),
            .assistant("", toolCalls: [call]),
            .tool("screenshot attached", call: call, images: [ChatImage(jpeg: Data([1]))]),
        ])))
        #expect(events.first == .text("好"))
        guard case .toolCall(let emitted) = events[1] else { Issue.record("expected a tool call"); return }
        #expect(emitted.id == "call_9" && emitted.name == "get_timeline" && emitted.arguments["date"] as? String == "today")
        #expect(events.last == .finished(ChatUsage(inputTokens: 50, outputTokens: 7, cachedInputTokens: 32)))

        let body = MockURLProtocol.lastBody()
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "user"])
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
        #expect((messages[4]["content"] as? [[String: Any]])?.last?["type"] as? String == "image_url")
        #expect((body["tools"] as? [[String: Any]])?.first?["type"] as? String == "function")
    }
}

@Suite("Cloud chat parsing")
struct CloudChatParsingTests {
    @Test("Responses API: text deltas, function call items and completion")
    func responsesParser() throws {
        var parser = ResponsesStreamParser()
        #expect(try parser.consume(#"{"type":"response.output_text.delta","delta":"Hi"}"#) == [.text("Hi")])
        let call = try parser.consume(#"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"c1","name":"get_memory","arguments":"{\"category\":\"work\"}"}}"#)
        #expect(call == [.toolCall(ChatToolCall(id: "c1", name: "get_memory", argumentsJSON: #"{"category":"work"}"#))])
        #expect(!parser.finished)
        let done = try parser.consume(#"{"type":"response.completed","response":{"usage":{"input_tokens":9,"output_tokens":3}}}"#)
        #expect(done == [.finished(ChatUsage(inputTokens: 9, outputTokens: 3))])
        #expect(parser.finished)
        #expect(throws: CloudError.truncated) { try parser.consume(#"{"type":"response.incomplete"}"#) }
    }

    @Test("Responses API request: function calls and outputs become input items")
    func responsesBody() throws {
        let call = ChatToolCall(id: "c1", name: "get_memory", argumentsJSON: #"{"category":"work"}"#)
        let body = ChatGPTPlanClient.chatBody(ChatRequest(system: "sys", tools: [memoryTool], messages: [
            .user("我的项目进展？"), .assistant("", toolCalls: [call]), .tool("…", call: call),
        ]), model: "gpt-test")
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String ?? $0["role"] as? String } == ["user", "function_call", "function_call_output"])
        #expect(body["store"] as? Bool == false)
        #expect((body["tools"] as? [[String: Any]])?.first?["name"] as? String == "search_memory")
    }

    @Test("OpenAI chat: truncation and refusal are errors")
    func openAIErrors() throws {
        var truncated = OpenAIStreamParser()
        _ = try truncated.consume(#"{"choices":[{"delta":{"content":"a"},"finish_reason":"length"}]}"#)
        #expect(throws: CloudError.truncated) { try truncated.finish() }
        var refused = OpenAIStreamParser()
        _ = try refused.consume(#"{"choices":[{"delta":{"refusal":"no"}}]}"#)
        #expect(throws: CloudError.refusal("no")) { try refused.finish() }
    }

    @Test("Claude Code: a single message is sent as is, a conversation as a labelled transcript")
    func claudeCodeTranscript() {
        #expect(ClaudeCodeClient.transcript([.user("翻译：hello")]) == "翻译：hello")
        let text = ClaudeCodeClient.transcript([.user("你好"), .assistant("你好！"), .user("今天做了什么？")])
        #expect(text.contains("[User]\n你好") && text.contains("[Assistant]\n你好！") && text.hasSuffix("[User]\n今天做了什么？\n"))
    }
}

final class FakeStreamer: ProcessStreaming, @unchecked Sendable {
    struct Call { let arguments: [String]; let environment: [String: String]; let stdin: Data }
    private let lock = NSLock()
    var outputs: [ProcessOutput] = []
    private(set) var calls: [Call] = []

    func lines(
        executable: URL, arguments: [String], environment: [String: String],
        workingDirectory: URL, stdin: Data, timeout: TimeInterval
    ) -> AsyncThrowingStream<ProcessOutput, Error> {
        let outputs = lock.withLock {
            calls.append(Call(arguments: arguments, environment: environment, stdin: stdin))
            return self.outputs
        }
        return AsyncThrowingStream { continuation in
            for output in outputs { continuation.yield(output) }
            continuation.finish()
        }
    }
}

@Suite("Claude Code chat")
struct ClaudeCodeChatTests {
    let exe = URL(fileURLWithPath: "/opt/fake/bin/claude")
    let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("amai-claude-chat-test")

    func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> (String, [ChatEvent]) {
        var text = ""
        var events: [ChatEvent] = []
        for try await event in stream {
            if case .text(let piece) = event { text += piece }
            events.append(event)
        }
        return (text, events)
    }

    @Test("streams text deltas; the screenshot goes in as an image block before the text")
    func streamsWithImage() async throws {
        let streamer = FakeStreamer()
        streamer.outputs = [
            .line(#"{"type":"system","subtype":"init","tools":[]}"#),
            .line(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}}"#),
            .line(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"你"}}}"#),
            .line(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"好"}}}"#),
            .line(#"{"type":"result","subtype":"success","is_error":false,"result":"你好","usage":{"input_tokens":2,"cache_creation_input_tokens":700,"cache_read_input_tokens":0,"output_tokens":9}}"#),
            .exit(status: 0, stderr: "", timedOut: false),
        ]
        let client = ClaudeCodeClient(executable: exe, model: "haiku", workingDirectory: cwd, streamer: streamer)
        #expect(client.supportsImages)
        let image = ChatImage(jpeg: Data([0xFF, 0xD8, 0xFF]))
        let request = ChatRequest(
            system: "规则", messages: [.user("你好"), .assistant("你好！"), .user("屏幕上是什么？", images: [image])], maxTokens: 500
        )
        let (text, events) = try await collect(client.stream(request))
        #expect(text == "你好")
        #expect(events.last == .finished(ChatUsage(inputTokens: 702, outputTokens: 9)))

        let call = try #require(streamer.calls.first)
        let a = call.arguments
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        #expect(value("--input-format") == "stream-json" && value("--output-format") == "stream-json")
        #expect(value("--model") == "haiku" && value("--system-prompt") == "规则" && value("--tools") == "")
        #expect(a.contains("--include-partial-messages") && a.contains("--no-session-persistence") && a.contains("--strict-mcp-config"))
        #expect(call.environment["ANTHROPIC_API_KEY"] == nil)

        // 一行 JSON、一条用户消息：历史在文字稿里，不作为多条消息回放。
        #expect(call.stdin.last == 0x0A && call.stdin.filter { $0 == 0x0A }.count == 1)
        let message = try #require(try JSONSerialization.jsonObject(with: call.stdin) as? [String: Any])
        let content = try #require((message["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        #expect((content[0]["source"] as? [String: Any])?["data"] as? String == image.jpeg.base64EncodedString())
        #expect((content[1]["text"] as? String)?.hasSuffix("[User]\n屏幕上是什么？\n") == true)
    }

    @Test("falls back to the result text when no deltas arrive; errors are classified")
    func resultAndErrors() async throws {
        var parser = ClaudeCodeStreamParser()
        let events = try parser.consume(#"{"type":"result","is_error":false,"result":"整段","usage":{"input_tokens":1,"output_tokens":2}}"#)
        #expect(events == [.text("整段"), .finished(ChatUsage(inputTokens: 1, outputTokens: 2))])
        try parser.finish(status: 0, stderr: "")

        var failing = ClaudeCodeStreamParser()
        #expect(throws: CloudError.self) {
            _ = try failing.consume(#"{"type":"result","is_error":true,"result":"Claude usage limit reached"}"#)
        }

        let streamer = FakeStreamer()
        streamer.outputs = [.exit(status: 1, stderr: "Not logged in · Please run /login", timedOut: false)]
        let client = ClaudeCodeClient(executable: exe, model: "haiku", workingDirectory: cwd, streamer: streamer)
        await #expect(throws: CloudError.self) {
            _ = try await collect(client.stream(ChatRequest(system: "", messages: [.user("hi")], maxTokens: 10)))
        }
    }

    @Test(
        "real CLI: reads an image and streams (uses the subscription)",
        .enabled(if: ProcessInfo.processInfo.environment["AMAI_CLAUDE_CODE_TEST"] != nil)
    )
    func realCLI() async throws {
        let env = ProcessInfo.processInfo.environment
        let executable = try #require(ClaudeCodeLocator.locate(configured: env["AMAI_CLAUDE_CODE_PATH"]))
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: try #require(env["AMAI_CLAUDE_CODE_TEST"])))
        let client = ClaudeCodeClient(executable: executable, model: "haiku", workingDirectory: cwd)
        let request = ChatRequest(
            system: "You are a concise assistant.",
            messages: [.user("Read the text in this image, then count from 1 to 40, one number per line.", images: [ChatImage(jpeg: jpeg)])],
            maxTokens: 500
        )
        let start = Date()
        var first: TimeInterval?
        var pieces = 0
        var text = ""
        for try await event in client.stream(request) {
            if case .text(let piece) = event {
                if first == nil { first = Date().timeIntervalSince(start) }
                pieces += 1
                text += piece
            }
        }
        print("claude-code chat: first text \(first ?? -1)s, total \(Date().timeIntervalSince(start))s, \(pieces) pieces")
        #expect(text.contains("7391") && pieces > 1)
    }
}

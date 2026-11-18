import AmaiCore
import Foundation

/// OpenAI Chat Completions 的对话实现（`stream: true`）。`baseURL` 可指向任何兼容该接口的服务，
/// 这也是接入其他云端 Provider 的通用途径。
///
/// - 工具结果里的图片：该接口的 tool 消息只能是文字，图片改由紧随其后的一条 user 消息携带；
/// - `finish_reason == "length"` 视为截断，`delta.refusal` 视为拒绝。
extension OpenAIClient: ChatModel {
    public var sendsDataOffDevice: Bool { true }
    public var supportsImages: Bool { true }
    public var supportsTools: Bool { true }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        CloudChat.stream { continuation in
            guard !apiKey.isEmpty else { throw CloudError.missingAPIKey(.openai) }
            guard !model.isEmpty else { throw CloudError.missingModel(.openai) }

            var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = timeout
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
            urlRequest.httpBody = try JSONSerialization.data(
                withJSONObject: Self.chatBody(request, model: model, reasoningEffort: reasoningEffort)
            )

            var parser = OpenAIStreamParser()
            let events = SSE.events(urlRequest, session: transport.session) { status, data in
                HTTPTransport.standardError(status: status, data: data)
            }
            for try await event in events {
                for output in try parser.consume(event.data) { continuation.yield(output) }
            }
            for output in try parser.finish() { continuation.yield(output) }
        }
    }

    static func chatBody(_ request: ChatRequest, model: String, reasoningEffort: String?) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        // 工具结果带的图片要等这一组 tool 消息全部结束后再发，否则会打断 tool 消息与调用的对应关系。
        var pendingImages: [ChatImage] = []
        func flushImages() {
            guard !pendingImages.isEmpty else { return }
            var content: [[String: Any]] = [["type": "text", "text": "Images returned by the tool call(s) above."]]
            content += pendingImages.map { ["type": "image_url", "image_url": ["url": CloudChat.dataURL($0)]] }
            messages.append(["role": "user", "content": content])
            pendingImages = []
        }
        for message in request.messages {
            if message.role != .tool { flushImages() }
            switch message.role {
            case .user:
                if message.images.isEmpty {
                    messages.append(["role": "user", "content": message.text])
                } else {
                    var content: [[String: Any]] = [["type": "text", "text": message.text]]
                    content += message.images.map { ["type": "image_url", "image_url": ["url": CloudChat.dataURL($0)]] }
                    messages.append(["role": "user", "content": content])
                }
            case .assistant:
                var item: [String: Any] = ["role": "assistant", "content": message.text]
                if !message.toolCalls.isEmpty {
                    item["tool_calls"] = message.toolCalls.map { call in
                        ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]] as [String: Any]
                    }
                }
                messages.append(item)
            case .tool:
                messages.append(["role": "tool", "tool_call_id": message.toolCallId ?? "", "content": message.text])
                pendingImages += message.images
            }
        }
        flushImages()

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            // 推理模型的推理 token 也计入上限，预留空间。
            "max_completion_tokens": min(64_000, request.maxTokens + 16_000),
        ]
        if let effort = reasoningEffort, !effort.isEmpty { body["reasoning_effort"] = effort }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["type": "function", "function": [
                    "name": tool.name, "description": tool.description, "parameters": CloudChat.schema(tool),
                ]] as [String: Any]
            }
        }
        return body
    }
}

/// Chat Completions 流式分片的解析。工具调用的名称与参数按 `index` 分片到达，流结束时一并产出。
struct OpenAIStreamParser {
    private struct PendingCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var calls: [Int: PendingCall] = [:]
    private var usage = ChatUsage()
    private var refusal = ""
    private var finishReason: String?
    private var sawChoice = false

    mutating func consume(_ data: String) throws -> [ChatEvent] {
        guard data != "[DONE]", let chunk = SSE.json(data) else { return [] }
        if let error = chunk["error"] as? [String: Any] {
            throw CloudError.badRequest(String((error["message"] as? String ?? "").prefix(200)))
        }
        if let raw = chunk["usage"] as? [String: Any] {
            usage.inputTokens = raw["prompt_tokens"] as? Int ?? usage.inputTokens
            usage.outputTokens = raw["completion_tokens"] as? Int ?? usage.outputTokens
            usage.cachedInputTokens = (raw["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? usage.cachedInputTokens
        }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return [] }
        sawChoice = true
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return [] }
        if let text = delta["refusal"] as? String { refusal += text }
        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = call["index"] as? Int ?? 0
            var pending = calls[index] ?? PendingCall()
            if let id = call["id"] as? String, !id.isEmpty { pending.id = id }
            let function = call["function"] as? [String: Any]
            if let name = function?["name"] as? String { pending.name += name }
            if let arguments = function?["arguments"] as? String { pending.arguments += arguments }
            calls[index] = pending
        }
        if let text = delta["content"] as? String, !text.isEmpty { return [.text(text)] }
        return []
    }

    mutating func finish() throws -> [ChatEvent] {
        if !refusal.isEmpty { throw CloudError.refusal(String(refusal.prefix(200))) }
        if finishReason == "length" { throw CloudError.truncated }
        guard sawChoice else { throw CloudError.invalidResponse }
        var events: [ChatEvent] = []
        for index in calls.keys.sorted() {
            guard let call = calls[index], !call.name.isEmpty else { continue }
            let parsed = (try? JSONSerialization.jsonObject(with: Data((call.arguments.isEmpty ? "{}" : call.arguments).utf8))) as? [String: Any] ?? [:]
            events.append(.toolCall(ChatToolCall(
                id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name, argumentsJSON: CloudChat.jsonString(parsed)
            )))
        }
        events.append(.finished(usage))
        return events
    }
}

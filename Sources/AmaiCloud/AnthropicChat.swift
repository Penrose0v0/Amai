import AmaiCore
import Foundation

/// Anthropic Messages API 的对话实现：`stream: true` 的 SSE、工具调用、提示缓存。
///
/// - 思考由模型自适应决定，用 `output_config.effort` 控制深度；不发送 `temperature`（当前模型拒绝采样参数）；
/// - 请求顶层的 `cache_control` 让服务端在最后一个可缓存块上自动设缓存点：消息只追加不改写，
///   所以每一轮都能命中上一轮的前缀；
/// - 思考块（含签名）必须原样带回，否则工具调用的下一轮会被拒绝：整条 assistant 消息的内容块
///   通过 `ChatEvent.providerState` 交给调用方保存，下次请求时原样发送。
extension AnthropicClient: ChatModel {
    public var sendsDataOffDevice: Bool { true }
    public var supportsImages: Bool { true }
    public var supportsTools: Bool { true }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        CloudChat.stream { continuation in
            guard !apiKey.isEmpty else { throw CloudError.missingAPIKey(.anthropic) }
            guard !model.isEmpty else { throw CloudError.missingModel(.anthropic) }

            var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = timeout
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.chatBody(request, model: model, effort: effort))

            var parser = AnthropicStreamParser()
            let events = SSE.events(urlRequest, session: transport.session) { status, data in
                HTTPTransport.standardError(status: status, data: data)
            }
            for try await event in events {
                for output in try parser.consume(event.data) { continuation.yield(output) }
            }
            guard parser.finished else { throw CloudError.network(String(localized: "响应流中断")) }
        }
    }

    static func chatBody(_ request: ChatRequest, model: String, effort: String?) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            // 思考 token 计入 max_tokens：在回答所需输出之外预留思考空间。
            "max_tokens": min(64_000, request.maxTokens + 16_000),
            "stream": true,
            "cache_control": ["type": "ephemeral"],
            "messages": chatMessages(request.messages),
        ]
        if !request.system.isEmpty { body["system"] = request.system }
        if let effort, !effort.isEmpty { body["output_config"] = ["effort": effort] }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["name": tool.name, "description": tool.description, "input_schema": CloudChat.schema(tool)] as [String: Any]
            }
        }
        return body
    }

    /// 工具结果在 Anthropic 的格式里属于 user 消息；同一轮的多个结果必须放在同一条消息里。
    static func chatMessages(_ messages: [ChatMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func appendUser(_ blocks: [[String: Any]]) {
            if let last = result.last, last["role"] as? String == "user", var content = last["content"] as? [[String: Any]] {
                content += blocks
                result[result.count - 1]["content"] = content
            } else {
                result.append(["role": "user", "content": blocks])
            }
        }
        func image(_ image: ChatImage) -> [String: Any] {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.jpeg.base64EncodedString()]]
        }
        for message in messages {
            switch message.role {
            case .user:
                var blocks = message.images.map(image)
                blocks.append(["type": "text", "text": message.text.isEmpty ? " " : message.text])
                appendUser(blocks)
            case .tool:
                var content: [[String: Any]] = [["type": "text", "text": message.text.isEmpty ? " " : message.text]]
                content += message.images.map(image)
                appendUser([["type": "tool_result", "tool_use_id": message.toolCallId ?? "", "content": content]])
            case .assistant:
                // 同一个 Provider 产生的内容块原样带回（思考块签名只对原文有效）。
                if let state = message.providerState,
                   let blocks = (try? JSONSerialization.jsonObject(with: Data(state.utf8))) as? [[String: Any]],
                   blocks.allSatisfy({ ["thinking", "redacted_thinking", "text", "tool_use"].contains($0["type"] as? String ?? "") }),
                   !blocks.isEmpty {
                    result.append(["role": "assistant", "content": blocks])
                    continue
                }
                var blocks: [[String: Any]] = []
                if !message.text.isEmpty { blocks.append(["type": "text", "text": message.text]) }
                for call in message.toolCalls {
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": call.arguments])
                }
                if blocks.isEmpty { blocks.append(["type": "text", "text": " "]) }
                result.append(["role": "assistant", "content": blocks])
            }
        }
        return result
    }
}

/// Messages API 流式事件的解析：文本增量立即产出，工具调用在其内容块结束时产出，
/// `message_stop` 时产出要带回的内容块与用量。
struct AnthropicStreamParser {
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var usage = ChatUsage()
    private var stopReason: String?
    private(set) var finished = false

    mutating func consume(_ data: String) throws -> [ChatEvent] {
        guard let event = SSE.json(data), let type = event["type"] as? String else { return [] }
        switch type {
        case "message_start":
            let message = event["message"] as? [String: Any]
            apply(usage: message?["usage"] as? [String: Any])
            return []
        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return [] }
            blocks[index] = block
            return []
        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                let previous = blocks[index]?["text"] as? String ?? ""
                blocks[index]?["text"] = previous + text
                return text.isEmpty ? [] : [.text(text)]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "thinking_delta":
                let previous = blocks[index]?["thinking"] as? String ?? ""
                blocks[index]?["thinking"] = previous + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                blocks[index]?["signature"] = delta["signature"] as? String ?? ""
            default:
                break
            }
            return []
        case "content_block_stop":
            guard let index = event["index"] as? Int, let block = blocks[index], block["type"] as? String == "tool_use" else { return [] }
            let raw = partialJSON[index] ?? ""
            // 工具参数以 JSON 片段流式到达；拼完后必须能解析成对象，否则按空参数处理，由工具报参数错误。
            let input = (try? JSONSerialization.jsonObject(with: Data((raw.isEmpty ? "{}" : raw).utf8))) as? [String: Any] ?? [:]
            blocks[index]?["input"] = input
            return [.toolCall(ChatToolCall(
                id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                argumentsJSON: CloudChat.jsonString(input)
            ))]
        case "message_delta":
            stopReason = (event["delta"] as? [String: Any])?["stop_reason"] as? String ?? stopReason
            apply(usage: event["usage"] as? [String: Any])
            return []
        case "message_stop":
            switch stopReason {
            case "refusal": throw CloudError.refusal(nil)
            case "max_tokens": throw CloudError.truncated
            default: break
            }
            finished = true
            let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
            return [.providerState(CloudChat.jsonString(ordered)), .finished(usage)]
        case "error":
            let error = event["error"] as? [String: Any]
            let message = String((error?["message"] as? String ?? "").prefix(200))
            switch error?["type"] as? String {
            case "overloaded_error": throw CloudError.server(529)
            case "rate_limit_error": throw CloudError.rateLimited
            default: throw CloudError.badRequest(message)
            }
        default:
            return []
        }
    }

    private mutating func apply(usage raw: [String: Any]?) {
        guard let raw else { return }
        let cached = raw["cache_read_input_tokens"] as? Int
        if let cached { usage.cachedInputTokens = cached }
        if let input = raw["input_tokens"] as? Int {
            usage.inputTokens = input + (raw["cache_creation_input_tokens"] as? Int ?? 0) + (cached ?? 0)
        }
        if let output = raw["output_tokens"] as? Int { usage.outputTokens = output }
    }
}

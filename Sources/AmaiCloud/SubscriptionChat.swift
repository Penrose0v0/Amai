import AmaiCore
import Foundation

// 订阅额度的两种来源（ADR-0005）的对话实现。

/// ChatGPT 订阅：Responses API（`store: false`、`stream: true`），支持工具调用与图片。
/// 服务端不保存会话，每次发送完整的输入项列表。
extension ChatGPTPlanClient: ChatModel {
    public var sendsDataOffDevice: Bool { true }
    public var supportsImages: Bool { true }
    public var supportsTools: Bool { true }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        CloudChat.stream { continuation in
            guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw CloudError.missingModel(.openai) }
            let body = try JSONSerialization.data(withJSONObject: Self.chatBody(request, model: model))
            var token = try await session.accessTokenForInference()
            var refreshed = false
            while true {
                var produced = false
                do {
                    let config = await session.config
                    var urlRequest = URLRequest(url: config.apiBase.appendingPathComponent("responses"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = timeout
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    urlRequest.httpBody = body

                    var parser = ResponsesStreamParser()
                    let events = SSE.events(urlRequest, session: http) { status, data in
                        status == 401 ? .unauthorized("") : Self.mapError(status: status, data: data)
                    }
                    for try await event in events {
                        for output in try parser.consume(event.data) {
                            produced = true
                            continuation.yield(output)
                        }
                    }
                    guard parser.finished else {
                        throw CloudError.network(String(localized: "响应流在 response.completed 之前结束"))
                    }
                    return
                } catch CloudError.unauthorized where !refreshed && !produced {
                    // 访问令牌过期：刷新一次后重发。
                    refreshed = true
                    token = try await session.forceRefresh()
                } catch CloudError.unauthorized {
                    throw CloudError.signInRequired(String(localized: "ChatGPT 拒绝了当前登录，请重新登录"))
                }
            }
        }
    }

    static func chatBody(_ request: ChatRequest, model: String) -> [String: Any] {
        var input: [[String: Any]] = []
        var pendingImages: [ChatImage] = []
        func imageItems(_ images: [ChatImage]) -> [[String: Any]] {
            images.map { ["type": "input_image", "image_url": CloudChat.dataURL($0)] }
        }
        func flushImages() {
            guard !pendingImages.isEmpty else { return }
            input.append(["role": "user", "content":
                [["type": "input_text", "text": "Images returned by the tool call(s) above."]] + imageItems(pendingImages)])
            pendingImages = []
        }
        for message in request.messages {
            if message.role != .tool { flushImages() }
            switch message.role {
            case .user:
                input.append(["role": "user", "content":
                    [["type": "input_text", "text": message.text]] + imageItems(message.images)])
            case .assistant:
                if !message.text.isEmpty {
                    input.append(["role": "assistant", "content": [["type": "output_text", "text": message.text]]])
                }
                for call in message.toolCalls {
                    input.append(["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.argumentsJSON])
                }
            case .tool:
                input.append(["type": "function_call_output", "call_id": message.toolCallId ?? "", "output": message.text])
                pendingImages += message.images
            }
        }
        flushImages()

        var body: [String: Any] = [
            "model": model,
            "instructions": request.system,
            "input": input,
            "store": false,
            "stream": true,
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["type": "function", "name": tool.name, "description": tool.description, "parameters": CloudChat.schema(tool)] as [String: Any]
            }
        }
        return body
    }
}

/// Responses API 流式事件的解析：文本增量、完成的函数调用项、以 `response.completed` 为成功信号。
struct ResponsesStreamParser {
    private(set) var finished = false
    private var sawText = false

    mutating func consume(_ data: String) throws -> [ChatEvent] {
        guard data != "[DONE]", let event = SSE.json(data), let type = event["type"] as? String else { return [] }
        switch type {
        case "response.output_text.delta":
            let delta = event["delta"] as? String ?? ""
            if !delta.isEmpty { sawText = true }
            return delta.isEmpty ? [] : [.text(delta)]
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any], item["type"] as? String == "function_call" else { return [] }
            let raw = item["arguments"] as? String ?? "{}"
            let parsed = (try? JSONSerialization.jsonObject(with: Data((raw.isEmpty ? "{}" : raw).utf8))) as? [String: Any] ?? [:]
            return [.toolCall(ChatToolCall(
                id: item["call_id"] as? String ?? item["id"] as? String ?? "",
                name: item["name"] as? String ?? "", argumentsJSON: CloudChat.jsonString(parsed)
            ))]
        case "response.completed":
            finished = true
            let response = event["response"] as? [String: Any] ?? [:]
            let usage = response["usage"] as? [String: Any]
            var events: [ChatEvent] = []
            // 有的路由不发增量，只在完成事件里给出全文。
            if !sawText {
                let text = SSEParser.outputText(response)
                if !text.isEmpty { events.append(.text(text)) }
            }
            events.append(.finished(ChatUsage(
                inputTokens: usage?["input_tokens"] as? Int ?? 0,
                outputTokens: usage?["output_tokens"] as? Int ?? 0,
                cachedInputTokens: (usage?["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
            )))
            return events
        case "response.failed":
            let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
            throw ChatGPTPlanClient.mapCode(error?["code"] as? String ?? "", message: error?["message"] as? String ?? "", status: 0)
        case "response.incomplete":
            throw CloudError.truncated
        case "error":
            let nested = event["error"] as? [String: Any]
            throw ChatGPTPlanClient.mapCode(
                (event["code"] as? String) ?? (nested?["code"] as? String) ?? "",
                message: (event["message"] as? String) ?? (nested?["message"] as? String) ?? "", status: 0
            )
        default:
            return []
        }
    }
}

/// Claude 订阅（本机 Claude Code CLI）：每次提问启动一次 `claude -p`，用 stream-json 收发。
/// 输入是一条结构化的用户消息（截图作为图片块），输出逐段返回。
/// CLI 会对输入里的每条用户消息各生成一次回答，不能把历史当作多条消息回放，
/// 所以多轮对话仍拼成一份文字稿放进这一条消息。没有工具：需要查记忆时由调用方先检索、再把结果放进提示词。
extension ClaudeCodeClient: ChatModel {
    public var sendsDataOffDevice: Bool { true }
    public var supportsImages: Bool { true }
    public var supportsTools: Bool { false }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        CloudChat.stream { continuation in
            guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw CloudError.missingModel(.anthropic) }
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let lines = streamer.lines(
                executable: executable,
                arguments: chatArguments(system: request.system),
                environment: Self.environment(executable: executable),
                workingDirectory: workingDirectory,
                stdin: Self.chatInput(request.messages),
                timeout: timeout
            )
            var parser = ClaudeCodeStreamParser()
            for try await output in lines {
                try Task.checkCancellation()
                switch output {
                case .line(let line):
                    for event in try parser.consume(line) { continuation.yield(event) }
                case .exit(let status, let stderr, let timedOut):
                    if timedOut { throw CloudError.network(String(localized: "Claude Code 超过 \(Int(timeout)) 秒未返回")) }
                    try parser.finish(status: status, stderr: stderr)
                }
            }
        }
    }

    /// 与一次性调用相同的隔离方式（无工具、不加载用户全局设置 / MCP / 技能），只是改用流式的输入输出格式。
    func chatArguments(system: String) -> [String] {
        [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            "--system-prompt", system,
            "--tools", "",
            "--no-session-persistence",
            "--setting-sources", "project",
            "--strict-mcp-config",
            "--disable-slash-commands",
        ]
    }

    /// 标准输入的内容：一行 JSON，一条用户消息。最后一条消息带的截图放在文字前面。
    static func chatInput(_ messages: [ChatMessage]) -> Data {
        var content: [[String: Any]] = (messages.last?.images ?? []).map { image in
            [
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": image.jpeg.base64EncodedString()],
            ]
        }
        content.append(["type": "text", "text": transcript(messages)])
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// 只有一条消息时原样发送；多轮时标出说话人，最后一条是要回答的内容。
    static func transcript(_ messages: [ChatMessage]) -> String {
        guard messages.count > 1 else { return messages.first?.text ?? "" }
        var lines = ["Conversation so far (reply to the last user message only):", ""]
        for message in messages {
            switch message.role {
            case .user: lines.append("[User]\n\(message.text)\n")
            case .assistant: if !message.text.isEmpty { lines.append("[Assistant]\n\(message.text)\n") }
            case .tool: lines.append("[Tool result: \(message.toolName ?? "tool")]\n\(message.text)\n")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// 把 `claude -p --output-format stream-json` 的输出行转成 `ChatEvent`。
struct ClaudeCodeStreamParser {
    private var sawText = false
    private var finished = false

    mutating func consume(_ line: String) throws -> [ChatEvent] {
        guard line.hasPrefix("{"), let object = SSE.json(line) else { return [] }
        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty
            else { return [] }
            sawText = true
            return [.text(text)]
        case "result":
            let text = object["result"] as? String ?? ""
            if object["is_error"] as? Bool == true {
                throw ClaudeCodeClient.classify(message: text, fallback: .badRequest(String(text.prefix(200))))
            }
            finished = true
            var events: [ChatEvent] = []
            // 没有收到逐段输出时（旧版本 CLI），用结果里的整段文字。
            if !sawText {
                guard !text.isEmpty else { throw CloudError.invalidResponse }
                events.append(.text(text))
            }
            var input = 0, output = 0
            if let usage = object["usage"] as? [String: Any] {
                input = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                output = usage["output_tokens"] as? Int ?? 0
            }
            events.append(.finished(ChatUsage(inputTokens: input, outputTokens: output)))
            return events
        default:
            return []
        }
    }

    /// 进程结束时还没有收到结果：按错误输出归类。
    func finish(status: Int32, stderr: String) throws {
        guard !finished else { return }
        throw ClaudeCodeClient.classify(
            message: stderr, fallback: .local(String(localized: "Claude Code 退出码 \(status)"))
        )
    }
}

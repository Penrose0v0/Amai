import Foundation
import os

/// 用 ChatGPT 套餐额度调用 Responses API（SIWC，ADR-0005）。
///
/// - `POST https://api.openai.com/v1/responses`，`store:false`、`stream:true`；
/// - 系统提示放 `instructions`（不能用 system 角色消息），不发送 temperature / max_output_tokens 等不支持字段；
/// - 只有收到 `response.completed` 才算成功；
/// - 结构化输出：先带 `text.format` 的 JSON Schema；若被判定为不支持，本次运行改为不带 Schema。
public struct ChatGPTPlanClient: CloudTextClient {
    public let session: ChatGPTSession
    public let model: String
    public let http: URLSession
    public let sleep: @Sendable (TimeInterval) async -> Void
    public let timeout: TimeInterval

    public var identifier: String { "chatgpt-plan:\(model)" }

    public init(
        session: ChatGPTSession,
        model: String,
        http: URLSession = .shared,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        timeout: TimeInterval = 300
    ) {
        self.session = session
        self.model = model
        self.http = http
        self.sleep = sleep
        self.timeout = timeout
    }

    public func generate(_ request: CloudRequest) async throws -> CloudResponse {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw CloudError.missingModel(.openai) }
        var useSchema = request.schemaJSON != nil
        if await session.structuredOutputUnsupported { useSchema = false }
        var token = try await session.accessTokenForInference()
        var refreshedAfter401 = false
        var attempt = 0

        while true {
            do {
                let response = try await stream(request, token: token, includeSchema: useSchema)
                Logger(subsystem: "com.amai.app", category: "cloud.chatgpt")
                    .notice("plan call ok, schema=\(useSchema, privacy: .public), \(response.inputTokens) in / \(response.outputTokens) out")
                return response
            } catch let failure as Failure {
                switch failure {
                case .unauthorized where !refreshedAfter401:
                    refreshedAfter401 = true
                    token = try await session.forceRefresh()
                case .unsupportedSchema where useSchema:
                    await session.markStructuredOutputUnsupported()
                    Logger(subsystem: "com.amai.app", category: "cloud.chatgpt")
                        .notice("structured output not supported on this route; falling back to prompt-only JSON")
                    useSchema = false
                case .error(let error) where error.isRetryable && attempt < 2:
                    attempt += 1
                    await sleep(pow(2, Double(attempt)))
                case .unauthorized:
                    throw CloudError.signInRequired("ChatGPT 拒绝了当前登录，请重新登录")
                case .unsupportedSchema:
                    throw CloudError.badRequest("不支持的请求参数")
                case .error(let error):
                    throw error
                }
            }
        }
    }

    enum Failure: Error {
        case unauthorized
        case unsupportedSchema
        case error(CloudError)
    }

    func body(_ request: CloudRequest, includeSchema: Bool) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "instructions": request.system,
            "input": [["role": "user", "content": request.user]],
            "store": false,
            "stream": true,
        ]
        if includeSchema, let schemaJSON = request.schemaJSON,
           let schema = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) {
            body["text"] = ["format": [
                "type": "json_schema",
                "name": request.schemaName ?? "output",
                "schema": schema,
                "strict": true,
            ]]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func stream(_ request: CloudRequest, token: String, includeSchema: Bool) async throws -> CloudResponse {
        let config = await session.config
        var urlRequest = URLRequest(url: config.apiBase.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.httpBody = try body(request, includeSchema: includeSchema)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await http.bytes(for: urlRequest)
        } catch {
            throw Failure.error(.network("无法连接 OpenAI"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let mapped = Self.mapError(status: status, data: data)
            if status == 401 { throw Failure.unauthorized }
            if includeSchema, Self.isUnsupportedSchema(data) { throw Failure.unsupportedSchema }
            throw Failure.error(mapped)
        }

        var parser = SSEParser()
        do {
            for try await line in bytes.lines {
                if let outcome = try parser.consume(line) {
                    return CloudResponse(text: outcome.text, model: outcome.model ?? model,
                                         inputTokens: outcome.inputTokens, outputTokens: outcome.outputTokens)
                }
            }
        } catch let error as CloudError {
            throw Failure.error(error)
        } catch {
            throw Failure.error(.network("响应流中断"))
        }
        throw Failure.error(.network("响应流在 response.completed 之前结束"))
    }

    // MARK: - Errors

    /// 按 SIWC 官方错误码映射（errors-and-recovery 页）。
    static func mapError(status: Int, data: Data) -> CloudError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = obj["error"] as? [String: Any]
        let code = error?["code"] as? String ?? ""
        let message = (error?["message"] as? String) ?? (obj["detail"] as? String) ?? ""
        return mapCode(code, message: message, status: status)
    }

    static func mapCode(_ code: String, message: String, status: Int) -> CloudError {
        let short = String(message.prefix(160))
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return .planUsageLimit("已达到 ChatGPT 套餐在 Amai 中的用量上限，可在 ChatGPT 设置的 Usage 中查看")
        case "subscription_sharing_user_not_eligible":
            return .planNotEligible(short)
        case "subscription_sharing_invalid_user":
            return .signInRequired("ChatGPT 账户状态无效，请重新登录")
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .server(503)
        case "subscription_sharing_unsupported_capability":
            return .badRequest("模型或参数不受支持：\(short)")
        case "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return .badRequest("\(code)：请检查授权或接口配置")
        default:
            break
        }
        switch status {
        case 401: return .signInRequired("ChatGPT 登录已失效，请重新登录")
        case 403: return .badRequest(short.isEmpty ? "请求被策略拒绝（403）" : short)
        case 429: return .planUsageLimit(short)
        case 500...599: return .server(status)
        default: return .badRequest(short.isEmpty ? "HTTP \(status)" : short)
        }
    }

    static func isUnsupportedSchema(_ data: Data) -> Bool {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = obj["error"] as? [String: Any] ?? [:]
        let code = error["code"] as? String ?? ""
        let param = (error["param"] as? String ?? "").lowercased()
        return code == "subscription_sharing_unsupported_capability" && (param.contains("text") || param.contains("format") || param.contains("schema"))
    }
}

/// Responses API 的 SSE 解析：累积 `response.output_text.delta`，以 `response.completed` 为成功信号。
struct SSEParser {
    struct Outcome {
        let text: String
        let model: String?
        let inputTokens: Int
        let outputTokens: Int
    }

    private var text = ""

    mutating func consume(_ line: String) throws -> Outcome? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return nil }

        switch type {
        case "response.output_text.delta":
            text += event["delta"] as? String ?? ""
            return nil
        case "response.completed":
            let response = event["response"] as? [String: Any] ?? [:]
            let usage = response["usage"] as? [String: Any]
            var final = text
            if final.isEmpty { final = Self.outputText(response) }
            return Outcome(
                text: final,
                model: response["model"] as? String,
                inputTokens: usage?["input_tokens"] as? Int ?? 0,
                outputTokens: usage?["output_tokens"] as? Int ?? 0
            )
        case "response.failed":
            let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
            throw ChatGPTPlanClient.mapCode(error?["code"] as? String ?? "", message: error?["message"] as? String ?? "", status: 0)
        case "response.incomplete":
            throw CloudError.truncated
        case "error":
            let code = (event["code"] as? String) ?? ((event["error"] as? [String: Any])?["code"] as? String) ?? ""
            let message = (event["message"] as? String) ?? ((event["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw ChatGPTPlanClient.mapCode(code, message: message, status: 0)
        default:
            return nil
        }
    }

    static func outputText(_ response: [String: Any]) -> String {
        let output = response["output"] as? [[String: Any]] ?? []
        return output.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
            .joined()
    }
}

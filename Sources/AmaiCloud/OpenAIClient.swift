import Foundation

/// OpenAI Chat Completions API（原始 HTTP）。`baseURL` 可改为兼容该接口的其他服务。
///
/// - `POST {baseURL}/chat/completions`，请求头 `Authorization: Bearer <key>`；
/// - 结构化输出：`response_format = {type: "json_schema", json_schema: {name, strict: true, schema}}`；
/// - `reasoning_effort` 只在用户配置了时才发送（非推理模型不接受该参数）；
/// - `message.refusal` 非空视为拒绝，`finish_reason == "length"` 视为截断。
public struct OpenAIClient: CloudTextClient {
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    public static let reasoningEfforts = ["", "minimal", "low", "medium", "high"]

    public let apiKey: String
    public let model: String
    public let reasoningEffort: String?
    public let baseURL: URL
    public let transport: HTTPTransport
    public let timeout: TimeInterval

    public var identifier: String { "openai:\(model)" }

    public init(
        apiKey: String,
        model: String,
        reasoningEffort: String? = nil,
        baseURL: URL = OpenAIClient.defaultBaseURL,
        transport: HTTPTransport = HTTPTransport(),
        timeout: TimeInterval = 300
    ) {
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.baseURL = baseURL
        self.transport = transport
        self.timeout = timeout
    }

    public func generate(_ request: CloudRequest) async throws -> CloudResponse {
        guard !apiKey.isEmpty else { throw CloudError.missingAPIKey(.openai) }
        guard !model.isEmpty else { throw CloudError.missingModel(.openai) }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
            // 推理模型的推理 token 也计入上限，预留空间。
            "max_completion_tokens": min(64_000, request.maxTokens + 16_000),
        ]
        if let effort = reasoningEffort, !effort.isEmpty { body["reasoning_effort"] = effort }
        if let schemaJSON = request.schemaJSON,
           let schema = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": request.schemaName ?? "output", "strict": true, "schema": schema],
            ]
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await transport.send(urlRequest) { status, data in
            HTTPTransport.standardError(status: status, data: data)
        }
        return try Self.parse(data, fallbackModel: model)
    }

    static func parse(_ data: Data, fallbackModel: String) throws -> CloudResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else { throw CloudError.invalidResponse }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw CloudError.refusal(String(refusal.prefix(200)))
        }
        if choice["finish_reason"] as? String == "length" { throw CloudError.truncated }
        guard let text = message["content"] as? String else { throw CloudError.invalidResponse }
        let usage = obj["usage"] as? [String: Any]
        return CloudResponse(
            text: text,
            model: obj["model"] as? String ?? fallbackModel,
            inputTokens: usage?["prompt_tokens"] as? Int ?? 0,
            outputTokens: usage?["completion_tokens"] as? Int ?? 0
        )
    }
}

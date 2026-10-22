import Foundation

/// Anthropic Messages API（原始 HTTP；Swift 没有官方 SDK）。
///
/// - `POST {baseURL}/v1/messages`，请求头 `x-api-key`、`anthropic-version: 2023-06-01`；
/// - 当前模型思考始终开启，用 `output_config.effort` 控制深度，思考 token 计入 `max_tokens`，因此预留空间；
/// - 结构化输出：`output_config.format = {type: "json_schema", schema}`；
/// - 先检查 `stop_reason`：`refusal` 与 `max_tokens` 视为失败。
public struct AnthropicClient: CloudTextClient {
    public static let defaultModel = "claude-opus-5-5"
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    public let apiKey: String
    public let model: String
    public let effort: String?
    public let baseURL: URL
    public let transport: HTTPTransport
    public let timeout: TimeInterval

    public var identifier: String { "anthropic:\(model)" }

    public init(
        apiKey: String,
        model: String = AnthropicClient.defaultModel,
        effort: String? = "high",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        transport: HTTPTransport = HTTPTransport(),
        timeout: TimeInterval = 300
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.baseURL = baseURL
        self.transport = transport
        self.timeout = timeout
    }

    public func generate(_ request: CloudRequest) async throws -> CloudResponse {
        guard !apiKey.isEmpty else { throw CloudError.missingAPIKey(.anthropic) }
        guard !model.isEmpty else { throw CloudError.missingModel(.anthropic) }

        var outputConfig: [String: Any] = [:]
        if let effort, !effort.isEmpty { outputConfig["effort"] = effort }
        if let schemaJSON = request.schemaJSON,
           let schema = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        var body: [String: Any] = [
            "model": model,
            // 思考 token 计入 max_tokens：在任务所需输出之外预留思考空间。
            "max_tokens": min(64_000, request.maxTokens + 16_000),
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
        ]
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await transport.send(urlRequest) { status, data in
            // 529 为服务过载，按服务端错误重试。
            HTTPTransport.standardError(status: status, data: data)
        }
        return try Self.parse(data, fallbackModel: model)
    }

    static func parse(_ data: Data, fallbackModel: String) throws -> CloudResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        switch obj["stop_reason"] as? String {
        case "refusal":
            let details = obj["stop_details"] as? [String: Any]
            throw CloudError.refusal(details?["explanation"] as? String ?? details?["category"] as? String)
        case "max_tokens":
            throw CloudError.truncated
        default:
            break
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw CloudError.invalidResponse
        }
        let usage = obj["usage"] as? [String: Any]
        return CloudResponse(
            text: text,
            model: obj["model"] as? String ?? fallbackModel,
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0
        )
    }
}

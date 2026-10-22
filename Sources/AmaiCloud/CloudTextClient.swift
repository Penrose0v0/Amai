import Foundation

/// 云端文本模型提供商（ADR-0004）。只用于记忆整理；抽取层始终本地。
public enum CloudProvider: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }
}

/// 一次文本生成请求。`schemaJSON` 为 JSON Schema 的序列化字符串，
/// 提供时用 API 的结构化输出保证返回合法 JSON。
public struct CloudRequest: Sendable, Equatable {
    public var system: String
    public var user: String
    public var maxTokens: Int
    public var schemaName: String?
    public var schemaJSON: String?

    public init(system: String, user: String, maxTokens: Int, schemaName: String? = nil, schemaJSON: String? = nil) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.schemaName = schemaName
        self.schemaJSON = schemaJSON
    }
}

public struct CloudResponse: Sendable, Equatable {
    public let text: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
}

/// 错误信息中绝不包含 API Key 或请求内容。
public enum CloudError: Error, Equatable, CustomStringConvertible {
    case missingAPIKey(CloudProvider)
    case missingModel(CloudProvider)
    case unauthorized(String)
    case badRequest(String)
    case rateLimited
    case server(Int)
    case network(String)
    /// 安全策略拒绝（Anthropic `stop_reason: refusal` / OpenAI `message.refusal`）。
    case refusal(String?)
    /// 输出达到上限被截断。
    case truncated
    case invalidResponse
    /// 订阅额度用尽（ChatGPT `subscription_sharing_usage_limit_exceeded` / Claude 订阅限额）。
    case planUsageLimit(String)
    /// 订阅套餐不符合使用条件。
    case planNotEligible(String)
    /// 需要（重新）登录：ChatGPT 未登录或会话已失效，或 Claude Code 未登录。
    case signInRequired(String)
    /// 本机找不到 Claude Code 程序。
    case toolNotFound(String)
    /// 本地子进程或回调服务失败。
    case local(String)

    public var description: String {
        switch self {
        case .missingAPIKey(let p): "未设置 \(p.displayName) API Key"
        case .missingModel(let p): "未设置 \(p.displayName) 模型"
        case .unauthorized(let m): "API Key 无效或无权限：\(m)"
        case .badRequest(let m): "请求被拒绝：\(m)"
        case .rateLimited: "请求过于频繁（429），稍后重试"
        case .server(let code): "服务端错误（\(code)），稍后重试"
        case .network(let m): "网络错误：\(m)"
        case .refusal(let m): "模型拒绝回答" + (m.map { "：\($0)" } ?? "")
        case .truncated: "输出被截断（达到 max_tokens）"
        case .invalidResponse: "无法解析服务端响应"
        case .planUsageLimit(let m): "订阅额度已用尽" + (m.isEmpty ? "" : "：\(m)")
        case .planNotEligible(let m): "当前订阅套餐不能用于此功能" + (m.isEmpty ? "" : "：\(m)")
        case .signInRequired(let m): "需要登录：\(m)"
        case .toolNotFound(let m): "找不到程序：\(m)"
        case .local(let m): "本地错误：\(m)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .network: true
        default: false
        }
    }
}

public protocol CloudTextClient: Sendable {
    /// 例如 `anthropic:claude-opus-5-5`。写入整理日志。
    var identifier: String { get }
    func generate(_ request: CloudRequest) async throws -> CloudResponse
}

// MARK: - Transport

/// HTTP 发送与重试。`sleep` 可注入，测试中不真正等待。
public struct HTTPTransport: Sendable {
    public var session: URLSession
    public var maxRetries: Int
    public var sleep: @Sendable (TimeInterval) async -> Void

    public init(
        session: URLSession = .shared,
        maxRetries: Int = 2,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.session = session
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    /// 429、5xx 与网络错误按 2、4 秒退避重试；其余状态码交给 `mapError` 转成错误。
    func send(
        _ request: URLRequest,
        mapError: (Int, Data) -> CloudError
    ) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
                if (200..<300).contains(http.statusCode) { return data }
                throw mapError(http.statusCode, data)
            } catch let error as CloudError {
                guard error.isRetryable, attempt < maxRetries else { throw error }
            } catch let error as URLError {
                let mapped = CloudError.network(error.code == .timedOut ? "请求超时" : "\(error.code.rawValue)")
                guard attempt < maxRetries else { throw mapped }
            }
            attempt += 1
            await sleep(pow(2, Double(attempt)))
        }
    }

    static func errorMessage(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let err = obj["error"] as? [String: Any], let message = err["message"] as? String {
            return String(message.prefix(200))
        }
        return ""
    }

    static func standardError(status: Int, data: Data) -> CloudError {
        let message = errorMessage(data)
        switch status {
        case 401, 403: return .unauthorized(message)
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .badRequest(message.isEmpty ? "HTTP \(status)" : message)
        }
    }
}

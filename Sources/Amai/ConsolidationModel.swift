import AmaiCloud
import AmaiCore
import AmaiExtraction
import AmaiMemory
import Foundation

/// 记忆整理使用的模型（ADR-0004 / ADR-0005）。保存在 `config.json` 的 `consolidationModel` 字段；
/// API Key 与 ChatGPT 令牌不在这里，只存钥匙串。抽取层不受此配置影响，始终本地。
struct ConsolidationModelConfiguration: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        /// 本机 MLX 模型（默认，不联网）。
        case local
        /// Anthropic / OpenAI API Key（ADR-0004）。
        case apiKey
        /// ChatGPT 订阅额度，经官方 Sign in with ChatGPT（ADR-0005）。
        case chatgptPlan
        /// Claude 订阅额度，经本机已登录的 Claude Code CLI（ADR-0005）。
        case claudeCode

        var isCloud: Bool { self != .local }

        var title: String {
            switch self {
            case .local: String(localized: "本地模型（默认，不联网）")
            case .apiKey: "API Key（Anthropic / OpenAI）"
            case .chatgptPlan: String(localized: "ChatGPT 订阅")
            case .claudeCode: String(localized: "Claude 订阅（本机 Claude Code）")
            }
        }

        /// 兼容 ADR-0004 的旧值 `cloud`。
        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = raw == "cloud" ? .apiKey : (Mode(rawValue: raw) ?? .local)
        }
    }

    var mode: Mode = .local
    var provider: CloudProvider = .anthropic
    var anthropicModel = AnthropicClient.defaultModel
    var anthropicEffort = "high"
    var openaiModel = ""
    /// 空字符串表示不发送 reasoning_effort（非推理模型不接受该参数）。
    var openaiReasoningEffort = ""
    var openaiBaseURL = OpenAIClient.defaultBaseURL.absoluteString
    /// ChatGPT 订阅模型的 slug（来自 `GET /v1/models`）。
    var chatgptModel = ""
    var claudeCodeModel = ClaudeCodeClient.defaultModel
    /// Claude Code 程序路径；为空时自动查找。
    var claudeCodePath = ""

    static let `default` = ConsolidationModelConfiguration()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, provider, anthropicModel, anthropicEffort, openaiModel, openaiReasoningEffort, openaiBaseURL
        case chatgptModel, claudeCodeModel, claudeCodePath
    }

    /// 缺字段补默认值，未知取值回退默认，避免一处写错导致整份配置失效。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? d.mode
        provider = (try? c.decodeIfPresent(CloudProvider.self, forKey: .provider)) ?? d.provider
        anthropicModel = (try? c.decodeIfPresent(String.self, forKey: .anthropicModel)) ?? d.anthropicModel
        anthropicEffort = (try? c.decodeIfPresent(String.self, forKey: .anthropicEffort)) ?? d.anthropicEffort
        openaiModel = (try? c.decodeIfPresent(String.self, forKey: .openaiModel)) ?? d.openaiModel
        openaiReasoningEffort = (try? c.decodeIfPresent(String.self, forKey: .openaiReasoningEffort)) ?? d.openaiReasoningEffort
        openaiBaseURL = (try? c.decodeIfPresent(String.self, forKey: .openaiBaseURL)) ?? d.openaiBaseURL
        chatgptModel = (try? c.decodeIfPresent(String.self, forKey: .chatgptModel)) ?? d.chatgptModel
        claudeCodeModel = (try? c.decodeIfPresent(String.self, forKey: .claudeCodeModel)) ?? d.claudeCodeModel
        claudeCodePath = (try? c.decodeIfPresent(String.self, forKey: .claudeCodePath)) ?? d.claudeCodePath
    }

    /// API Key 模式的客户端。Key 缺失时客户端在调用时报错。
    func apiKeyClient(apiKey: String?) -> any CloudTextClient {
        switch provider {
        case .anthropic:
            return AnthropicClient(
                apiKey: apiKey ?? "",
                model: anthropicModel.trimmingCharacters(in: .whitespaces),
                effort: anthropicEffort.isEmpty ? nil : anthropicEffort
            )
        case .openai:
            return OpenAIClient(
                apiKey: apiKey ?? "",
                model: openaiModel.trimmingCharacters(in: .whitespaces),
                reasoningEffort: openaiReasoningEffort.isEmpty ? nil : openaiReasoningEffort,
                baseURL: URL(string: openaiBaseURL.trimmingCharacters(in: .whitespaces)) ?? OpenAIClient.defaultBaseURL
            )
        }
    }

    /// 数据发往的服务名称，用于隐私确认。
    var serviceName: String {
        switch mode {
        case .local: String(localized: "本机")
        case .apiKey: provider.displayName
        case .chatgptPlan: "OpenAI（ChatGPT）"
        case .claudeCode: String(localized: "Anthropic（经 Claude Code）")
        }
    }
}

/// 云端模式：把 AmaiCloud 的客户端接到记忆层接口上。
/// 发送前对全部文本再做一次凭据脱敏；日志只记录 token 用量，不记录内容。
struct CloudLanguageModel: MemoryLanguageModel {
    let client: any CloudTextClient
    private let log = AmaiLog.logger("memory.cloud")

    var identifier: String { client.identifier }

    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
        let request = CloudRequest(
            system: SecretRedactor.redact(system).text,
            user: SecretRedactor.redact(user).text,
            maxTokens: maxTokens,
            schemaName: schema?.name,
            schemaJSON: schema?.json
        )
        let started = Date()
        let response = try await client.generate(request)
        log.info("cloud call ok: \(response.inputTokens) in / \(response.outputTokens) out tokens, \(Int(Date().timeIntervalSince(started))) s")
        return response.text
    }
}

/// 某个来源不可用时（例如找不到 Claude Code）的占位实现：调用时报出明确原因。
struct UnavailableLanguageModel: MemoryLanguageModel {
    let identifier: String
    let error: CloudError

    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
        throw error
    }
}

/// 构建整理模型需要的共享依赖。
struct ConsolidationModelContext {
    let local: any ModelProvider
    let keychain: KeychainStore
    let chatGPT: ChatGPTSession
    /// Claude Code 子进程的专用空工作目录。
    let claudeWorkdir: URL
}

enum ConsolidationModelFactory {
    static func client(_ config: ConsolidationModelConfiguration, context: ConsolidationModelContext) -> Result<any CloudTextClient, CloudError> {
        switch config.mode {
        case .local:
            return .failure(.local(String(localized: "本地模式没有云端客户端")))
        case .apiKey:
            return .success(config.apiKeyClient(apiKey: context.keychain.apiKey(for: config.provider)))
        case .chatgptPlan:
            return .success(ChatGPTPlanClient(session: context.chatGPT, model: config.chatgptModel))
        case .claudeCode:
            guard let exe = ClaudeCodeLocator.locate(configured: config.claudeCodePath) else {
                return .failure(.toolNotFound(config.claudeCodePath.isEmpty ? String(localized: "未在常见位置找到 claude，请在设置中指定路径") : config.claudeCodePath))
            }
            return .success(ClaudeCodeClient(executable: exe, model: config.claudeCodeModel, workingDirectory: context.claudeWorkdir))
        }
    }

    static func make(_ config: ConsolidationModelConfiguration, context: ConsolidationModelContext) -> any MemoryLanguageModel {
        if config.mode == .local { return LocalLanguageModel(provider: context.local) }
        switch client(config, context: context) {
        case .success(let client):
            return CloudLanguageModel(client: client)
        case .failure(let error):
            return UnavailableLanguageModel(identifier: "\(config.mode.rawValue):unavailable", error: error)
        }
    }

    /// 菜单与设置窗口中显示的说明。ChatGPT 订阅按官方 UI 规范显示 "Using ChatGPT plan"。
    static func label(_ config: ConsolidationModelConfiguration, localIdentifier: String) -> String {
        switch config.mode {
        case .local:
            return String(localized: "本地 · \(localIdentifier)")
        case .apiKey:
            let model = config.provider == .anthropic ? config.anthropicModel : config.openaiModel
            return "API Key · \(config.provider.displayName) · \(model.isEmpty ? String(localized: "未设置模型") : model)"
        case .chatgptPlan:
            return "Using ChatGPT plan · \(config.chatgptModel.isEmpty ? String(localized: "未选择模型") : config.chatgptModel)"
        case .claudeCode:
            return String(localized: "Claude 订阅（Claude Code）· \(config.claudeCodeModel)")
        }
    }
}

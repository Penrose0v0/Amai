import AmaiCore
import Foundation

/// 本地 MLX 模型的单次调用入口（抽取、记忆整理）。权重由 `LocalModelRuntime` 中对应的
/// `LocalModelHost` 持有，同一个模型标签的多个 Provider / ChatModel 共用一份。
public struct MLXModelProvider: ModelProvider {
    public let identifier: String
    public let sendsDataOffDevice = false
    public let modelTag: String
    public let priority: InferencePriority
    private let host: LocalModelHost

    public init(modelTag: String, priority: InferencePriority = .background) {
        self.modelTag = modelTag
        self.priority = priority
        self.identifier = Self.identifier(for: modelTag)
        self.host = LocalModelRuntime.host(for: modelTag)
    }

    static func identifier(for modelTag: String) -> String {
        "mlx:" + (modelTag.split(separator: "/").last.map(String.init) ?? modelTag)
    }

    public var isLoaded: Bool {
        get async { await host.isLoaded }
    }

    public func generate(_ request: ModelRequest) async throws -> ModelResponse {
        try await host.generate(request, identifier: identifier, priority: priority)
    }

    public func unload(reason: String) async {
        await host.unload(reason: reason)
    }

    /// 去掉可能出现的思考块与首尾空白。
    public static func clean(_ text: String) -> String {
        ThinkingFilter.clean(text)
    }
}

/// 本地 MLX 模型的对话入口：流式、多轮、工具调用，跨轮复用 KV cache。
public struct MLXChatModel: ChatModel {
    public let identifier: String
    public let sendsDataOffDevice = false
    /// 目录中的模型全部是视觉语言模型。
    public let supportsImages = true
    public let supportsTools = true
    public let modelTag: String
    public let priority: InferencePriority
    private let host: LocalModelHost

    public init(modelTag: String, priority: InferencePriority = .interactive) {
        self.modelTag = modelTag
        self.priority = priority
        self.identifier = MLXModelProvider.identifier(for: modelTag)
        self.host = LocalModelRuntime.host(for: modelTag)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        host.chat(request, priority: priority)
    }

    public func resetConversation() async {
        await host.resetChat()
    }

    public func prepare(_ request: ChatRequest) async {
        await host.prefill(request, priority: priority)
    }

    /// 最近一次预填充与最近一次对话请求的缓存统计（集成测试与性能检查用）。
    public var prefixStats: (prefill: LocalModelHost.PrefixStats, chat: LocalModelHost.PrefixStats) {
        get async { (await host.lastPrefill, await host.lastChat) }
    }

    /// 最近一次请求是否复用了 KV cache（集成测试用）。
    public var lastRequestReusedCache: Bool {
        get async { await host.lastChatReusedCache }
    }
}

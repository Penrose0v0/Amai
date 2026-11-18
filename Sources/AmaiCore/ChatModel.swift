import Foundation

// 对话式模型调用的统一契约：本地 MLX 与各云端 Provider 都实现 `ChatModel`，
// Agent 循环、快速文本操作只面向这一个接口（参考 Pi SDK 的"统一消息 + 流式事件 + 工具调用"）。
//
// 请求是无状态的：每次给出完整的 system、工具定义与消息列表。消息列表只追加、不改写，
// 这样云端可以命中前缀缓存，本地实现可以把上一轮的 KV cache 接着用。

/// 一个可被模型调用的工具。`parametersJSON` 是 JSON Schema（object）的序列化字符串，便于跨并发域传递。
public struct ChatToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

/// 模型发出的一次工具调用。`argumentsJSON` 是参数对象的 JSON 字符串。
public struct ChatToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// 解析后的参数；格式不对时为空字典。
    public var arguments: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
    }
}

/// 随消息发送的一张图片（JPEG）。`perceptualHash` 用于判断"屏幕没变"，本地实现据此跳过重复编码。
public struct ChatImage: Sendable, Equatable {
    public let jpeg: Data
    public let perceptualHash: UInt64?

    public init(jpeg: Data, perceptualHash: UInt64? = nil) {
        self.jpeg = jpeg
        self.perceptualHash = perceptualHash
    }
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
        /// 工具结果。`toolCallId` 指向它回答的那次调用。
        case tool
    }

    public var role: Role
    public var text: String
    public var images: [ChatImage]
    /// 仅 assistant：这一轮发出的工具调用。
    public var toolCalls: [ChatToolCall]
    /// 仅 tool。
    public var toolCallId: String?
    public var toolName: String?
    /// 仅 assistant：Provider 要求原样带回的内容（例如 Anthropic 的思考块及其签名）。
    /// 对其他 Provider 没有意义，换模型后被忽略；不参与显示与持久化之外的任何逻辑。
    public var providerState: String?

    public init(
        role: Role, text: String, images: [ChatImage] = [], toolCalls: [ChatToolCall] = [],
        toolCallId: String? = nil, toolName: String? = nil, providerState: String? = nil
    ) {
        self.providerState = providerState
        self.role = role
        self.text = text
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
    }

    public static func user(_ text: String, images: [ChatImage] = []) -> ChatMessage {
        ChatMessage(role: .user, text: text, images: images)
    }

    public static func assistant(_ text: String, toolCalls: [ChatToolCall] = []) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, toolCalls: toolCalls)
    }

    public static func tool(_ text: String, call: ChatToolCall, images: [ChatImage] = []) -> ChatMessage {
        ChatMessage(role: .tool, text: text, images: images, toolCallId: call.id, toolName: call.name)
    }
}

public struct ChatRequest: Sendable, Equatable {
    /// 固定前缀：身份与规则。同一会话内必须字节一致，否则缓存失效。
    public var system: String
    public var tools: [ChatToolSpec]
    public var messages: [ChatMessage]
    public var maxTokens: Int
    public var temperature: Float
    /// 一次性请求（快速文本操作）：不读也不写会话缓存，避免顶掉正在进行的对话的 KV cache。
    public var ephemeral: Bool

    public init(
        system: String, tools: [ChatToolSpec] = [], messages: [ChatMessage],
        maxTokens: Int = 2048, temperature: Float = 0.3, ephemeral: Bool = false
    ) {
        self.system = system
        self.tools = tools
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.ephemeral = ephemeral
    }
}

public struct ChatUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// 命中缓存的输入 token（云端的 prompt cache；本地为复用的 KV cache 是否命中，命中时为非零）。
    public var cachedInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }
}

public enum ChatEvent: Sendable, Equatable {
    case text(String)
    case toolCall(ChatToolCall)
    /// 这一轮 assistant 消息需要原样带回的 Provider 内容（见 `ChatMessage.providerState`）。在 `finished` 之前发出。
    case providerState(String)
    /// 一轮生成正常结束。之后流关闭。
    case finished(ChatUsage)
}

public protocol ChatModel: Sendable {
    /// 例如 `mlx:gemma-4-e4b-it-4bit`、`anthropic:claude-opus-5-5`。
    var identifier: String { get }
    /// 本地实现为 false；任何网络调用的实现必须为 true。
    var sendsDataOffDevice: Bool { get }
    var supportsImages: Bool { get }
    var supportsTools: Bool { get }

    /// 流式生成一轮。取消：终止对返回流的迭代即可。
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>

    /// 用户离开当前会话时调用，释放与它绑定的状态（本地的 KV cache）。
    func resetConversation() async

    /// 在用户提交之前提前做能做的事（加载模型、把已经确定的前缀算进缓存），让提交后更快出第一个字。
    ///
    /// `request.messages` 的最后一条如果是 user 消息，表示"接下来要发的那条消息会以这段文字开头"；
    /// 之后真正的请求必须只在它后面追加，前缀才用得上。没有这种能力的实现什么都不做。
    func prepare(_ request: ChatRequest) async
}

extension ChatModel {
    public func resetConversation() async {}

    public func prepare(_ request: ChatRequest) async {}

    /// 不需要流式输出时的便捷调用：返回完整文本（忽略工具调用）。
    public func complete(_ request: ChatRequest) async throws -> String {
        var text = ""
        for try await event in stream(request) {
            if case .text(let delta) = event { text += delta }
        }
        return text
    }
}

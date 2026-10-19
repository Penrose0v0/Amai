import Foundation

/// 模型调用的统一入口。所有 LLM / VLM 调用必须经过此协议，
/// 外发边界由 `sendsDataOffDevice` 显式声明并受 PrivacyPolicy 外发开关控制。
public protocol ModelProvider: Sendable {
    /// 例如 `mlx:gemma-4-e4b-it-4bit`。写入 Observation / ActivitySegment 的 `provider` 字段。
    var identifier: String { get }
    /// 本地实现为 false；任何网络调用的实现必须为 true。
    var sendsDataOffDevice: Bool { get }

    func generate(_ request: ModelRequest) async throws -> ModelResponse
}

/// 提示词分为两段以复用 KV cache（Eira 实证，ADR-0002）：
/// `cacheable` 跨调用保持字节一致；任何会变的内容（时间、截图描述、当前批次）放 `dynamic`。
public struct ModelRequest: Sendable, Equatable {
    public var cacheable: String
    public var dynamic: String
    /// JPEG 数据；仅 VLM 使用。
    public var images: [Data]
    public var maxTokens: Int

    public init(cacheable: String, dynamic: String, images: [Data] = [], maxTokens: Int = 1024) {
        self.cacheable = cacheable
        self.dynamic = dynamic
        self.images = images
        self.maxTokens = maxTokens
    }
}

public struct ModelResponse: Sendable, Equatable {
    public let text: String
    public let provider: String
    public let latencyMs: Int

    public init(text: String, provider: String, latencyMs: Int) {
        self.text = text
        self.provider = provider
        self.latencyMs = latencyMs
    }
}

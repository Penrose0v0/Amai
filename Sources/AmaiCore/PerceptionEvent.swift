import Foundation

/// 感知层的输出单元。只描述"采到了什么、何时、来自哪里"，不包含任何理解。
/// 字段定义见 docs/architecture.md §3。
public struct PerceptionEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// 墙钟时间，用于人类可读的时间线与跨会话对齐。
    public let wallTime: Date
    /// 单调时钟（纳秒），用于排序与跨模态对齐；不受系统时间调整影响。
    public let monoTime: UInt64
    public let source: PerceptionSource
    public let kind: PerceptionKind
    /// 原始数据在 RawSpool 中的引用（相对路径或 blob id）。被跳过的事件为 nil。
    public let payloadRef: String?
    public let metadata: PerceptionMetadata
    public let sensitivity: Sensitivity

    public init(
        id: UUID = UUID(),
        wallTime: Date,
        monoTime: UInt64,
        source: PerceptionSource,
        kind: PerceptionKind,
        payloadRef: String?,
        metadata: PerceptionMetadata = PerceptionMetadata(),
        sensitivity: Sensitivity = .normal
    ) {
        self.id = id
        self.wallTime = wallTime
        self.monoTime = monoTime
        self.source = source
        self.kind = kind
        self.payloadRef = payloadRef
        self.metadata = metadata
        self.sensitivity = sensitivity
    }
}

public enum PerceptionSource: String, Codable, Sendable {
    case screen
    case audio
    case interaction
    case system
}

public enum PerceptionKind: String, Codable, Sendable {
    case screenFrame
    case audioChunk
    case interaction
    case focusChange
    case permissionChange
}

/// `skipped`：被 PrivacyPolicy 跳过（安全输入、排除应用、用户暂停）。
/// 只保留占位以维持时间线连续，不含任何内容。
public enum Sensitivity: String, Codable, Sendable {
    case normal
    case skipped
}

/// 事件元数据。这些字段可能出现在记忆与检查器中，但**绝不能进入日志**。
public struct PerceptionMetadata: Codable, Sendable, Equatable {
    public var app: String?
    public var bundleId: String?
    public var windowTitle: String?
    public var displayId: UInt32?
    public var durationMs: Int?
    /// 截图时距上次用户输入的秒数。空闲判定留给抽取层。
    public var idleSeconds: Double?

    public init(
        app: String? = nil,
        bundleId: String? = nil,
        windowTitle: String? = nil,
        displayId: UInt32? = nil,
        durationMs: Int? = nil,
        idleSeconds: Double? = nil
    ) {
        self.app = app
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.displayId = displayId
        self.durationMs = durationMs
        self.idleSeconds = idleSeconds
    }
}

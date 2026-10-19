import Foundation

/// 闭区间时间范围。`end >= start` 由构造方保证。
public struct TimeRange: Codable, Sendable, Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        precondition(end >= start, "TimeRange end must not precede start")
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public enum Modality: String, Codable, Sendable {
    case screen
    case audio
    case interaction
}

/// 观察事实 vs 模型推断。这是记忆写入规则的基础，不允许自动升级。
public enum ObservationKind: String, Codable, Sendable {
    case fact
    case inference
}

/// 抽取层的最小输出单元：一段时间内、来自某一模态的一条语义信息。
public struct Observation: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timeRange: TimeRange
    public let modality: Modality
    public let kind: ObservationKind
    public let content: String
    /// 0...1。
    public let confidence: Double
    public let sourceEvents: [UUID]
    /// 产生该观察的组件 / 模型标识，例如 `vision-ocr`、`mlx:gemma-4-e4b`。
    public let provider: String

    public init(
        id: UUID = UUID(),
        timeRange: TimeRange,
        modality: Modality,
        kind: ObservationKind,
        content: String,
        confidence: Double,
        sourceEvents: [UUID],
        provider: String
    ) {
        precondition((0...1).contains(confidence), "confidence must be within 0...1")
        self.id = id
        self.timeRange = timeRange
        self.modality = modality
        self.kind = kind
        self.content = content
        self.confidence = confidence
        self.sourceEvents = sourceEvents
        self.provider = provider
    }
}

import Foundation

/// 闭区间时间范围。`end >= start` 由构造方保证。
public struct TimeRange: Codable, Sendable, Equatable, Hashable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        precondition(end >= start, "TimeRange end must not precede start")
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func contains(_ date: Date) -> Bool { date >= start && date <= end }
}

public enum Modality: String, Codable, Sendable {
    case screen
    case audio
    case interaction
}

/// 观察事实 vs 模型推断。这是记忆写入规则的基础，不允许自动升级。
/// - `fact`：感知层元数据、OCR 识别出的文字等可直接核对的内容；
/// - `inference`：VLM / LLM 生成的描述与归纳。
public enum ObservationKind: String, Codable, Sendable {
    case fact
    case inference
}

/// 指向原始数据的证据引用。原始帧被 TTL 清理后，`eventId` 与时间仍可在索引中找到。
public struct Evidence: Codable, Sendable, Equatable, Hashable {
    public let eventId: UUID
    public let time: Date
    /// 视频分段路径（相对 raw/）。
    public let payloadRef: String?
    public let frameIndex: Int?

    public init(eventId: UUID, time: Date, payloadRef: String?, frameIndex: Int?) {
        self.eventId = eventId
        self.time = time
        self.payloadRef = payloadRef
        self.frameIndex = frameIndex
    }

    public init(event: PerceptionEvent) {
        self.init(
            eventId: event.id,
            time: event.wallTime,
            payloadRef: event.payloadRef,
            frameIndex: event.metadata.frameIndex
        )
    }
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
    public let evidence: [Evidence]
    /// 结构化字段，例如 `app`、`bundleId`、`idleSeconds`、`ocrLines`。
    public let attributes: [String: String]
    /// 产生该观察的组件 / 模型标识，例如 `vision-ocr`、`mlx:gemma-4-e4b-it-4bit`。
    public let provider: String

    public init(
        id: UUID = UUID(),
        timeRange: TimeRange,
        modality: Modality,
        kind: ObservationKind,
        content: String,
        confidence: Double,
        evidence: [Evidence],
        attributes: [String: String] = [:],
        provider: String
    ) {
        self.id = id
        self.timeRange = timeRange
        self.modality = modality
        self.kind = kind
        self.content = content
        self.confidence = min(1, max(0, confidence))
        self.evidence = evidence
        self.attributes = attributes
        self.provider = provider
    }
}

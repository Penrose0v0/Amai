import Foundation

/// 活动分类。初始集合，定稿前允许调整（docs/architecture.md §3）。
public enum ActivityCategory: String, Codable, Sendable, CaseIterable {
    case work
    case research
    case communication
    case reading
    case entertainment
    case idle
    case other
}

/// 一段时间窗口内用户活动的识别结果。活动识别本质上是推断，
/// 因此没有 `kind` 字段：写入记忆时一律按 `inferred` 处理。
public struct ActivitySegment: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timeRange: TimeRange
    public let title: String
    public let summary: String
    public let category: ActivityCategory
    /// 涉及的应用 bundle id。
    public let apps: [String]
    public let observations: [UUID]
    public let confidence: Double
    public let provider: String

    public init(
        id: UUID = UUID(),
        timeRange: TimeRange,
        title: String,
        summary: String,
        category: ActivityCategory,
        apps: [String],
        observations: [UUID],
        confidence: Double,
        provider: String
    ) {
        precondition((0...1).contains(confidence), "confidence must be within 0...1")
        self.id = id
        self.timeRange = timeRange
        self.title = title
        self.summary = summary
        self.category = category
        self.apps = apps
        self.observations = observations
        self.confidence = confidence
        self.provider = provider
    }
}

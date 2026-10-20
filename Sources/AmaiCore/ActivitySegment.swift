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

/// 一段时间内用户活动的识别结果。活动识别本质上是推断，
/// 写入记忆时一律按 `inferred` 处理。
///
/// 一个处理窗口可以产生多个片段，片段也可以跨窗口延续：延续时沿用原 `id`
/// 并扩展 `timeRange`，`updatedAt` 随之更新，记忆层据此做增量写入。
public struct ActivitySegment: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timeRange: TimeRange
    public let title: String
    public let summary: String
    public let category: ActivityCategory
    /// 涉及的应用 bundle id，按首次出现顺序。
    public let apps: [String]
    public let observations: [UUID]
    /// 关键帧引用，供检查器回看与检索。
    public let evidence: [Evidence]
    public let confidence: Double
    /// 例如 `mlx:gemma-4-e4b-it-4bit`、`rule:idle`、`fallback:metadata`。
    public let provider: String
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        timeRange: TimeRange,
        title: String,
        summary: String,
        category: ActivityCategory,
        apps: [String],
        observations: [UUID],
        evidence: [Evidence] = [],
        confidence: Double,
        provider: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.timeRange = timeRange
        self.title = title
        self.summary = summary
        self.category = category
        self.apps = apps
        self.observations = observations
        self.evidence = evidence
        self.confidence = min(1, max(0, confidence))
        self.provider = provider
        self.updatedAt = updatedAt
    }
}

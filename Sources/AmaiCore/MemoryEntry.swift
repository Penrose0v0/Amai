import Foundation

/// 记忆条目的来源类别。优先级 stated > confirmed > observed > inferred，
/// 用于冲突处理；`inferred` 永远不会自动升级（docs/memory.md §4.2）。
public enum MemoryEntryKind: String, Codable, Sendable {
    case observed
    case stated
    case inferred
    case confirmed
}

/// 写入 Markdown 的最小单元。`file` 为相对记忆目录的路径，`section` 为二级标题文本。
public struct MemoryEntry: Codable, Sendable, Equatable {
    public let file: String
    public let section: String
    public let content: String
    public let timestamp: Date
    public let kind: MemoryEntryKind
    /// 来源引用，例如 `seg:<ActivitySegment.id>`。
    public let sourceRefs: [String]

    public init(
        file: String,
        section: String,
        content: String,
        timestamp: Date,
        kind: MemoryEntryKind,
        sourceRefs: [String]
    ) {
        self.file = file
        self.section = section
        self.content = content
        self.timestamp = timestamp
        self.kind = kind
        self.sourceRefs = sourceRefs
    }
}

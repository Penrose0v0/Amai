import Foundation

/// 记忆条目的依据类型（不是真实性或置信度）。
///
/// - `observed`：有直接观察依据（屏幕文字、焦点记录等）；
/// - `inferred`：模型推断；
/// - `stated`：用户明确陈述；
/// - `confirmed`：用户明确确认过的信息；
/// - `unknown`：兼容状态，Schema v1 之前写入的条目没有记录依据，不得视为 `stated`。
///
/// 依据只能在有明确用户陈述或确认时提升，`inferred` / `unknown` 不会自动升级（docs/memory.md §4.2）。
public enum MemoryEntryKind: String, Codable, Sendable, CaseIterable {
    case observed
    case stated
    case inferred
    case confirmed
    case unknown

    /// 是否以用户本人为依据。提升到这一级需要用户陈述或确认的证据。
    public var isUserBacked: Bool { self == .stated || self == .confirmed }

    /// 未知取值按兼容状态处理，避免读入时丢弃条目。
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryEntryKind(rawValue: raw) ?? .unknown
    }
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

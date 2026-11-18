import AmaiCore
import AmaiMemory
import Foundation

/// 回答所依据的一处记忆。由后端检索的实际结果记录，而不是靠模型自己在回答里引用，
/// 所以界面上列出的来源一定是这一轮真正放进提示词的内容。
public struct MemorySource: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let category: MemoryCategory
    /// 记忆目录下的相对路径，例如 `work.md`、`daily/2026-11-10.md`。
    public let file: String
    public let section: String?
    /// 内容对应的日期（YYYY-MM-DD）。
    public let date: String?

    public var id: String { "\(file)#\(section ?? "")#\(date ?? "")" }

    public init(category: MemoryCategory, file: String, section: String? = nil, date: String? = nil) {
        self.category = category
        self.file = file
        self.section = section
        self.date = date
    }
}

/// 界面上显示、并持久化到会话记录里的一条消息。
public struct DisplayMessage: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public var sources: [MemorySource]
    public let createdAt: Date

    public init(id: UUID = UUID(), role: Role, text: String, sources: [MemorySource] = [], createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
        self.createdAt = createdAt
    }
}

/// 这一轮实际带给模型的实时上下文的摘要（供界面显示"正在看什么"）。
public struct TurnContextSummary: Sendable, Equatable {
    public var appName: String?
    public var windowTitle: String?
    public var hasSelection = false
    public var includesScreenText = false
    public var includesScreenshot = false
    public var recentStateCount = 0
    /// 这一轮放进提示词的记忆来源数。
    public var memorySourceCount = 0
    /// 是否直接用了面板唤出时准备好的上下文（没有重新识别屏幕）。
    public var usedPreparedContext = false
    /// 屏幕读取被隐私策略拦下时的原因代码。
    public var blockedReason: String?

    public init() {}
}

public enum AssistantEvent: Sendable, Equatable {
    /// 上下文与记忆已经准备好，接下来开始生成。
    case context(TurnContextSummary)
    case text(String)
    /// 一轮结束：完整回答与这一轮用到的记忆来源。
    case finished(text: String, sources: [MemorySource])
}

public enum AssistantError: Error, Equatable, Sendable {
    /// 上一轮还没结束。
    case busy
    case emptyMessage
}

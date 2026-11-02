import Foundation

/// 一个分区文件的读取结果。Markdown 原文是唯一事实来源，其余字段都是从原文派生的视图。
public struct MemoryDocument: Sendable, Equatable {
    public let category: MemoryCategory
    /// 相对记忆根目录。
    public let path: String
    public let url: URL
    public let markdown: String
    /// 去掉系统区块后的内容（用户手写部分，系统永不改写）。
    public let userMarkdown: String
    /// 系统区块中的条目，带小节、来源日期与依据类型。
    public let systemItems: [MemoryItem]
    public let modifiedAt: Date?
}

/// 记忆的统一只读接口（ADR-0006）：Memory Browser 使用它，今后的 Memory API / MCP / Skill 也复用它，
/// 并以 `MemoryCategory` 为单位授权。只读，不写文件，不触发整理。
public struct MemoryLibrary: Sendable {
    public let root: URL
    private let index: MemoryIndex?
    private let timeZone: TimeZone

    public init(root: URL, index: MemoryIndex?, timeZone: TimeZone = .current) {
        self.root = root
        self.index = index
        self.timeZone = timeZone
    }

    /// 分区文件的绝对路径（daily 为目录）。
    public func url(for category: MemoryCategory) -> URL {
        root.appendingPathComponent(category.file ?? MemoryDirectory.dailyDirectory, isDirectory: category == .daily)
    }

    /// 读取一个单文件分区；文件不存在或不可读时为 nil。daily 请用 `daily(on:)`。
    public func document(_ category: MemoryCategory) -> MemoryDocument? {
        guard let path = category.file else { return nil }
        return load(path, category: category)
    }

    /// 某天的 daily 文件。
    public func daily(on day: Date) -> MemoryDocument? {
        load(MemoryDirectory.dailyFile(for: day, timeZone: timeZone), category: .daily)
    }

    /// 已有 daily 文件的日期名（YYYY-MM-DD），新的在前。
    public func dailyDays() -> [String] {
        MemoryStore.markdownFiles(in: root)
            .filter { $0.hasPrefix(MemoryDirectory.dailyDirectory + "/") }
            .map { String($0.dropFirst(MemoryDirectory.dailyDirectory.count + 1).dropLast(3)) }
            .sorted(by: >)
    }

    /// 在指定分区中检索（全文索引，section 粒度）。索引不可用时返回空。
    public func search(
        _ query: String,
        in categories: Set<MemoryCategory> = Set(MemoryCategory.allCases),
        limit: Int = 20
    ) async throws -> [MemoryHit] {
        guard let index else { return [] }
        return try await index.retrieve(query, categories: categories, limit: limit)
    }

    private func load(_ path: String, category: MemoryCategory) -> MemoryDocument? {
        let url = root.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var user = text
        var items: [MemoryItem] = []
        if category == .daily {
            for block in [Consolidator.digestBlock, TimelineBlock.block] { user = block.removing(from: user) }
        } else {
            items = Consolidator.memoryBlock.content(in: text).map(MemoryItems.parse) ?? []
            user = Consolidator.memoryBlock.removing(from: text)
        }
        return MemoryDocument(
            category: category, path: path, url: url, markdown: text,
            userMarkdown: user, systemItems: items, modifiedAt: modified
        )
    }
}

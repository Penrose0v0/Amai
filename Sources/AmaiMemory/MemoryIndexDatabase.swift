import Foundation
import GRDB

/// 记忆的派生索引（docs/memory.md §6）。可随时删除并从 Markdown 重建；
/// 存放在应用内部目录，不在记忆目录内。
public final class MemoryIndexDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// 打开磁盘数据库。目录不存在时创建。
    public convenience init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        try self.init(writer: try DatabasePool(path: path))
    }

    /// 内存数据库，供测试使用。
    public static func inMemory() throws -> MemoryIndexDatabase {
        try MemoryIndexDatabase(writer: try DatabaseQueue())
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 迁移只增不改。索引是派生物，schema 变化时可直接删库重建。
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1.sections") { db in
            try db.create(table: "section") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file", .text).notNull()
                t.column("heading", .text).notNull()
                t.column("content", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["file", "heading"])
            }
            try db.create(virtualTable: "section_fts", using: FTS5()) { t in
                t.synchronize(withTable: "section")
                t.tokenizer = .unicode61()
                t.column("file")
                t.column("heading")
                t.column("content")
            }
        }
        return migrator
    }
}

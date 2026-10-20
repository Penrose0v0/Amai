import Foundation
import GRDB

/// 记忆的派生索引（docs/memory.md §6）。可随时删除并从 Markdown 重建；
/// 存放在应用内部目录，不在记忆目录内。
public final class MemoryIndexDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// 打开磁盘数据库。打开或迁移失败时视为索引损坏：删除后重建（索引只是派生数据）。
    public convenience init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        do {
            try self.init(writer: try DatabasePool(path: path))
        } catch {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
            try self.init(writer: try DatabasePool(path: path))
        }
    }

    /// 内存数据库，供测试使用。
    public static func inMemory() throws -> MemoryIndexDatabase {
        try MemoryIndexDatabase(writer: try DatabaseQueue())
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 索引是派生物：schema 变化时直接改迁移、删库重建即可，不需要兼容旧库。
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = true
        migrator.registerMigration("v1") { db in
            try db.create(table: "section") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file", .text).notNull().indexed()
                t.column("heading", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("content", .text).notNull()
                /// daily 文件对应的日期（当天 00:00）；其他文件为 NULL。
                t.column("day", .datetime)
            }
            // trigram 分词：中文没有空格，按字切三元组才能检索到句子中间的词。
            try db.create(virtualTable: "section_fts", using: FTS5()) { t in
                t.synchronize(withTable: "section")
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("heading")
                t.column("content")
            }
            try db.create(table: "file_meta") { t in
                t.primaryKey("file", .text)
                t.column("mtime", .double).notNull()
                t.column("size", .integer).notNull()
            }
        }
        return migrator
    }
}

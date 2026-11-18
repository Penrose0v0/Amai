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
        // 混合检索（ADR-0011）：比 section 更细的块、预先分好词的全文索引、按内容哈希存放的向量。
        migrator.registerMigration("v2-chunks") { db in
            try db.create(table: "chunk") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file", .text).notNull().indexed()
                t.column("heading", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("content", .text).notNull()
                t.column("day", .datetime)
                /// 空格分隔的检索词（MemoryTerms.indexTerms），全文索引建在它上面。
                t.column("terms", .text).notNull()
                /// 向量文本（标题 + 正文）的哈希，对应 embedding.hash。
                t.column("hash", .text).notNull().indexed()
            }
            // 词已经分好（汉字 bigram），这里只需要按空格切。
            try db.create(virtualTable: "chunk_fts", using: FTS5()) { t in
                t.synchronize(withTable: "chunk")
                t.tokenizer = .unicode61()
                t.column("terms")
            }
            // 向量按（模型，内容哈希）存放：文件重建索引时内容没变的块不必重算。
            try db.create(table: "embedding") { t in
                t.column("model", .text).notNull()
                t.column("hash", .text).notNull()
                t.column("vector", .blob).notNull()
                t.primaryKey(["model", "hash"])
            }
            // 已有的索引里没有块：清掉文件记录，让下一次 refresh 把所有文件重新索引一遍。
            try db.execute(sql: "DELETE FROM file_meta")
        }
        return migrator
    }
}

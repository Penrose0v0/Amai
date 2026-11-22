import AmaiCore
import Foundation
import GRDB
import Testing
@testable import AmaiMemory

/// 记忆索引 memory.sqlite 是派生数据（docs/memory.md §6）：损坏时应删掉重建，不影响 Markdown 原文。
/// `MemoryIndexDatabase(path:)` 只在"打开或迁移失败"时重建；这里分别检查整文件损坏与文件头完好、数据页损坏两种情况。
@Suite("Memory index corruption", .serialized)
struct IndexCorruptionTests {
    struct Fixture {
        let root: URL
        let support: URL
        var dbPath: String { support.appendingPathComponent("index/memory.sqlite").path }

        init() throws {
            root = try tempDir()
            support = try tempDir()
            try MemoryDirectory.ensureDirectories(at: root)
            // 足够多的内容，让数据分布到第一页之后。
            let body = (0..<400).map { "- 第 \($0) 条：完成 Lumen 离线同步队列的联调与回归测试，记录 \($0)" }.joined(separator: "\n")
            try "# 工作\n\n## Lumen\n\n\(body)\n".write(to: root.appendingPathComponent("work.md"), atomically: true, encoding: .utf8)
        }

        /// 建好索引后关闭数据库（并合并 WAL），保证接下来对文件的破坏落在主库文件上。
        func buildIndex() async throws {
            let db = try MemoryIndexDatabase(path: dbPath)
            let index = MemoryIndex(root: root, database: db, timeZone: utc)
            try await index.refresh()
            #expect(try await !index.retrieve("Lumen").isEmpty)
            if let pool = db.writer as? DatabasePool {
                _ = try await pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
                try pool.close()
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: support)
        }
    }

    @Test("a file that is not a database at all is replaced and rebuilt from Markdown")
    func notADatabase() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.buildIndex()
        try Data(repeating: 0x5A, count: 8192).write(to: URL(fileURLWithPath: f.dbPath))

        let index = MemoryIndex(root: f.root, database: try MemoryIndexDatabase(path: f.dbPath), timeZone: utc)
        try await index.refresh()
        #expect(try await !index.retrieve("Lumen").isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("work.md").path))
    }

    /// 文件头完好、后面的数据页被破坏（磁盘错误等）。实测打开时 GRDB / SQLite 已能发现损坏，
    /// 走 `MemoryIndexDatabase(path:)` 的删库重建分支；这里保护这条恢复路径：重建后库完整、检索结果正确。
    @Test("damaged data pages behind an intact header are detected and the index is rebuilt")
    func damagedPages() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.buildIndex()
        let url = URL(fileURLWithPath: f.dbPath)
        var bytes = try Data(contentsOf: url)
        let pageSize = 4096
        try #require(bytes.count > pageSize * 4, "index too small to damage beyond page 1: \(bytes.count)")
        for i in (pageSize * 2)..<bytes.count where i % 7 == 0 { bytes[i] = 0xA5 }
        try bytes.write(to: url)

        let db = try MemoryIndexDatabase(path: f.dbPath)
        let integrity = try await db.writer.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") }
        #expect(integrity == ["ok"])

        let index = MemoryIndex(root: f.root, database: db, timeZone: utc)
        try await index.refresh()
        #expect(try await !index.retrieve("Lumen").isEmpty)
        let hits = try await index.search("第 399 条", embedder: nil, options: MemorySearchOptions())
        #expect(hits.contains { $0.file == "work.md" })
    }
}

import Foundation
import GRDB
import Testing
@testable import AmaiMemory

@Suite("MemoryLayout")
struct MemoryLayoutTests {
    @Test("daily file name uses the given time zone")
    func dailyFileName() throws {
        // 2026-10-19 23:30 东京时间 = 2026-10-19 14:30 UTC
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 19
        components.hour = 23; components.minute = 30
        components.timeZone = tokyo
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))

        #expect(MemoryLayout.dailyFile(for: date, timeZone: tokyo) == "daily/2026-10-19.md")
        // 同一时刻在夏威夷仍是 10-19 凌晨。
        let hawaii = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        #expect(MemoryLayout.dailyFile(for: date, timeZone: hawaii) == "daily/2026-10-19.md")
        // 在奥克兰已是 10-20。
        let auckland = try #require(TimeZone(identifier: "Pacific/Auckland"))
        #expect(MemoryLayout.dailyFile(for: date, timeZone: auckland) == "daily/2026-10-20.md")
    }

    @Test("health and finance are scaffold-only in MVP")
    func scaffoldOnly() {
        #expect(MemoryLayout.autoWrittenTopics.allSatisfy { !$0.hasPrefix("health/") && !$0.hasPrefix("finance/") })
        #expect(MemoryLayout.scaffoldOnlyTopics.contains("finance/expenses.md"))
    }
}

@Suite("MemoryIndexDatabase")
struct MemoryIndexDatabaseTests {
    @Test("migrates and supports FTS lookup")
    func migrateAndSearch() throws {
        let db = try MemoryIndexDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO section (file, heading, content, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: ["daily/2026-10-19.md", "时间线", "阅读 Screenpipe 源码", Date()]
            )
        }
        let hits = try db.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM section_fts WHERE section_fts MATCH ?",
                arguments: ["Screenpipe"]
            )
        }
        #expect(hits == 1)
    }
}

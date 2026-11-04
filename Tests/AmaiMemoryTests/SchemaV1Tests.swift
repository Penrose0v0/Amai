import AmaiCore
import Foundation
import Testing
@testable import AmaiMemory

@Suite("MemoryItem kind")
struct MemoryItemKindTests {
    @Test("legacy lines without kind parse as unknown and render unchanged")
    func legacy() {
        let body = "- 开发 Amai <!-- src:2026-10-19,2026-10-20 -->\n- 没有来源的条目"
        let items = MemoryItems.parse(body)
        #expect(items.map(\.kind) == [.unknown, .unknown])
        #expect(items[1].sources.isEmpty)
        #expect(MemoryItems.render(items) == body)
    }

    @Test("every kind round-trips through render and parse, with and without sources")
    func roundTrip() {
        let items = MemoryEntryKind.allCases.enumerated().map { i, kind in
            MemoryItem(text: "条目 \(i)", sources: i.isMultiple(of: 2) ? ["2026-10-19"] : [], section: "小节", kind: kind)
        }
        let body = MemoryItems.render(items)
        #expect(body.contains("- 条目 1 <!-- kind:stated -->"))
        #expect(body.contains("- 条目 4 <!-- src:2026-10-19 -->"))
        #expect(MemoryItems.parse(body) == items)
    }

    @Test("an unrecognised kind value keeps the entry as unknown instead of dropping it")
    func unrecognised() {
        let items = MemoryItems.parse("- 条目 <!-- src:2026-10-19 kind:rumour -->")
        #expect(items == [MemoryItem(text: "条目", sources: ["2026-10-19"], kind: .unknown)])
        let decoded = try? JSONDecoder().decode(MemoryItem.self, from: Data(#"{"text":"x","kind":"rumour"}"#.utf8))
        #expect(decoded?.kind == .unknown)
    }

    @Test("JSON serialization keeps kind")
    func codable() throws {
        let item = MemoryItem(text: "x", sources: ["2026-10-19"], section: "s", kind: .observed)
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(MemoryItem.self, from: data) == item)
    }

    @Test("merging only combines identical text with the same kind; sources are unioned")
    func merge() {
        let items = MemoryItems.sanitize([
            MemoryItem(text: "完成 M2", sources: ["2026-10-19"], kind: .inferred),
            MemoryItem(text: "完成 M2。", sources: ["2026-10-20"], kind: .inferred),
            MemoryItem(text: "完成 M2", sources: ["2026-10-21"], kind: .stated),
        ], fallbackSource: nil, limit: 10)
        #expect(items == [
            MemoryItem(text: "完成 M2", sources: ["2026-10-19", "2026-10-20"], kind: .inferred),
            MemoryItem(text: "完成 M2", sources: ["2026-10-21"], kind: .stated),
        ])
    }

    @Test("reconcile keeps the previous kind and blocks unapproved upgrades")
    func illegalUpgrade() {
        let previous = [
            MemoryItem(text: "喜欢 Swift", sources: ["2026-10-18"], kind: .inferred),
            MemoryItem(text: "住在东京", sources: ["2026-10-17"], kind: .unknown),
            MemoryItem(text: "博士二年级", sources: ["2026-10-16"], kind: .stated),
        ]
        let proposed = [
            MemoryItem(text: "喜欢 Swift。", sources: ["2026-10-19"], kind: .confirmed),
            MemoryItem(text: "住在东京", sources: [], kind: .stated),
            MemoryItem(text: "博士二年级", sources: ["2026-10-16"], kind: .inferred),
            MemoryItem(text: "生日是 3 月", sources: ["2026-10-19"], kind: .stated),
            MemoryItem(text: "常用 Xcode", sources: ["2026-10-19"], kind: .observed),
        ]
        let result = MemoryItems.reconcileKinds(proposed, previous: previous, defaultKind: .inferred)
        #expect(result.map(\.kind) == [.inferred, .unknown, .stated, .inferred, .observed])
        #expect(result[0].sources == ["2026-10-18", "2026-10-19"])
        #expect(result[1].sources == ["2026-10-17"])

        // 有明确依据时（由调用方判断）才允许升级。
        let approved = MemoryItems.reconcileKinds(
            [proposed[0]], previous: previous, defaultKind: .inferred, allowUpgrade: { _ in true }
        )
        #expect(approved.map(\.kind) == [.confirmed])
    }

    @Test("same text under different previous kinds stays as separate entries")
    func splitKinds() {
        let previous = [
            MemoryItem(text: "在写论文", sources: ["2026-10-18"], kind: .stated),
            MemoryItem(text: "在写论文", sources: ["2026-10-19"], kind: .inferred),
        ]
        let result = MemoryItems.reconcileKinds(
            [MemoryItem(text: "在写论文", sources: ["2026-10-20"])], previous: previous, defaultKind: .inferred
        )
        #expect(result == [
            MemoryItem(text: "在写论文", sources: ["2026-10-18", "2026-10-20"], kind: .stated),
            MemoryItem(text: "在写论文", sources: ["2026-10-19", "2026-10-20"], kind: .inferred),
        ])
    }
}

@Suite("SchemaMigration")
struct SchemaMigrationTests {
    struct Fixture {
        let root: URL
        var migration: SchemaMigration { SchemaMigration(root: root) }

        init() throws {
            root = try tempDir()
        }

        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }

        func items(_ path: String) throws -> [MemoryItem] {
            MemoryItems.parse(Consolidator.memoryBlock.content(in: try read(path)) ?? "")
        }

        /// 旧版布局：summary.md + work/ 下多个专题 + goals/ 下一个带手写内容的文件。
        func seedLegacy(workItems: Int = 45) throws {
            try write("summary.md", """
            # 用户档案

            ## Amai 整理的长期记忆

            <!-- amai:memory:begin · 旧说明 -->
            ### 基本背景
            - 某大学研究生 <!-- src:2026-10-19 -->
            ### 工作与研究
            - 正在开发 Amai <!-- src:2026-10-19,2026-10-20 -->
            ### 习惯与偏好
            - 似乎习惯深夜工作 <!-- src:2026-10-20 -->
            ### 长期目标
            - 完成博士论文 <!-- src:2026-10-20 -->
            <!-- amai:memory:end -->
            """)
            // 超过 40 条：迁移不得截断。
            let many = (1...workItems).map { "- 进展 \($0)：调整采样频率与 dHash 阈值。 <!-- src:2026-10-2\($0 % 9) -->" }.joined(separator: "\n")
            try write("work/projects/amai.md", "# Amai 项目进展\n\n## 记录\n\n<!-- amai:memory:begin · x -->\n\(many)\n<!-- amai:memory:end -->\n")
            try write("work/research/maws-eval.md", "# MAWS-Eval\n\n## 记录\n\n<!-- amai:memory:begin · x -->\n- 搭建评测框架 <!-- src:2026-10-21 -->\n<!-- amai:memory:end -->\n")
            try write("goals/plans.md", "# 计划\n\n## 本周\n- 我自己写的：周五前交初稿\n\n## 记录\n\n<!-- amai:memory:begin · x -->\n- 准备组会报告 <!-- src:2026-10-22 -->\n<!-- amai:memory:end -->\n")
            try "".write(to: root.appendingPathComponent("work/.DS_Store"), atomically: true, encoding: .utf8)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("migrates every legacy entry with sources, maps summary sections and archives old files")
    func fullMigration() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let report = try f.migration.migrate()
        #expect(Set(report.migrated) == ["summary.md", "work/projects/amai.md", "work/research/maws-eval.md", "goals/plans.md"])
        #expect(report.itemsCarried == 4 + 45 + 1 + 1)

        let general = try f.read("general.md")
        #expect(general.hasPrefix("# 综合\n\n## Amai 整理的记忆\n\n<!-- amai:memory:begin"))
        #expect(general.contains("### 基本信息\n- 某大学研究生 <!-- src:2026-10-19 -->"))
        #expect(general.contains("### 工作概况\n- 正在开发 Amai <!-- src:2026-10-19,2026-10-20 -->"))
        #expect(general.contains("### 个人偏好\n- 似乎习惯深夜工作"))
        #expect(general.contains("### 目标概况\n- 完成博士论文"))
        // 骨架标题不会被当作用户内容搬运。
        #expect(!general.contains("迁移自"))
        #expect(try f.items("general.md").allSatisfy { $0.kind == .unknown })

        let work = try f.items("work.md")
        #expect(work.count == 46)
        #expect(work.filter { $0.section == "Amai 项目进展" }.count == 45)
        #expect(work.contains { $0.section == "MAWS-Eval" && $0.text == "搭建评测框架" && $0.sources == ["2026-10-21"] })

        let goals = try f.read("goals.md")
        #expect(goals.contains("### 计划\n- 准备组会报告 <!-- src:2026-10-22 -->"))
        #expect(goals.contains("## 迁移自 goals/plans.md"))
        #expect(goals.contains("- 我自己写的：周五前交初稿"))

        for old in ["summary.md", "work/projects/amai.md", "work/research/maws-eval.md", "goals/plans.md"] {
            #expect(!f.exists(old))
            #expect(f.exists(".archive/schema-v1/\(old)"))
        }
        // 只剩 .DS_Store 的旧目录被清理。
        #expect(!f.exists("work"))
        #expect(!f.exists("goals"))
    }

    @Test("running again is a no-op and leaves the targets byte-identical")
    func idempotent() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.migration.migrate()
        let before = try ["general.md", "work.md", "goals.md"].map(f.read)
        #expect(try f.migration.migrate() == SchemaMigration.Report())
        #expect(try ["general.md", "work.md", "goals.md"].map(f.read) == before)
    }

    @Test("resumes after a crash between writing the target and archiving the sources")
    func resume() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.migration.migrate()
        let migratedWork = try f.read("work.md")
        // 模拟崩溃：旧文件仍在原位（目标已写好）。
        try f.write("work/projects/amai.md", try f.read(".archive/schema-v1/work/projects/amai.md"))
        let report = try f.migration.migrate()
        #expect(report.migrated == ["work/projects/amai.md"])
        #expect(try f.read("work.md") == migratedWork)
        #expect(!f.exists("work/projects/amai.md"))
    }

    @Test("merges into an existing target without touching its user content or entries")
    func mergeExisting() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("work.md", """
        # 我的工作

        自己写的说明。

        ## Amai 整理的记忆

        <!-- amai:memory:begin · x -->
        ### Amai 项目进展
        - 进展 1：调整采样频率与 dHash 阈值。 <!-- src:2026-10-21 kind:observed -->
        <!-- amai:memory:end -->
        """)
        try f.seedLegacy(workItems: 2)
        try f.migration.migrate()
        let text = try f.read("work.md")
        #expect(text.hasPrefix("# 我的工作\n\n自己写的说明。\n"))
        let items = try f.items("work.md")
        // 依据不同（observed vs unknown）的同文条目分开保留，旧条目没有被提升。
        #expect(items.filter { $0.text.hasPrefix("进展 1") }.map(\.kind) == [.observed, .unknown])
        #expect(f.exists(".archive/schema-v1/pre-migration"))
    }

    @Test("a malformed legacy block stops migration and leaves every file in place")
    func malformed() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("work/projects/broken.md", "# 坏文件\n\n<!-- amai:memory:begin · x -->\n- 没有结束标记\n")
        #expect(throws: SchemaMigration.MigrationError.malformedBlock("work/projects/broken.md")) {
            try f.migration.migrate()
        }
        #expect(f.exists("work/projects/broken.md"))
        #expect(!f.exists("work.md"))
    }

    @Test("a legacy file with two system blocks is refused instead of half-migrated")
    func duplicateBlocks() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let block = "<!-- amai:memory:begin · x -->\n- 条目 <!-- src:2026-10-19 -->\n<!-- amai:memory:end -->\n"
        try f.write("work/projects/twice.md", "# 两个区块\n\n" + block + "\n" + block)
        #expect(throws: SchemaMigration.MigrationError.malformedBlock("work/projects/twice.md")) {
            try f.migration.migrate()
        }
        #expect(f.exists("work/projects/twice.md"))
        #expect(!f.exists("work.md"))
    }

    @Test("rollback restores the old layout and sets the new files aside without deleting them")
    func rollback() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        let original = try f.read("goals/plans.md")
        try f.migration.migrate()
        #expect(f.migration.status().targets.allSatisfy { $0.unchangedSinceMigration })

        let report = try f.migration.rollback()
        #expect(Set(report.restored) == ["summary.md", "work/projects/amai.md", "work/research/maws-eval.md", "goals/plans.md"])
        #expect(try f.read("goals/plans.md") == original)
        #expect(!f.exists("work.md") && !f.exists("general.md"))
        #expect(report.setAside.count == 3)
        for path in report.setAside { #expect(f.exists(path)) }
        #expect(throws: SchemaMigration.RollbackError.nothingToRollBack) { try f.migration.rollback() }
    }

    @Test("rollback refuses once a migrated file has been updated, and changes nothing")
    func rollbackAfterUpdate() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.migration.migrate()
        try (try f.read("work.md") + "\n用户后来补充的内容\n").write(to: f.root.appendingPathComponent("work.md"), atomically: true, encoding: .utf8)
        let before = try f.read("work.md")

        #expect(throws: SchemaMigration.RollbackError.targetModified(["work.md"])) { try f.migration.rollback() }
        #expect(try f.read("work.md") == before)
        #expect(f.exists("general.md"))
        #expect(!f.exists("summary.md"))
        #expect(f.migration.status().targets.first { $0.path == "work.md" }?.unchangedSinceMigration == false)
    }

    @Test("rollback refuses when an archived copy was altered")
    func rollbackArchiveTampered() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy()
        try f.migration.migrate()
        try f.write(".archive/schema-v1/summary.md", "改过的归档")
        #expect(throws: SchemaMigration.RollbackError.archiveModified("summary.md")) { try f.migration.rollback() }
        #expect(f.migration.status().archiveProblems == ["summary.md"])
        #expect(f.exists("general.md"))
    }

    @Test("a target that existed before migration is restored by rollback")
    func rollbackRestoresPreexisting() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let mine = "# Work\n\n我自己先建的文件。\n"
        try f.write("work.md", mine)
        try f.seedLegacy(workItems: 1)
        try f.migration.migrate()
        try f.migration.rollback()
        #expect(try f.read("work.md") == mine)
        #expect(f.exists("work/projects/amai.md"))
    }

    @Test("migrate after rollback works again and does not overwrite the earlier archive")
    func migrateAgain() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy(workItems: 1)
        try f.migration.migrate()
        try f.migration.rollback()
        try (try f.read("summary.md") + "\n## 新增\n回滚后手写的内容\n").write(to: f.root.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try f.migration.migrate()
        #expect(try f.read("general.md").contains("回滚后手写的内容"))
        #expect(f.exists(".archive/schema-v1/summary.md"))
        #expect(f.exists(".archive/schema-v1/summary.md.2"))
    }

    @Test("library reads documents and searches by category")
    func library() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.seedLegacy(workItems: 1)
        try f.migration.migrate()
        let index = MemoryIndex(root: f.root, database: try MemoryIndexDatabase.inMemory(), timeZone: utc)
        try await index.refresh()
        let library = MemoryLibrary(root: f.root, index: index, timeZone: utc)

        let goals = try #require(library.document(.goals))
        #expect(goals.systemItems == [MemoryItem(text: "准备组会报告", sources: ["2026-10-22"], section: "计划")])
        #expect(goals.userMarkdown.contains("周五前交初稿"))
        #expect(!goals.userMarkdown.contains("amai:memory"))
        #expect(library.document(.health) == nil)
        #expect(library.document(.daily) == nil)

        let hits = try await library.search("组会报告", in: [.goals])
        #expect(hits.map(\.category) == [.goals])
        #expect(try await library.search("组会报告", in: [.work]).isEmpty)
    }
}

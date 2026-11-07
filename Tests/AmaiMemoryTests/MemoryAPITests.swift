import AmaiCore
import Foundation
import Testing
@testable import AmaiMemory

@Suite("Memory API")
struct MemoryAPITests {
    /// 合成的记忆目录：goals / health 两个分区与一天的 daily。
    struct Fixture {
        let root: URL
        let utc = TimeZone(identifier: "UTC")!

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("amai-api-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("daily"), withIntermediateDirectories: true)
            try write("goals.md", """
            # 目标

            ## Amai 整理的记忆

            <!-- amai:memory:begin · x -->
            ### 计划
            - 年底前完成 Amai MVP <!-- src:2026-10-10,2026-10-12 kind:stated -->
            ### 决策
            - 同步服务改为自建 <!-- src:2026-10-18 kind:inferred -->
            <!-- amai:memory:end -->

            ## 我的备注

            MVP 先只做 macOS。
            """)
            try write("health.md", """
            # 健康

            <!-- amai:memory:begin · x -->
            ### 基本指标
            - 身高 175 cm，同步自体检报告 <!-- src:2026-10-01 kind:stated -->
            <!-- amai:memory:end -->
            """)
            try write("daily/2026-10-19.md", """
            # 2026-10-19

            ## 摘要

            <!-- amai:digest:begin · x -->
            活跃 1 小时 40 分，主要在写同步队列。
            <!-- amai:digest:end -->

            ## 时间线

            <!-- amai:timeline:begin · x -->
            - 09:00–10:30 实现同步队列 <!-- seg:A conf:0.88 src:t -->
              在 Xcode 中编写本地变更队列。
            - 10:30–10:40 [low confidence] Reading something <!-- seg:B conf:0.30 src:t -->
            - 11:00–11:20 〔低置信〕看邮件 <!-- seg:C conf:0.40 src:t -->
            <!-- amai:timeline:end -->

            ## 笔记

            下午去医院复查。
            """)
        }

        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        func api(_ categories: Set<MemoryCategory>) throws -> MemoryAPI {
            let index = MemoryIndex(root: root, database: try .inMemory(), timeZone: utc)
            return MemoryAPI(root: root, index: index, access: MemoryAccess(categories: categories), timeZone: utc)
        }

        /// 记忆目录下每个文件的内容与修改时间，用来确认 API 只读。
        func snapshot() throws -> [String: String] {
            var result: [String: String] = [:]
            for file in MemoryStore.markdownFiles(in: root) {
                let url = root.appendingPathComponent(file)
                let mtime = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                result[file] = try String(contentsOf: url, encoding: .utf8) + "|\(mtime?.timeIntervalSince1970 ?? 0)"
            }
            return result
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("search expands long-term hits into entries with sources and kind, and only covers allowed categories")
    func search() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let api = try f.api([.goals, .daily])
        let results = try await api.search("同步")
        let decision = try #require(results.first { $0.category == .goals })
        #expect(decision.content == "同步服务改为自建")
        #expect(decision.section == "决策")
        #expect(decision.sources == ["2026-10-18"] && decision.date == "2026-10-18")
        #expect(decision.kind == .inferred)
        #expect(results.contains { $0.category == .daily && $0.date == "2026-10-19" })
        // health.md 也含"同步"，但没有授权。
        #expect(!results.contains { $0.category == .health })

        let limited = try await api.search("同步", limit: 1)
        #expect(limited.count == 1)
        #expect(try await f.api([]).search("同步").isEmpty)
    }

    @Test("get_memory groups entries by section, matches topics in any language and keeps user notes")
    func memory() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let api = try f.api([.goals])
        let all = try #require(try api.memory(.goals))
        #expect(all.topics == ["计划", "决策"])
        #expect(all.sections.map(\.name) == ["计划", "决策"])
        #expect(all.sections[0].entries[0].sources == ["2026-10-10", "2026-10-12"])
        #expect(all.sections[0].entries[0].kind == .stated)
        #expect(all.userNotes.contains("MVP 先只做 macOS。"))
        #expect(!all.userNotes.contains("amai:memory"))

        let plans = try #require(try api.memory(.goals, topic: "Plans"))
        #expect(plans.sections.map(\.name) == ["计划"])
        let notes = try #require(try api.memory(.goals, topic: "备注"))
        #expect(notes.sections.isEmpty && notes.userNotes.contains("MVP 先只做 macOS。"))

        #expect(throws: MemoryAPIError.notAllowed(.health)) { try api.memory(.health) }
        #expect(throws: MemoryAPIError.notADocument(.daily)) { try api.memory(.daily) }
        // 已授权但文件还不存在。
        #expect(try f.api([.work]).memory(.work) == nil)
    }

    @Test("get_timeline parses entries, summaries and low-confidence tags in any language")
    func timeline() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let api = try f.api([.daily])
        let day = try api.timeline(on: "2026-10-19")
        #expect(day.exists)
        #expect(day.entries.count == 3)
        #expect(day.entries[0] == TimelineEntry(start: "09:00", end: "10:30", title: "实现同步队列", summary: "在 Xcode 中编写本地变更队列。", confidence: 0.88, lowConfidence: false))
        #expect(day.entries[1].title == "Reading something" && day.entries[1].lowConfidence)
        #expect(day.entries[2].title == "看邮件" && day.entries[2].lowConfidence && day.entries[2].confidence == 0.4)
        #expect(day.summary == "活跃 1 小时 40 分，主要在写同步队列。")
        #expect(day.userNotes.contains("下午去医院复查。"))

        let missing = try api.timeline(on: "2026-10-20")
        #expect(!missing.exists && missing.entries.isEmpty)
        #expect(throws: MemoryAPIError.invalidDate("2026-13-40")) { try api.timeline(on: "2026-13-40") }
        #expect(throws: MemoryAPIError.invalidDate("../general")) { try api.timeline(on: "../general") }
        #expect(throws: MemoryAPIError.notAllowed(.daily)) { try f.api([.goals]).timeline(on: "2026-10-19") }
    }

    @Test("reading through the API never modifies memory files")
    func readOnly() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let before = try f.snapshot()
        let api = try f.api(Set(MemoryCategory.allCases))
        _ = try await api.search("同步")
        _ = try api.memory(.goals, topic: "计划")
        _ = try api.timeline(on: "2026-10-19")
        _ = try api.timeline(on: "2026-10-21")
        #expect(try f.snapshot() == before)
    }

    @Test("mcp configuration is off by default, opens general/work/goals and ignores unknown categories")
    func configuration() throws {
        #expect(MCPConfiguration.default.enabled == false)
        #expect(MCPConfiguration.default.access.categories == [.general, .work, .goals])
        let empty = try JSONDecoder().decode(MCPConfiguration.self, from: Data("{}".utf8))
        #expect(empty == .default)
        let custom = try JSONDecoder().decode(MCPConfiguration.self, from: Data(#"{"enabled":true,"categories":["daily","helth","finance"]}"#.utf8))
        #expect(custom.enabled && custom.categories == [.daily, .finance])
    }
}

import AmaiCore
import Foundation
import Testing
@testable import AmaiMemory

/// 根据系统提示词区分三种任务，返回脚本化输出。
final class ScriptedModel: MemoryLanguageModel, @unchecked Sendable {
    let identifier = "scripted:test"
    private let lock = NSLock()
    private(set) var schemaNames: [String] = []
    var digest = #"{"summary":"主要在开发 Amai 的抽取层。","highlights":["完成活动切分","修正切分过碎"]}"#
    var topics = #"{"updates":[]}"#
    var general = #"{"items":[]}"#
    private(set) var lastTopicsPrompt = ""
    private(set) var lastGeneralPrompt = ""
    private(set) var calls = 0

    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
        lock.withLock {
            calls += 1
            if let schema { schemaNames.append(schema.name) }
            if system == Prompts.digestSystem { return digest }
            if system == Prompts.topicsSystem { lastTopicsPrompt = user; return topics }
            lastGeneralPrompt = user
            return general
        }
    }
}

@Suite("MemoryItems")
struct MemoryItemsTests {
    @Test("render and parse round-trip, with sections")
    func roundTrip() {
        let items = [
            MemoryItem(text: "常在深夜写代码", sources: ["2026-10-20"], section: "个人偏好"),
            MemoryItem(text: "开发 Amai", sources: ["2026-10-19", "2026-10-20"], section: "工作概况", kind: .inferred),
        ]
        let body = MemoryItems.render(items, sections: MemorySchema.generalSections)
        #expect(body.contains("### 工作概况\n- 开发 Amai <!-- src:2026-10-19,2026-10-20 kind:inferred -->"))
        #expect(body.contains("- 常在深夜写代码 <!-- src:2026-10-20 -->"))
        #expect(MemoryItems.parse(body) == items)
    }

    @Test("sanitize dedupes, fills missing sources, drops bad dates and secrets")
    func sanitize() {
        let raw = [
            MemoryItem(text: "完成 M2 抽取层", sources: ["2026-10-19"]),
            MemoryItem(text: "完成 M2 抽取层。", sources: ["2026-10-20", "昨天"]),
            MemoryItem(text: "密钥 sk-proj-abcdefghijklmnopqrstuvwxyz0123", sources: []),
            MemoryItem(text: "  ", sources: []),
        ]
        let items = MemoryItems.sanitize(raw, fallbackSource: "2026-10-20", limit: 10)
        #expect(items.count == 2)
        #expect(items[0].sources == ["2026-10-19", "2026-10-20"])
        #expect(items[1].sources == ["2026-10-20"])
        #expect(!items[1].text.contains("sk-proj"))
    }
}

@Suite("SystemBlock")
struct SystemBlockTests {
    let block = SystemBlock(name: "digest", note: "n")

    @Test("inserts before an anchor heading when missing, then replaces in place")
    func insertBefore() throws {
        let daily = "# 2026-10-19\n\n## 时间线\n\n<!-- amai:timeline:begin · x -->\n- a\n<!-- amai:timeline:end -->\n"
        let once = try block.splice(body: "摘要", into: daily, newFileTitle: "x", heading: "## 摘要", insertBeforeHeading: "## 时间线")
        #expect(once.hasPrefix("# 2026-10-19\n\n## 摘要\n\n<!-- amai:digest:begin · n -->\n摘要\n<!-- amai:digest:end -->\n\n## 时间线"))
        let twice = try block.splice(body: "新摘要", into: once, newFileTitle: "x", heading: "## 摘要", insertBeforeHeading: "## 时间线")
        #expect(twice.contains("新摘要") && !twice.contains("\n摘要\n"))
        #expect(block.content(in: twice) == "新摘要")
        #expect(!block.removing(from: twice).contains("新摘要"))
    }
}

@Suite("Consolidator")
struct ConsolidatorTests {
    struct Fixture {
        let root: URL
        let support: URL
        let store: MemoryStore
        let source = FakeSource()
        let model = ScriptedModel()
        let consolidator: Consolidator
        let snapshots: SnapshotStore
        /// 2026-10-19
        let day = Date(timeIntervalSince1970: 1_792_368_000)

        init(now: Date = Date(timeIntervalSince1970: 1_792_368_000 + 86_400 + 5 * 3600)) throws {
            root = try tempDir()
            support = try tempDir()
            store = try MemoryStore(root: root, timeZone: utc)
            snapshots = SnapshotStore(root: support.appendingPathComponent("snapshots"))
            consolidator = Consolidator(
                store: store, source: source, model: model, snapshots: snapshots,
                stateURL: support.appendingPathComponent("consolidation.json"),
                clock: FixedClock(now), timeZone: utc
            )
        }

        func seedDay() async throws {
            let segs = [
                segment(0, 3600, "编辑采集代码", category: .work),
                segment(3600, 5400, "查阅论文", category: .research),
                segment(5400, 6000, "离开", category: .idle, provider: "rule:idle"),
            ]
            source.set(segs, on: day)
            try await store.writeDailyTimeline(day: day, segments: segs)
        }

        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: support)
        }
    }

    @Test("daily digest goes above the timeline with code-computed stats; user notes survive")
    func digest() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        let path = "daily/2026-10-19.md"
        try (try f.read(path) + "\n## 我的笔记\n今天很累\n").write(to: f.root.appendingPathComponent(path), atomically: true, encoding: .utf8)

        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.digestWritten)
        let text = try f.read(path)
        let digest = try #require(Consolidator.digestBlock.content(in: text))
        #expect(digest.hasPrefix("活跃 1 小时 30 分（工作 1 小时 0 分 · 研究 30 分），03:00–04:30。"))
        #expect(digest.contains("- 完成活动切分"))
        #expect(text.firstRange(of: "## 摘要")!.lowerBound < text.firstRange(of: "## 时间线")!.lowerBound)
        #expect(text.contains("## 我的笔记\n今天很累"))
        #expect(await f.consolidator.status.lastDailyDay == "2026-10-19")
        // 每个任务都带上自己的输出 Schema；改动日志记录所用模型。
        #expect(f.model.schemaNames == ["daily_digest", "work_topics"])
        let log = try String(contentsOf: f.snapshots.root.appendingPathComponent("changes.jsonl"), encoding: .utf8)
        #expect(log.contains(#""model":"scripted:test""#))
    }

    @Test("output schemas are valid JSON and strict")
    func schemas() throws {
        for schema in [Schemas.digest, Schemas.topics, Schemas.general] {
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(schema.json.utf8)) as? [String: Any])
            #expect(obj["additionalProperties"] as? Bool == false)
            #expect(!(obj["required"] as? [String] ?? []).isEmpty)
        }
    }

    @Test("the model can be swapped at runtime")
    func swapModel() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        #expect(await f.consolidator.modelIdentifier == "scripted:test")
        let other = ScriptedModel()
        await f.consolidator.setModel(other)
        try await f.seedDay()
        _ = try await f.consolidator.consolidateDay(f.day)
        #expect(other.calls == 2 && f.model.calls == 0)
    }

    @Test("work.md groups by project; other projects, kinds and user notes survive; snapshots before rewrite")
    func topics() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        f.model.topics = """
        {"updates":[
          {"project":"Amai","items":[{"text":"完成抽取层 MVP","sources":["2026-10-19"]},{"text":"修正切分过碎"}]},
          {"project":"  ","items":[{"text":"y"}]}
        ]}
        """
        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.projectsUpdated == ["Amai"])
        #expect(report.projectsRejected.count == 1)
        let work = try f.read("work.md")
        #expect(work.hasPrefix("# Work\n\n## Amai 整理的记忆\n\n<!-- amai:memory:begin"))
        #expect(work.contains("### Amai\n- 完成抽取层 MVP <!-- src:2026-10-19 kind:inferred -->"))
        #expect(work.contains("- 修正切分过碎 <!-- src:2026-10-19 kind:inferred -->"))

        // 用户在区块外加笔记、区块内另有一个手动依据的项目；第二天只更新 Amai。
        let block = try #require(Consolidator.memoryBlock.content(in: work))
        let seeded = work.replacingOccurrences(of: block, with: block + "\n\n### 论文\n- 投稿 CVPR <!-- src:2026-10-18 kind:stated -->")
        try (seeded + "\n## 我的想法\n下周开始做 M4\n").write(to: f.root.appendingPathComponent("work.md"), atomically: true, encoding: .utf8)
        let day2 = f.day.addingTimeInterval(86_400)
        f.source.set([segment(86_400, 90_000, "整理记忆")], on: day2)
        try await f.store.writeDailyTimeline(day: day2, segments: [segment(86_400, 90_000, "整理记忆")])
        f.model.topics = """
        {"updates":[{"project":"Amai","items":[
          {"text":"完成抽取层 MVP","sources":["2026-10-20"],"kind":"stated"},
          {"text":"完成 Markdown 记忆写入","sources":["2026-10-20"]}]}]}
        """
        _ = try await f.consolidator.consolidateDay(day2)
        #expect(f.model.lastTopicsPrompt.contains("项目「Amai」"))
        #expect(f.model.lastTopicsPrompt.contains("项目「论文」"))
        let updated = try f.read("work.md")
        // 模型自称 stated 不会被采纳：沿用原来的 inferred，来源取并集。
        #expect(updated.contains("- 完成抽取层 MVP <!-- src:2026-10-19,2026-10-20 kind:inferred -->"))
        #expect(updated.contains("- 完成 Markdown 记忆写入 <!-- src:2026-10-20 kind:inferred -->"))
        #expect(updated.contains("### 论文\n- 投稿 CVPR <!-- src:2026-10-18 kind:stated -->"))
        #expect(updated.contains("## 我的想法\n下周开始做 M4"))
        #expect(f.snapshots.snapshots().contains { $0.lastPathComponent.hasSuffix("work.md") })
    }

    @Test("a rewrite that drops most of a project's entries is rejected")
    func lossGuard() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        let six = (1...6).map { #"{"text":"条目 \#($0)","sources":["2026-10-19"]}"# }.joined(separator: ",")
        f.model.topics = #"{"updates":[{"project":"研究","items":[\#(six)]}]}"#
        _ = try await f.consolidator.consolidateDay(f.day)

        f.model.topics = #"{"updates":[{"project":"研究","items":[{"text":"只剩一条"}]}]}"#
        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.projectsRejected == ["研究"])
        #expect(try f.read("work.md").contains("条目 6"))
    }

    @Test("unparsable model output fails without marking the day done")
    func unparsable() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        f.model.digest = "抱歉，我做不到"
        await #expect(throws: Consolidator.ConsolidationError.unparsableModelOutput("digest")) {
            try await f.consolidator.consolidateDay(f.day)
        }
        #expect(await f.consolidator.status.lastDailyDay == nil)
        #expect(await f.consolidator.status.lastError != nil)
    }

    @Test("general groups by section, keeps user-written text and item kinds, and passes them to the model")
    func general() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        _ = try await f.consolidator.consolidateDay(f.day)
        try """
        # General

        ## 基本信息
        某大学研究生

        ## Amai 整理的记忆

        <!-- amai:memory:begin · x -->
        ### 个人偏好
        - 喜欢用 Swift <!-- src:2026-10-18 kind:stated -->
        - 似乎习惯深夜工作 <!-- src:2026-10-18 -->
        <!-- amai:memory:end -->
        """.write(to: f.root.appendingPathComponent("general.md"), atomically: true, encoding: .utf8)
        f.model.general = """
        {"items":[
          {"section":"工作概况","text":"正在开发 Ambient Personal AI 项目 Amai","sources":["2026-10-19"]},
          {"section":"个人偏好","text":"喜欢用 Swift","sources":["2026-10-19"]},
          {"section":"个人偏好","text":"似乎习惯深夜工作","sources":["2026-10-18"],"kind":"confirmed"},
          {"section":"奇怪的小节","text":"经常查阅论文","sources":["2026-10-19"]}]}
        """
        #expect(try await f.consolidator.updateGeneral())
        #expect(f.model.lastGeneralPrompt.contains("某大学研究生"))
        #expect(f.model.lastGeneralPrompt.contains("主要在开发 Amai 的抽取层"))
        let text = try f.read("general.md")
        #expect(text.hasPrefix("# General\n\n## 基本信息\n某大学研究生\n"))
        #expect(text.contains("### 工作概况\n- 正在开发 Ambient Personal AI 项目 Amai <!-- src:2026-10-19 kind:inferred -->"))
        #expect(text.contains("- 喜欢用 Swift <!-- src:2026-10-18,2026-10-19 kind:stated -->"))
        // unknown 不会被模型升级为 confirmed。
        #expect(text.contains("- 似乎习惯深夜工作 <!-- src:2026-10-18 -->"))
        #expect(text.contains("### 其他\n- 经常查阅论文"))
        #expect(await f.consolidator.status.lastGeneralAt != nil)
    }

    @Test("state written before Schema v1 keeps its last summary time")
    func legacyState() async throws {
        let support = try tempDir()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = support.appendingPathComponent("consolidation.json")
        try #"{"lastDailyDay":"2026-10-18","lastSummaryAt":"2026-10-19T00:00:00Z"}"#.write(to: stateURL, atomically: true, encoding: .utf8)
        let c = Consolidator(
            store: try MemoryStore(root: root, timeZone: utc), source: FakeSource(), model: ScriptedModel(),
            snapshots: SnapshotStore(root: support), stateURL: stateURL, timeZone: utc
        )
        #expect(await c.status.lastGeneralAt == Date(timeIntervalSince1970: 1_792_368_000))
        #expect(await c.status.lastDailyDay == "2026-10-18")
    }

    @Test("tick consolidates finished days once, waits until 4am, and is idempotent")
    func tick() async throws {
        // 10-20 03:00：昨天（10-19）还没到整理时间。
        let early = try Fixture(now: Date(timeIntervalSince1970: 1_792_368_000 + 86_400 + 3 * 3600))
        defer { early.cleanup() }
        try await early.seedDay()
        await early.consolidator.tick()
        #expect(early.model.calls == 0)

        // 10-20 05:00：整理 10-19；再次 tick 不重复。
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        await f.consolidator.tick()
        #expect(await f.consolidator.status.lastDailyDay == "2026-10-19")
        let calls = f.model.calls
        await f.consolidator.tick()
        #expect(f.model.calls == calls)
    }

    @Test("consolidating today does not mark it done")
    func today() async throws {
        let now = Date(timeIntervalSince1970: 1_792_368_000 + 15 * 3600)
        let f = try Fixture(now: now)
        defer { f.cleanup() }
        try await f.seedDay()
        _ = try await f.consolidator.consolidateDay(f.day)
        #expect(await f.consolidator.status.lastDailyDay == nil)
    }

    @Test("project names are cleaned before becoming headings")
    func projectNames() {
        #expect(Consolidator.projectName("## Amai\n计划") == "Amai 计划")
        #expect(Consolidator.projectName("<!-- x -->") == "x")
        #expect(Consolidator.projectName("   ") == nil)
    }
}

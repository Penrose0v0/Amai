import AmaiCore
import Foundation
import Testing
@testable import AmaiMemory

/// 根据系统提示词区分三种任务，返回脚本化输出。
final class ScriptedModel: MemoryLanguageModel, @unchecked Sendable {
    private let lock = NSLock()
    var digest = #"{"summary":"主要在开发 Amai 的抽取层。","highlights":["完成活动切分","修正切分过碎"]}"#
    var topics = #"{"updates":[]}"#
    var summary = #"{"items":[]}"#
    private(set) var lastTopicsPrompt = ""
    private(set) var lastSummaryPrompt = ""
    private(set) var calls = 0

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        lock.withLock {
            calls += 1
            if system == Prompts.digestSystem { return digest }
            if system == Prompts.topicsSystem { lastTopicsPrompt = user; return topics }
            lastSummaryPrompt = user
            return summary
        }
    }
}

@Suite("MemoryItems")
struct MemoryItemsTests {
    @Test("render and parse round-trip, with sections")
    func roundTrip() {
        let items = [
            MemoryItem(text: "开发 Amai", sources: ["2026-10-19", "2026-10-20"], section: "工作与研究"),
            MemoryItem(text: "常在深夜写代码", sources: ["2026-10-20"], section: "习惯与偏好"),
        ]
        let body = MemoryItems.render(items, sections: Consolidator.summarySections)
        #expect(body.contains("### 工作与研究\n- 开发 Amai <!-- src:2026-10-19,2026-10-20 -->"))
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
    }

    @Test("creates and updates work topics with sources; rejects bad paths; snapshots before rewrite")
    func topics() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        f.model.topics = """
        {"updates":[
          {"file":"work/projects/amai.md","title":"Amai","items":[{"text":"完成抽取层 MVP","sources":["2026-10-19"]},{"text":"修正切分过碎"}]},
          {"file":"../escape.md","title":"x","items":[{"text":"y"}]},
          {"file":"goals/plans.md","title":"x","items":[{"text":"y"}]}
        ]}
        """
        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.topicsUpdated == ["work/projects/amai.md"])
        #expect(report.topicsRejected.count == 2)
        let amai = try f.read("work/projects/amai.md")
        #expect(amai.hasPrefix("# Amai\n\n## 记录\n\n<!-- amai:memory:begin"))
        #expect(amai.contains("- 修正切分过碎 <!-- src:2026-10-19 -->"))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("goals/plans.md").path))

        // 用户在区块外加笔记；第二天模型合并旧条目并新增一条。
        try (amai + "\n## 我的想法\n下周开始做 M4\n").write(to: f.root.appendingPathComponent("work/projects/amai.md"), atomically: true, encoding: .utf8)
        let day2 = f.day.addingTimeInterval(86_400)
        f.source.set([segment(86_400, 90_000, "整理记忆")], on: day2)
        try await f.store.writeDailyTimeline(day: day2, segments: [segment(86_400, 90_000, "整理记忆")])
        f.model.topics = """
        {"updates":[{"file":"work/projects/amai.md","items":[
          {"text":"完成抽取层 MVP 并修正切分过碎","sources":["2026-10-19"]},
          {"text":"完成 Markdown 记忆写入","sources":["2026-10-20"]}]}]}
        """
        _ = try await f.consolidator.consolidateDay(day2)
        #expect(f.model.lastTopicsPrompt.contains("文件 work/projects/amai.md（Amai）"))
        #expect(f.model.lastTopicsPrompt.contains("完成抽取层 MVP"))
        let updated = try f.read("work/projects/amai.md")
        #expect(updated.contains("完成 Markdown 记忆写入 <!-- src:2026-10-20 -->"))
        #expect(updated.contains("## 我的想法\n下周开始做 M4"))
        #expect(f.snapshots.snapshots().contains { $0.lastPathComponent.hasSuffix("work__projects__amai.md") })
    }

    @Test("a rewrite that drops most existing entries is rejected")
    func lossGuard() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        let six = (1...6).map { #"{"text":"条目 \#($0)","sources":["2026-10-19"]}"# }.joined(separator: ",")
        f.model.topics = #"{"updates":[{"file":"work/research.md","title":"研究","items":[\#(six)]}]}"#
        _ = try await f.consolidator.consolidateDay(f.day)

        f.model.topics = #"{"updates":[{"file":"work/research.md","items":[{"text":"只剩一条"}]}]}"#
        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.topicsRejected == ["work/research.md"])
        #expect(try f.read("work/research.md").contains("条目 6"))
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

    @Test("summary groups by section, keeps user-written text, and passes it to the model")
    func summary() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        _ = try await f.consolidator.consolidateDay(f.day)
        try "# 用户档案\n\n## 基本背景\n某大学研究生\n".write(to: f.root.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        f.model.summary = """
        {"items":[
          {"section":"工作与研究","text":"正在开发 Ambient Personal AI 项目 Amai","sources":["2026-10-19"]},
          {"section":"奇怪的小节","text":"似乎习惯深夜工作","sources":["2026-10-19"]}]}
        """
        #expect(try await f.consolidator.updateSummary())
        #expect(f.model.lastSummaryPrompt.contains("某大学研究生"))
        #expect(f.model.lastSummaryPrompt.contains("主要在开发 Amai 的抽取层"))
        let text = try f.read("summary.md")
        #expect(text.hasPrefix("# 用户档案\n\n## 基本背景\n某大学研究生\n"))
        #expect(text.contains("### 工作与研究\n- 正在开发 Ambient Personal AI 项目 Amai <!-- src:2026-10-19 -->"))
        #expect(text.contains("### 其他\n- 似乎习惯深夜工作"))
        #expect(await f.consolidator.status.lastSummaryAt != nil)
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

    @Test("topic paths are restricted to work/*.md")
    func paths() {
        #expect(Consolidator.validTopicPath("work/projects/amai.md") == "work/projects/amai.md")
        #expect(Consolidator.validTopicPath("/work/research.md") == "work/research.md")
        #expect(Consolidator.validTopicPath("work/../summary.md") == nil)
        #expect(Consolidator.validTopicPath("work/.hidden.md") == nil)
        #expect(Consolidator.validTopicPath("summary.md") == nil)
        #expect(Consolidator.validTopicPath("work/notes.txt") == nil)
    }
}

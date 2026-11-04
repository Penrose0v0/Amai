import AmaiCore
import Foundation
import Testing
@testable import AmaiMemory

/// 按系统提示词区分任务（日终摘要 / 各分区整理），返回脚本化输出。
final class ScriptedModel: MemoryLanguageModel, @unchecked Sendable {
    let identifier = "scripted:test"
    private let lock = NSLock()
    private(set) var schemaNames: [String] = []
    var digest = Responses.digest(routes: ["work"])
    /// 分区 → 操作 JSON；未设置的分区返回空操作。
    var operations: [MemoryCategory: String] = [:]
    /// 分区 → 第几次调用时抛错（用于失败重试测试）。
    var failing: Set<MemoryCategory> = []
    private(set) var prompts: [MemoryCategory: String] = [:]
    private(set) var lastDigestPrompt = ""
    private(set) var systems: [String] = []
    private(set) var calls = 0
    private(set) var categoryCalls: [MemoryCategory] = []

    struct Failure: Error {}

    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
        try lock.withLock {
            calls += 1
            systems.append(system)
            if let schema { schemaNames.append(schema.name) }
            if MemoryLanguage.allCases.contains(where: { system == Prompts.digestSystem($0) }) { lastDigestPrompt = user; return digest }
            guard let category = MemoryCategory.documents.first(where: { system.contains("（\($0.rawValue).md）") || system.contains("(\($0.rawValue).md)") }) else {
                return "{}"
            }
            categoryCalls.append(category)
            prompts[category] = user
            if failing.contains(category) { throw Failure() }
            return operations[category] ?? #"{"operations":[]}"#
        }
    }
}

enum Responses {
    static func digest(routes: [String], summary: String = "主要在开发 Amai 的抽取层。") -> String {
        let r = ["work", "goals", "health", "finance"].map { "\"\($0)\":{\"update\":\(routes.contains($0)),\"reason\":\"\"}" }.joined(separator: ",")
        return #"{"summary":"\#(summary)","highlights":["完成活动切分","修正切分过碎"],"routes":{\#(r)}}"#
    }

    /// 一个操作的 JSON（只写用到的字段，其余由解码补空）。
    static func op(_ fields: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func ops(_ list: [[String: Any]]) -> String {
        #"{"operations":["# + list.map(op).joined(separator: ",") + "]}"
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

        /// 一天的活动：Xcode 中编辑采集代码（带采集元数据）、查阅论文、离开。可附加用户笔记。
        func seedDay(notes: String? = nil, on date: Date? = nil, offset: TimeInterval = 0) async throws {
            let d = date ?? day
            let xcode = source.addFact(app: "Xcode", at: offset + 60)
            let segs = [
                segment(offset, offset + 3600, "编辑采集代码", summary: "在 Xcode 中修改 ScreenFrameSource.swift", category: .work, observations: [xcode]),
                segment(offset + 3600, offset + 5400, "查阅论文", category: .research),
                segment(offset + 5400, offset + 6000, "离开", category: .idle, provider: "rule:idle"),
            ]
            source.set(segs, on: d)
            try await store.writeDailyTimeline(day: d, segments: segs)
            if let notes {
                let path = MemoryDirectory.dailyFile(for: d, timeZone: utc)
                try (try read(path) + "\n## 我的笔记\n\(notes)\n").write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
        }

        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        func items(_ category: MemoryCategory) throws -> [MemoryItem] {
            MemoryItems.parse(Consolidator.memoryBlock.content(in: try read(category.file!)) ?? "")
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
        try await f.seedDay(notes: "今天很累")
        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.digestWritten)
        let text = try f.read("daily/2026-10-19.md")
        let digest = try #require(Consolidator.digestBlock.content(in: text))
        #expect(digest.hasPrefix("活跃 1 小时 30 分（工作 1 小时 0 分 · 研究 30 分），03:00–04:30。"))
        #expect(digest.contains("- 完成活动切分"))
        #expect(text.firstRange(of: "## 摘要")!.lowerBound < text.firstRange(of: "## 时间线")!.lowerBound)
        #expect(text.contains("## 我的笔记\n今天很累"))
        #expect(await f.consolidator.status.lastDailyDay == "2026-10-19")
        // 依据清单区分用户陈述、采集元数据与推断，且不包含屏幕文字。
        #expect(f.model.lastDigestPrompt.contains("[S1] 2026-10-19 今天很累"))
        #expect(f.model.lastDigestPrompt.contains("[F1] 2026-10-19 03:00–04:00 前台应用：Xcode"))
        #expect(f.model.lastDigestPrompt.contains("[I1] 2026-10-19 03:00–04:00 编辑采集代码：在 Xcode 中修改 ScreenFrameSource.swift"))
        #expect(!f.model.lastDigestPrompt.contains("屏幕文字不应进入记忆"))
        #expect(f.model.schemaNames == ["daily_digest", "memory_operations"])
        let log = try String(contentsOf: f.snapshots.root.appendingPathComponent("changes.jsonl"), encoding: .utf8)
        #expect(log.contains(#""model":"scripted:test""#))
    }

    @Test("output schemas are valid JSON and strict")
    func schemas() throws {
        for schema in [Schemas.digest, Schemas.operations] {
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(schema.json.utf8)) as? [String: Any])
            #expect(obj["additionalProperties"] as? Bool == false)
            #expect(!(obj["required"] as? [String] ?? []).isEmpty)
        }
    }

    @Test("only routed categories are consolidated")
    func routing() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay(notes: "下周开始准备求职面试")
        f.model.digest = Responses.digest(routes: ["goals"])
        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.routed == [.goals])
        #expect(!report.routingFallback)
        #expect(f.model.categoryCalls == [.goals])
        #expect(report.modelCalls == 2)
    }

    @Test("missing or malformed routes fall back to every category; Health/Finance without user statements skip the model")
    func routingFallback() async throws {
        for digest in [
            #"{"summary":"x","highlights":[]}"#,
            #"{"summary":"x","highlights":[],"routes":{"work":{"update":true},"goals":{"update":"maybe"},"health":{"update":false},"finance":{"update":false}}}"#,
            #"{"summary":"x","highlights":[],"routes":{"work":{"update":false}}}"#,
        ] {
            let f = try Fixture()
            defer { f.cleanup() }
            try await f.seedDay()
            f.model.digest = digest
            let report = try await f.consolidator.consolidateDay(f.day)
            #expect(report.routingFallback)
            #expect(report.routed == [.work, .goals, .health, .finance])
            #expect(report.skipped == [.health, .finance])
            #expect(f.model.categoryCalls == [.work, .goals])
        }
    }

    @Test("a missed route is not recovered by keyword rules (measured by the evaluation instead)")
    func missedRoute() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay(notes: "昨晚只睡了四个小时")
        f.model.digest = Responses.digest(routes: [])
        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.routed.isEmpty)
        #expect(f.model.categoryCalls.isEmpty)
    }

    @Test("kind comes from the cited evidence, never from the model; unsupported entries are dropped")
    func kinds() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay(notes: "决定把 Amai 的记忆层改成按分区维护")
        f.model.operations[.work] = Responses.ops([
            ["op": "add", "project": "new:Amai", "text": "决定把 Amai 的记忆层改成按分区维护", "evidence": ["S1"]],
            ["op": "add", "project": "new:Amai", "text": "使用 Xcode 约一小时", "evidence": ["F1"]],
            ["op": "add", "project": "new:Amai", "text": "在 Xcode 中开发采集代码", "evidence": ["F1"]],
            ["op": "add", "project": "new:Amai", "text": "修改了 ScreenFrameSource.swift", "evidence": ["I1"]],
            ["op": "add", "project": "new:Amai", "text": "Amai 已经有一百个用户", "evidence": ["S1"]],
            ["op": "add", "project": "new:Amai", "text": "在 Safari 中查资料", "evidence": ["F1"]],
            ["op": "add", "project": "new:Amai", "text": "没有依据的内容", "evidence": []],
        ])
        let report = try await f.consolidator.consolidateDay(f.day)
        let items = try f.items(.work)
        // 只说"用了 Xcode"才是观察；说了在做什么就超出了 F 能证明的范围。
        #expect(items.map(\.kind) == [.stated, .observed, .inferred, .inferred, .inferred])
        #expect(items.allSatisfy { $0.sources == ["2026-10-19"] && $0.section == "Amai" })
        // 转述超出原话的内容被降为推断；F 依据与内容无关、没有依据的条目被拒绝。
        #expect(items[4].text == "Amai 已经有一百个用户")
        #expect(report.rejected.count == 2)
        let work = try f.read("work.md")
        #expect(work.contains(#"### Amai <!-- project:p-"#))
    }

    @Test("Work projects keep stable IDs: only an exact name or explicit alias joins an existing project")
    func projects() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("work.md", """
        # Work

        ## Amai 整理的记忆

        <!-- amai:memory:begin · x -->
        ### Amai 项目进展
        - 完成抽取层 MVP <!-- src:2026-10-18 -->
        ### MAWS-Eval
        - 搭建评测框架 <!-- src:2026-10-18 -->
        <!-- amai:memory:end -->
        """)
        try await f.seedDay()
        f.model.operations[.work] = Responses.ops([
            ["op": "add", "project": "new:amai 项目进展", "text": "编辑采集代码", "evidence": ["I1"]],
            ["op": "add", "project": "new:maws eval", "text": "查阅论文", "evidence": ["I2"]],
            // 名字相近但不同的项目不合并：前缀相同也新建。
            ["op": "add", "project": "new:MAWS-Eval 2", "text": "查阅论文并记录", "evidence": ["I2"]],
        ])
        try await f.consolidator.consolidateDay(f.day)
        #expect(try f.items(.work).map(\.section) == ["Amai 项目进展", "Amai 项目进展", "MAWS-Eval", "MAWS-Eval", "MAWS-Eval 2"])
        let prompt = try #require(f.model.prompts[.work])
        let ids = MemoryItems.sections(Consolidator.memoryBlock.content(in: try f.read("work.md"))!)
        let amaiID = try #require(ids.first { $0.name == "Amai 项目进展" }?.meta["project"])
        #expect(prompt.contains("- \(amaiID) Amai 项目进展"))

        // 改名：ID 不变，旧名成为别名；之后用旧名新增仍归入同一项目。
        let day2 = f.day.addingTimeInterval(86_400)
        try await f.seedDay(on: day2, offset: 86_400)
        f.model.operations[.work] = Responses.ops([
            ["op": "rename_project", "project": amaiID, "text": "Amai"],
            ["op": "add", "project": "new:Amai 项目进展", "text": "编辑采集代码并提交", "evidence": ["I1"]],
            ["op": "add", "project": amaiID, "text": "编辑采集代码", "evidence": ["I1"]],
        ])
        try await f.consolidator.consolidateDay(day2)
        let sections = MemoryItems.sections(Consolidator.memoryBlock.content(in: try f.read("work.md"))!)
        let amai = try #require(sections.first { $0.name == "Amai" })
        #expect(amai.meta["project"] == amaiID)
        #expect(amai.meta["aka"] == "Amai 项目进展")
        #expect(try f.items(.work).filter { $0.section == "Amai" }.count == 3)
        // 同一条重复新增只合并来源。
        #expect(try f.items(.work).first { $0.text == "编辑采集代码" }?.sources == ["2026-10-19", "2026-10-20"])
    }

    @Test("weaker evidence cannot overwrite or retire a stronger fact; changes are kept in history")
    func conflicts() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("goals.md", """
        # Goals

        我的长期目标是做 Ambient AI。

        ## Amai 整理的记忆

        <!-- amai:memory:begin · x -->
        ### 计划
        - 年底前完成 Amai MVP <!-- src:2026-10-10 kind:stated -->
        - 似乎打算学习 Rust <!-- src:2026-10-11 kind:inferred -->
        - 准备 CVPR 投稿 <!-- src:2026-10-12 kind:inferred -->
        <!-- amai:memory:end -->
        """)
        try await f.seedDay(notes: "MVP 推迟到明年三月，先把记忆系统做扎实")
        f.model.digest = Responses.digest(routes: ["goals"])
        f.model.operations[.goals] = Responses.ops([
            ["op": "update", "item": "#1", "text": "年底前完成 Amai MVP 并发布", "evidence": ["I1"], "reason": "推断"],
            ["op": "retire", "item": "#1", "evidence": ["I1"], "reason": "看起来没在做"],
            ["op": "update", "item": "#1", "text": "MVP 推迟到明年三月", "evidence": ["S1"], "reason": "用户改变计划"],
            ["op": "retire", "item": "#2", "evidence": ["I2"], "reason": "最近没有相关活动"],
            ["op": "add", "section": "长期目标", "text": "做 Ambient AI", "evidence": ["U1"]],
        ])
        let report = try await f.consolidator.consolidateDay(f.day)
        let items = try f.items(.goals)
        let active = items.filter { $0.section != "变更记录" }
        #expect(active.map(\.text) == ["做 Ambient AI", "MVP 推迟到明年三月", "准备 CVPR 投稿"])
        #expect(active[1].kind == .stated && active[1].sources == ["2026-10-10", "2026-10-19"])
        let history = items.filter { $0.section == "变更记录" }.map(\.text)
        #expect(history.contains("2026-10-19 更新：「年底前完成 Amai MVP」→「MVP 推迟到明年三月」（用户改变计划）"))
        #expect(history.contains { $0.hasPrefix("2026-10-19 撤下：「似乎打算学习 Rust」") })
        #expect(report.rejected.count == 2)
        #expect(try f.read("goals.md").contains("我的长期目标是做 Ambient AI。"))
        #expect(f.snapshots.snapshots().contains { $0.lastPathComponent.hasSuffix("goals.md") })
    }

    @Test("Health keeps only the user's own data, and diagnoses only when the user stated them")
    func health() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay(notes: "昨晚只睡了四个小时\n上周医生诊断我有轻度贫血")
        f.model.digest = Responses.digest(routes: ["health"])
        f.model.operations[.health] = Responses.ops([
            ["op": "add", "section": "重要变化", "text": "昨晚只睡了四个小时", "evidence": ["S1"], "subject": "self"],
            ["op": "add", "section": "医学诊断", "text": "医生诊断有轻度贫血", "evidence": ["S2"], "subject": "self"],
            ["op": "add", "section": "健康关注", "text": "患有失眠症", "evidence": ["S1"], "subject": "self"],
            ["op": "add", "section": "健康关注", "text": "关注糖尿病饮食", "evidence": ["I2"], "subject": "self"],
            ["op": "add", "section": "健康关注", "text": "朋友在住院", "evidence": ["S1"], "subject": "third_party"],
            ["op": "add", "section": "医学诊断", "text": "可能有贫血", "evidence": ["I1"], "subject": "self"],
        ])
        let report = try await f.consolidator.consolidateDay(f.day)
        let items = try f.items(.health)
        #expect(items.map(\.text) == ["昨晚只睡了四个小时", "医生诊断有轻度贫血"])
        #expect(items.map(\.kind) == [.stated, .stated])
        #expect(report.rejected.count == 4)
    }

    @Test("Finance requires the user's own amount with currency, date and date type")
    func finance() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay(notes: "10 月工资到账 300000 日元\n看到一台 MacBook 卖 24 万日元")
        f.model.digest = Responses.digest(routes: ["finance"])
        f.model.operations[.finance] = Responses.ops([
            ["op": "add", "section": "收入", "text": "10 月工资到账 300000 日元", "evidence": ["S1"], "subject": "self",
             "amount": "300000", "currency": "JPY", "date": "2026-10-19", "date_type": "transaction"],
            ["op": "add", "section": "收入", "text": "10 月工资到账 300000 日元", "evidence": ["S1"], "subject": "self"],
            ["op": "add", "section": "支出", "text": "MacBook 售价 24 万日元", "evidence": ["S2"], "subject": "third_party",
             "amount": "240000", "currency": "JPY", "date": "2026-10-19", "date_type": "as_of"],
        ])
        _ = try await f.consolidator.consolidateDay(f.day)
        let items = try f.items(.finance)
        #expect(items.count == 1)
        #expect(items[0].attributes == ["amount": "300000", "cur": "JPY", "txn": "2026-10-19"])
        #expect(items[0].text == "10 月工资到账 300000 日元（交易日 2026-10-19）〔300000 JPY〕")
        #expect(items[0].sources == ["2026-10-19"])
        #expect(try f.read("finance.md").contains("amount:300000 cur:JPY kind:stated txn:2026-10-19") == false)
        #expect(try f.read("finance.md").contains("<!-- src:2026-10-19 kind:stated amount:300000 cur:JPY txn:2026-10-19 -->"))
    }

    @Test("a rewrite that retires most existing entries is rejected as a whole")
    func lossGuard() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let lines = (1...6).map { "- 条目 \($0) <!-- src:2026-10-18 kind:inferred -->" }.joined(separator: "\n")
        try f.write("work.md", "# Work\n\n## Amai 整理的记忆\n\n<!-- amai:memory:begin · x -->\n### 研究\n\(lines)\n<!-- amai:memory:end -->\n")
        let before = try f.read("work.md")
        try await f.seedDay()
        f.model.operations[.work] = Responses.ops((1...4).map { ["op": "retire", "item": "#\($0)", "evidence": ["I1"], "reason": "过时"] })
        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.updated.isEmpty)
        #expect(report.rejected.contains { $0.contains("整批拒绝") })
        #expect(try f.read("work.md") == before)
    }

    @Test("a failed category is retried later without redoing finished ones")
    func retry() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay(notes: "计划下周交初稿")
        f.model.digest = Responses.digest(routes: ["work", "goals"])
        f.model.failing = [.goals]
        await #expect(throws: Consolidator.ConsolidationError.categoriesFailed(["goals"])) {
            try await f.consolidator.consolidateDay(f.day)
        }
        #expect(await f.consolidator.status.lastDailyDay == nil)
        f.model.failing = []
        f.model.digest = Responses.digest(routes: [])
        let report = try await f.consolidator.consolidateDay(f.day)
        // 路由沿用第一次的结果；Work 已完成，不再调用。
        #expect(report.routed == [.work, .goals])
        #expect(f.model.categoryCalls == [.work, .goals, .goals])
        #expect(await f.consolidator.status.lastDailyDay == "2026-10-19")
    }

    @Test("unparsable digest fails without marking the day done")
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

    @Test("General summarises category entries and inherits their kind; user text survives")
    func general() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay()
        _ = try await f.consolidator.consolidateDay(f.day)
        try f.write("work.md", """
        # Work

        ## Amai 整理的记忆

        <!-- amai:memory:begin · x -->
        ### Amai
        - 开发 Ambient Personal AI 项目 Amai <!-- src:2026-10-17,2026-10-19 kind:stated -->
        - 修改了采集代码 <!-- src:2026-10-19 kind:inferred -->
        <!-- amai:memory:end -->
        """)
        try f.write("goals.md", """
        # Goals

        ## Amai 整理的记忆

        <!-- amai:memory:begin · x -->
        ### 长期目标
        - 成为研究者 <!-- src:2026-10-15 kind:confirmed -->
        <!-- amai:memory:end -->
        """)
        try f.write("general.md", """
        # General

        ## 基本信息
        某大学研究生

        ## Amai 整理的记忆

        <!-- amai:memory:begin · x -->
        ### 个人偏好
        - 似乎习惯深夜工作 <!-- src:2026-10-18 -->
        <!-- amai:memory:end -->
        """)
        f.model.operations[.general] = Responses.ops([
            ["op": "add", "section": "工作概况", "text": "开发 Ambient Personal AI 项目 Amai", "evidence": ["MW1"]],
            ["op": "add", "section": "目标概况", "text": "成为研究者", "evidence": ["MG1"]],
            ["op": "add", "section": "当前状态", "text": "最近在做采集代码", "evidence": ["MW2", "D1"]],
            ["op": "add", "section": "基本信息", "text": "住在东京", "evidence": ["D1"]],
            ["op": "update", "item": "#1", "text": "习惯深夜工作", "evidence": ["D1"], "reason": "x"],
        ])
        #expect(try await f.consolidator.updateGeneral())
        let prompt = try #require(f.model.prompts[.general])
        #expect(prompt.contains("[MW1]") && prompt.contains("（stated）"))
        #expect(prompt.contains("[U1] 2026-10-20 某大学研究生"))
        let items = try f.items(.general)
        let byText = Dictionary(uniqueKeysWithValues: items.map { ($0.text, $0) })
        #expect(byText["开发 Ambient Personal AI 项目 Amai"]?.kind == .stated)
        #expect(byText["开发 Ambient Personal AI 项目 Amai"]?.sources == ["2026-10-17", "2026-10-19"])
        // 由用户确认的条目汇总而来也不会成为 confirmed。
        #expect(byText["成为研究者"]?.kind == .stated)
        #expect(byText["最近在做采集代码"]?.kind == .inferred)
        // 只有摘要（推断）支持的基本信息照常记为推断；推断可以修改 unknown 条目。
        #expect(byText["住在东京"]?.kind == .inferred)
        #expect(byText["习惯深夜工作"]?.kind == .inferred)
        #expect(try f.read("general.md").hasPrefix("# General\n\n## 基本信息\n某大学研究生\n"))
        #expect(await f.consolidator.status.lastGeneralAt != nil)
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
        let early = try Fixture(now: Date(timeIntervalSince1970: 1_792_368_000 + 86_400 + 3 * 3600))
        defer { early.cleanup() }
        try await early.seedDay()
        await early.consolidator.tick()
        #expect(early.model.calls == 0)

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
        #expect(Consolidator.projectName("变更记录") == nil)
    }
}

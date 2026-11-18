import AmaiCore
import Foundation
import Testing
@testable import AmaiMemory

@Suite("EvidenceLedger")
struct EvidenceLedgerTests {
    @Test("user lines exclude system blocks and headings; low-confidence segments are not evidence")
    func building() {
        let daily = """
        # 2026-10-19

        ## 摘要

        <!-- amai:digest:begin · x -->
        摘要内容
        <!-- amai:digest:end -->

        ## 时间线

        <!-- amai:timeline:begin · x -->
        - 03:00–04:00 编辑代码 <!-- seg:A conf:0.9 src:x -->
        <!-- amai:timeline:end -->

        ## 我的笔记
        - 今天很累
        """
        let fact = Observation(
            timeRange: TimeRange(start: at(0), end: at(10)), modality: .screen, kind: .fact, content: "OCR 文字",
            confidence: 1, evidence: [], attributes: ["app": "Xcode"], provider: "perception"
        )
        let ledger = EvidenceLedger.forDay(
            day: "2026-10-19", daily: daily,
            segments: [
                segment(0, 3600, "编辑代码", observations: [fact.id]),
                segment(3600, 4000, "看不清", confidence: 0.3),
            ],
            observations: [fact], timeZone: utc
        )
        #expect(ledger.entries.map(\.id) == ["S1", "F1", "I1"])
        #expect(ledger["S1"]?.text == "今天很累")
        #expect(ledger["F1"]?.apps == ["Xcode"])
        #expect(!ledger.render().contains("OCR 文字"))
        #expect(!ledger.render().contains("摘要内容"))
    }

    @Test("without segments the daily timeline is used as inference evidence")
    func timelineFallback() {
        let daily = "# d\n\n## 时间线\n\n<!-- amai:timeline:begin · x -->\n- 03:00–04:00 编辑代码 <!-- seg:A -->\n  细节\n- 05:00–05:10 〔低置信〕不确定 <!-- seg:B -->\n<!-- amai:timeline:end -->\n"
        let ledger = EvidenceLedger.forDay(day: "2026-10-19", daily: daily, segments: [], observations: [], timeZone: utc)
        #expect(ledger.entries.map(\.text) == ["03:00–04:00 编辑代码"])
        #expect(ledger.entries.map(\.basis) == [.inference])
    }

    @Test("derivation collects source dates from valid citations and flags entries resting on the user's own words")
    func derive() {
        var ledger = EvidenceLedger()
        ledger.append(.userStatement, day: "2026-10-19", text: "计划周五前提交初稿")
        ledger.append(.observation, day: "2026-10-18", text: "03:00–04:00 前台应用：Xcode", apps: ["Xcode"])
        ledger.append(.memory, prefix: "MG", day: "2026-10-15", text: "成为研究者", sourceDays: ["2026-10-14", "2026-10-15"])
        #expect(ledger.derive(text: "计划周五前提交初稿", citing: ["S1"]) == .init(sources: ["2026-10-19"], cited: ["S1"], restsOnUserStatements: true))
        #expect(ledger.derive(text: "计划在周五前提交初稿", citing: ["S1"])?.restsOnUserStatements == true)
        // 原话里没有的内容，或混入其他依据，都不算出自用户本人原话。
        #expect(ledger.derive(text: "下周要答辩", citing: ["S1"])?.restsOnUserStatements == false)
        let mixed = ledger.derive(text: "计划周五前提交初稿，在 Xcode 中准备", citing: ["S1", "F1"])
        #expect(mixed?.sources == ["2026-10-18", "2026-10-19"] && mixed?.restsOnUserStatements == false)
        // M 依据沿用原条目的来源日期；无效编号被忽略。
        #expect(ledger.derive(text: "成为研究者", citing: ["MG1", "Z9"]) == .init(sources: ["2026-10-14", "2026-10-15"], cited: ["MG1"], restsOnUserStatements: false))
        // F 依据与内容无关（没提到其中的应用）时不采纳。
        #expect(ledger.derive(text: "在 Safari 中查资料", citing: ["F1"]) == nil)
        #expect(ledger.derive(text: "x", citing: ["Z9"]) == nil)
        #expect(ledger.derive(text: "x", citing: []) == nil)
    }
}

@Suite("CategoryUpdater")
struct CategoryUpdaterTests {
    func ledger() -> EvidenceLedger {
        var l = EvidenceLedger()
        l.append(.userStatement, day: "2026-10-19", text: "决定不再做 Rust 版本")
        l.append(.inference, day: "2026-10-19", text: "03:00 编辑代码")
        return l
    }

    let items = [
        MemoryItem(text: "计划学习 Rust", sources: ["2026-10-10"], section: "计划"),
        MemoryItem(text: "计划写 Rust 版本", sources: ["2026-10-11"], section: "计划"),
        MemoryItem(text: "成为研究者", sources: ["2026-10-01"], section: "长期目标"),
        MemoryItem(text: "每天写代码", sources: ["2026-10-02"], section: "计划"),
    ]

    @Test("merge only combines entries in one section and cannot add new content")
    func merge() {
        let updater = CategoryUpdater(policy: .policy(for: .goals), ledger: ledger(), day: "2026-10-19")
        let ok = updater.apply([MemoryOperation(op: "merge", items: ["#1", "#2"], text: "计划学习 Rust 并写 Rust 版本")], to: items, sectionMeta: [:])
        #expect(ok.items.filter { $0.section != "变更记录" }.count == 3)
        #expect(ok.items.first?.sources == ["2026-10-10", "2026-10-11"])

        let invented = updater.apply([MemoryOperation(op: "merge", items: ["#1", "#2"], text: "已经发布了 Rust 版本的商业产品")], to: items, sectionMeta: [:])
        #expect(!invented.changed && invented.rejected.count == 1)
        let crossSection = updater.apply([MemoryOperation(op: "merge", items: ["#1", "#3"], text: "计划学习 Rust 成为研究者")], to: items, sectionMeta: [:])
        #expect(!crossSection.changed)
    }

    @Test("update and retire need valid entries, evidence and a reason, and leave a history record")
    func updateAndRetire() {
        let updater = CategoryUpdater(policy: .policy(for: .goals), ledger: ledger(), day: "2026-10-19")
        let r = updater.apply([
            MemoryOperation(op: "retire", item: "#3", evidence: ["S1"]),
            MemoryOperation(op: "retire", item: "#3", evidence: ["Z9"], reason: "过时"),
            MemoryOperation(op: "update", item: "#9", text: "决定不再做 Rust 版本", evidence: ["S1"]),
            MemoryOperation(op: "retire", item: "#2", evidence: ["S1"], reason: "决定不再做 Rust 版本"),
            MemoryOperation(op: "explode", item: "#1"),
        ], to: items, sectionMeta: [:])
        #expect(r.rejected.count == 4)
        #expect(r.items.contains(items[2]))
        #expect(!r.items.contains(items[1]))
        let record = r.items.first { $0.section == "变更记录" }
        #expect(record?.text.contains("撤下：「计划写 Rust 版本」") == true)
        #expect(record?.sources == ["2026-10-11", "2026-10-19"])
    }

    @Test("history is capped, oldest first")
    func historyCap() {
        let old = (1...CategoryPolicy.historyLimit).map { MemoryItem(text: "旧记录 \($0)", sources: ["2026-10-01"], section: "变更记录") }
        let updater = CategoryUpdater(policy: .policy(for: .goals), ledger: ledger(), day: "2026-10-19")
        let r = updater.apply([MemoryOperation(op: "retire", item: "#1", evidence: ["I1"], reason: "过时")], to: items + old, sectionMeta: [:])
        let history = r.items.filter { $0.section == "变更记录" }
        #expect(history.count == CategoryPolicy.historyLimit)
        #expect(history.first?.text == "旧记录 2")
    }

    @Test("attributes and section metadata survive render/parse, including spaces")
    func attributes() {
        let items = [MemoryItem(text: "房租", sources: ["2026-10-20"], section: "Amai 项目", attributes: ["amount": "85000", "cur": "JPY", "note": "a b%c"])]
        let body = MemoryItems.render(items, sectionMeta: ["Amai 项目": ["project": "p-abc123", "aka": "Amai 项目进展|Amai"]])
        #expect(MemoryItems.parse(body) == items)
        let sections = MemoryItems.sections(body)
        #expect(sections.first?.name == "Amai 项目")
        #expect(sections.first?.meta == ["project": "p-abc123", "aka": "Amai 项目进展|Amai"])
    }

    @Test("project matching uses exact names and explicit aliases only, never prefixes")
    func projectMatching() {
        let meta: [String: [String: String]] = ["Amai 项目进展": ["project": "p-1", "aka": "Amai"], "Lumen": ["project": "p-2"]]
        #expect(CategoryUpdater.matchProject("amai", meta: meta) == "Amai 项目进展")
        #expect(CategoryUpdater.matchProject("AMAI 项目进展", meta: meta) == "Amai 项目进展")
        #expect(CategoryUpdater.matchProject("Lumen Lab", meta: meta) == nil)
        #expect(CategoryUpdater.matchProject("Lum", meta: meta) == nil)
        #expect(CategoryUpdater.matchProject("Amai 评测", meta: meta) == nil)
    }
}

@Suite("Statement coverage")
struct StatementCoverageTests {
    @Test("dates and reporting frames do not count as new claims, invented content still does")
    func framing() {
        let s = "这周右膝盖一直疼，先暂停跑步。"
        #expect(EvidenceLedger.coverage(of: "用户自述2026年10月中旬那一周右膝盖一直疼，因此先暂停跑步", in: s) >= EvidenceLedger.statementCoverage)
        #expect(EvidenceLedger.coverage(of: "右膝半月板撕裂需要手术", in: s) < EvidenceLedger.statementCoverage)
    }
}

@Suite("Evidence checks")
struct EvidenceCheckTests {
    @Test("a shared English name does not carry an embellished entry over the statement threshold")
    func properNoun() {
        let note = "Atlas 项目正式改名为 Orbit，仓库也一起改了名。"
        #expect(EvidenceLedger.coverage(of: "搭建 Orbit 的数据标注工具", in: note) < EvidenceLedger.statementCoverage)
        #expect(EvidenceLedger.coverage(of: "Atlas 项目改名为 Orbit", in: note) >= EvidenceLedger.statementCoverage)
        #expect(EvidenceLedger.units("用 Xcode 写 SyncEngine2") == ["用", "xcode", "写", "syncengine2"])
    }

    @Test("an entry already recorded in another category is not added again")
    func crossCategory() {
        var ledger = EvidenceLedger()
        ledger.append(.userStatement, day: "2026-10-15", text: "这周右膝盖一直疼，先暂停跑步。")
        var updater = CategoryUpdater(policy: .policy(for: .goals), ledger: ledger, day: "2026-10-15")
        updater.otherCategories = [(.health, "这周右膝盖一直疼，先暂停跑步。")]
        let r = updater.apply([
            MemoryOperation(op: "add", section: "决策", text: "这周右膝盖一直疼，先暂停跑步", evidence: ["S1"]),
            MemoryOperation(op: "add", section: "计划", text: "膝盖好之前先暂停跑步，之后恢复每周训练", evidence: ["S1"]),
        ], to: [], sectionMeta: [:])
        #expect(r.rejected == ["add 这周右膝盖一直疼，先暂停跑步：已记录在健康分区"])
        #expect(r.items.count == 1)
    }
}

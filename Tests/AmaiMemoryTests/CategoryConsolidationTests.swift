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

    @Test("derivation takes the weakest cited basis, ignores unknown IDs, and never yields confirmed")
    func derive() {
        var ledger = EvidenceLedger()
        ledger.append(.userStatement, day: "2026-10-19", text: "计划周五前提交初稿")
        ledger.append(.observation, day: "2026-10-19", text: "03:00–04:00 前台应用：Xcode", apps: ["Xcode"])
        ledger.append(.memory, prefix: "MG", day: "2026-10-15", text: "成为研究者", memoryKind: .confirmed, sourceDays: ["2026-10-14", "2026-10-15"])
        #expect(ledger.derive(text: "计划周五前提交初稿", citing: ["S1"])?.kind == .stated)
        #expect(ledger.derive(text: "计划在周五前提交初稿", citing: ["S1"])?.kind == .stated)
        #expect(ledger.derive(text: "下周要答辩", citing: ["S1"])?.kind == .inferred)
        #expect(ledger.derive(text: "计划周五前提交初稿，在 Xcode 中准备", citing: ["S1", "F1"])?.kind == .observed)
        #expect(ledger.derive(text: "成为研究者", citing: ["MG1"]) == .init(kind: .stated, sources: ["2026-10-14", "2026-10-15"], cited: ["MG1"]))
        #expect(ledger.derive(text: "x", citing: ["Z9", "F1"]) == nil)
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
        MemoryItem(text: "计划学习 Rust", sources: ["2026-10-10"], section: "计划", kind: .inferred),
        MemoryItem(text: "计划写 Rust 版本", sources: ["2026-10-11"], section: "计划", kind: .inferred),
        MemoryItem(text: "成为研究者", sources: ["2026-10-01"], section: "长期目标", kind: .confirmed),
        MemoryItem(text: "每天写代码", sources: ["2026-10-02"], section: "计划", kind: .stated),
    ]

    @Test("merge only combines same-kind entries in one section and cannot add new content")
    func merge() {
        let updater = CategoryUpdater(policy: .policy(for: .goals), ledger: ledger(), day: "2026-10-19")
        let ok = updater.apply([MemoryOperation(op: "merge", items: ["#1", "#2"], text: "计划学习 Rust 并写 Rust 版本")], to: items, sectionMeta: [:])
        #expect(ok.items.filter { $0.section != "变更记录" }.count == 3)
        #expect(ok.items.first?.sources == ["2026-10-10", "2026-10-11"])

        let invented = updater.apply([MemoryOperation(op: "merge", items: ["#1", "#2"], text: "已经发布了 Rust 版本的商业产品")], to: items, sectionMeta: [:])
        #expect(!invented.changed && invented.rejected.count == 1)
        let crossKind = updater.apply([MemoryOperation(op: "merge", items: ["#1", "#4"], text: "计划学习 Rust 每天写代码")], to: items, sectionMeta: [:])
        #expect(!crossKind.changed)
    }

    @Test("confirmed entries are never retired or overwritten by consolidation")
    func confirmed() {
        let updater = CategoryUpdater(policy: .policy(for: .goals), ledger: ledger(), day: "2026-10-19")
        let r = updater.apply([
            MemoryOperation(op: "retire", item: "#3", evidence: ["S1"], reason: "决定不再做"),
            MemoryOperation(op: "update", item: "#3", text: "决定不再做 Rust 版本", evidence: ["S1"]),
            MemoryOperation(op: "retire", item: "#2", evidence: ["S1"], reason: "决定不再做 Rust 版本"),
            MemoryOperation(op: "explode", item: "#1"),
        ], to: items, sectionMeta: [:])
        #expect(r.rejected.count == 3)
        #expect(r.items.contains(items[2]))
        #expect(r.items.contains { $0.section == "变更记录" && $0.text.contains("撤下：「计划写 Rust 版本」") && $0.kind == .stated })
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
        let items = [MemoryItem(text: "房租", sources: ["2026-10-20"], section: "Amai 项目", kind: .stated, attributes: ["amount": "85000", "cur": "JPY", "note": "a b%c"])]
        let body = MemoryItems.render(items, sectionMeta: ["Amai 项目": ["project": "p-abc123", "aka": "Amai 项目进展|Amai"]])
        #expect(MemoryItems.parse(body) == items)
        let sections = MemoryItems.sections(body)
        #expect(sections.first?.name == "Amai 项目")
        #expect(sections.first?.meta == ["project": "p-abc123", "aka": "Amai 项目进展|Amai"])
    }

    @Test("project matching uses exact names, aliases and long prefixes only")
    func projectMatching() {
        let meta: [String: [String: String]] = ["Amai 项目进展": ["project": "p-1"], "AI": ["project": "p-2", "aka": "Artificial"]]
        #expect(CategoryUpdater.matchProject("amai", meta: meta) == "Amai 项目进展")
        #expect(CategoryUpdater.matchProject("Artificial", meta: meta) == "AI")
        #expect(CategoryUpdater.matchProject("AI 安全", meta: meta) == nil)
        #expect(CategoryUpdater.matchProject("Ama", meta: meta) == nil)
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

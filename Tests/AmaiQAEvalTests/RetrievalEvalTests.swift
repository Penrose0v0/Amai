import AmaiAssistant
import AmaiCore
import AmaiMemory
import Foundation
import Testing
@testable import AmaiQAEval

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let now = ISO8601DateFormatter().date(from: "2026-11-19T03:00:00Z")!

private func unit(_ id: String, _ file: String, date: String? = nil, _ text: String, kind: QAEvidence.Kind = .timelineEntry) -> QAEvidence {
    QAEvidence(id: id, kind: kind, category: MemoryCategory(file: file) ?? .daily, file: file, date: date, text: text)
}

private func gtUnit(_ e: QAEvidence) -> QAGroundTruth.Unit { QAGroundTruth.unit(e) }

private func run(_ items: [[String]], tokens: Int = 100, system: QARetrievalSystem = .hybrid) -> QARetrievalRun {
    QARetrievalRun(
        item: "Q1", system: system, query: "q", ms: 1,
        items: items.map { QARetrievedItem(text: "x", file: nil, date: nil, score: 0.5, tokens: tokens, units: $0) },
        turnStart: 0, dayTimelines: [], truncatedDays: [], rangeDays: [], capped: false, productionTop: nil
    )
}

@Suite("Retrieval eval")
struct RetrievalEvalTests {
    @Test("the memory block is split into items mapped back to units, with whole days and truncation recognized")
    func parse() {
        let a = unit("E1", "daily/2026-11-12.md", date: "2026-11-12", "讨论 Lumen 的同步方案 — 比较了 CloudKit 与自建服务")
        let b = unit("E2", "work.md", "〔决策〕放弃 CloudKit，改用自建同步服务，因为需要支持 Android", kind: .item)
        let c = unit("E3", "daily/2026-11-13.md", date: "2026-11-13", "回复邮件和 Slack")
        let d = unit("E4", "daily/2026-11-12.md", date: "2026-11-12", "回复邮件和 Slack")
        let matcher = QAUnitMatcher([a, b, c, d])
        let memory = """
        Entries found for this question, most relevant first:
        - [work › Lumen, 2026-11-12] 〔决策〕放弃 CloudKit，改用自建同步服务，因为需要支持 Android
        - [timeline 2026-11-13] 15:00–16:30 回复邮件和 Slack

        Timeline for 2026-11-12:
        Summary: 活跃 5 小时。
        - 09:00–11:00 讨论 Lumen 的同步方案 — 比较了 CloudKit 与自建服务
        - 13:00–14:00 回复邮件 […]

        Daily records from 2026-11-10 to 2026-11-11, newest first:
        - 2026-11-11: 回复邮件和 Slack
        """
        let parsed = QARecallParser.parse(memory, matcher: matcher)
        #expect(parsed.items.map(\.units) == [["E2"], ["E3"], [], ["E1"], [], []])
        #expect(parsed.items[1].date == "2026-11-13" && parsed.items[0].file == "work.md")
        #expect(parsed.dayTimelines == ["2026-11-12"] && parsed.truncatedDays == ["2026-11-12"] && parsed.rangeDays == ["2026-11-11"])
        #expect(!parsed.capped)
        #expect(parsed.items.allSatisfy { $0.tokens > 0 })
    }

    @Test("Recall@K, Full, Precision@K and nDCG@K follow their definitions; alternatives satisfy one requirement")
    func metrics() {
        // 两个信息点：A 可由 E1 或 E2 提供，B 只有 E3。
        let entry = QAGroundTruth.Entry(requirements: [
            [gtUnit(unit("E1", "work.md", "x1x1x1x1", kind: .item)), gtUnit(unit("E2", "daily/2026-11-12.md", date: "2026-11-12", "x2x2x2x2"))],
            [gtUnit(unit("E3", "work.md", "x3x3x3x3", kind: .item))],
        ])
        let s = QARetrievalMetrics.score(run([["E9"], ["E2"], ["E1"], ["E3"], []]), entry: entry)
        #expect(s.firstHit == [2, 4])
        #expect(s.recall(at: 1) == 0 && s.recall(at: 3) == 0.5 && s.recall(at: 4) == 1)
        #expect(!s.full(at: 3) && s.full(at: 4))
        // E1 与 E2 都相关（同一信息点的替代记录），分母是 K。
        #expect(s.relevantRanks == [2, 3, 4] && s.precision(at: 3) == 2.0 / 3)
        // 增益只给让信息点首次满足的项：第 2、4 名。理想是第 1、2 名。
        let ideal = 1 / log2(2.0) + 1 / log2(3.0)
        #expect(abs(s.ndcg(at: 6) - (1 / log2(3.0) + 1 / log2(5.0)) / ideal) < 1e-9)
        #expect(s.ndcg(at: 1) == 0)
        #expect(QARetrievalMetrics.score(run([["E1"], ["E3"]]), entry: entry).ndcg(at: 6) == 1)
    }

    @Test("a token budget keeps only the prefix that fits, so returning more items cannot inflate recall")
    func budget() {
        let entry = QAGroundTruth.Entry(requirements: [[gtUnit(unit("E1", "work.md", "x1x1x1x1", kind: .item))]])
        let late = QARetrievalMetrics.score(run(Array(repeating: ["E9"], count: 50) + [["E1"]], tokens: 100), entry: entry)
        #expect(late.recall(at: late.count) == 1)
        #expect(late.budgetCutoff(4096) == 40 && late.recall(budget: 4096) == 0 && late.tokensUsed(budget: 4096) == 4000)
        #expect(late.recall(budget: 8192) == 1)
    }

    @Test("provisional GT uses seed evidence only and leaves follow-ups out; imported annotations become OR-groups")
    func groundTruth() throws {
        let memory = try SyntheticMemory()
        defer { memory.cleanup() }
        let catalog = try EvidenceCatalog.build(root: memory.root, timeZone: tokyo)
        let decision = try #require(catalog.units.first { $0.text.contains("CloudKit") && $0.kind == .item })
        let segment = try #require(catalog.units.first { $0.text.hasPrefix("讨论 Lumen") })
        let run = try #require(catalog.units.first { $0.text.hasPrefix("健身房跑步") })
        func item(_ id: String, _ type: QAQuestionType, _ evidence: [String], turn: Int = 0) -> QAItem {
            QAItem(id: id, conversation: "C\(id)", turn: turn, type: type, subtype: "x", language: "zh", question: "q",
                   expectedAnswer: "a", keyPoints: ["a"], evidence: evidence, context: [], absentTerms: [], maxOverlap: 0)
        }
        let dataset = QADataset(createdAt: now, now: now, timeZone: tokyo.identifier, memoryDigest: "d", seed: 1,
                                evidence: catalog.units, items: [item("Q1", .fact, [decision.id]), item("Q2", .followUp, [run.id]), item("Q3", .fact, [run.id])],
                                egress: QAEgress(), unfilledSlots: 0)
        let provisional = QAGroundTruth.provisional(dataset)
        #expect(provisional.source == .provisionalSeed)
        #expect(provisional.items["Q1"]?.requirements.map { $0.map(\.id) } == [[decision.id]])
        #expect(provisional.items["Q2"]?.excluded != nil)

        let sheet: [String: Any] = ["memoryDigest": "d", "items": [
            "Q1": ["labels": [decision.id: "A", segment.id: "A", run.id: "none"], "done": true],
            "Q2": ["labels": [:] as [String: String], "excluded": "题目有歧义", "done": true],
            "Q3": ["labels": [run.id: "B"], "done": false],
        ]]
        let (gt, incomplete) = try QAGroundTruth.importAnnotations(
            try JSONSerialization.data(withJSONObject: sheet), dataset: dataset, catalog: catalog, annotator: "tester"
        )
        #expect(gt.source == .human && gt.annotator == "tester")
        #expect(gt.items["Q1"]?.requirements.map { Set($0.map(\.id)) } == [[decision.id, segment.id]])
        #expect(gt.items["Q2"]?.excluded == "题目有歧义")
        #expect(incomplete == ["Q3"] && gt.items["Q3"] == nil)
        // 只标注子集时，子集外的题不算未完成。
        let scoped = try QAGroundTruth.importAnnotations(
            try JSONSerialization.data(withJSONObject: sheet), dataset: dataset, catalog: catalog, annotator: nil, scope: ["Q1", "Q2"]
        )
        #expect(scoped.incomplete.isEmpty && scoped.gt.items.count == 2)

        let wrong: [String: Any] = ["memoryDigest": "other", "items": [:] as [String: Any]]
        #expect(throws: QAEvalError.self) {
            try QAGroundTruth.importAnnotations(try JSONSerialization.data(withJSONObject: wrong), dataset: dataset, catalog: catalog, annotator: nil)
        }
    }

    @Test("the annotation subset is stratified, reproducible, takes follow-ups only from later turns, and ignores results")
    func subset() {
        var items: [QAItem] = []
        func add(_ type: QAQuestionType, _ subtype: String, count: Int, turns: Int = 1) {
            for c in 0..<count {
                let conversation = "C\(items.count)"
                for t in 0..<turns {
                    items.append(QAItem(id: "Q\(items.count)", conversation: conversation, turn: t, type: type, subtype: subtype, language: "zh",
                                        question: "q", expectedAnswer: "a", keyPoints: ["a"], evidence: ["E\(c)"], context: [], absentTerms: [], maxOverlap: 0))
                }
            }
        }
        add(.fact, "document", count: 15); add(.fact, "timeline", count: 15)
        add(.temporal, "relativeDate", count: 8); add(.temporal, "when", count: 7); add(.temporal, "ordering", count: 7)
        add(.crossLingual, "english", count: 8); add(.crossLingual, "japanese", count: 7)
        add(.followUp, "sameDay", count: 3, turns: 3); add(.followUp, "sameTopic", count: 3, turns: 3)
        add(.unanswerable, "absentEntity", count: 9)
        let dataset = QADataset(createdAt: now, now: now, timeZone: tokyo.identifier, memoryDigest: "d", seed: 7,
                                evidence: [], items: items, egress: QAEgress(), unfilledSlots: 0)
        let ids = QAGroundTruthSheet.subset(dataset, seed: 7)
        #expect(ids.count == 30 && Set(ids).count == 30)
        #expect(ids == QAGroundTruthSheet.subset(dataset, seed: 7))
        let picked = items.filter { ids.contains($0.id) }
        #expect(picked.allSatisfy { $0.isAnswerable })
        let followUps = picked.filter { $0.type == .followUp }
        #expect(followUps.count == 8 && followUps.allSatisfy { $0.turn > 0 })
        // 每段追问对话至少有一轮入选。
        #expect(Set(followUps.map(\.conversation)).count == 6)
        #expect(picked.filter { $0.subtype == "ordering" }.count == 4)
    }

    @Test("misses are attributed: unrecognized date, truncated day, ranked out, not retrieved")
    func causes() {
        let day = unit("E1", "daily/2026-11-13.md", date: "2026-11-13", "修复 Lumen 的上传缺陷")
        let doc = unit("E2", "work.md", "论文投到了 CHI", kind: .item)
        func item(_ q: String) -> QAItem {
            QAItem(id: "Q1", conversation: "C1", turn: 0, type: .fact, subtype: "x", language: "zh", question: q,
                   expectedAnswer: "a", keyPoints: ["a"], evidence: [], context: [], absentTerms: [], maxOverlap: 0)
        }
        var pipeline = run([], system: .pipeline)
        let hybridLate = run(Array(repeating: ["E9"], count: 9) + [["E1"], ["E2"]])
        func cause(_ u: QAEvidence, _ q: String, _ p: QARetrievalRun, _ h: QARetrievalRun?) -> QARetrievalMetrics.Cause {
            QARetrievalMetrics.cause(requirement: [gtUnit(u)], pipeline: p, hybrid: h, item: item(q), previousQuestions: [], now: now, timeZone: tokyo).cause
        }
        #expect(cause(day, "上周五我修了什么？", pipeline, hybridLate) == .dateNotRecognized)
        pipeline.dayTimelines = ["2026-11-13"]
        pipeline.truncatedDays = ["2026-11-13"]
        #expect(cause(day, "上周五我修了什么？", pipeline, hybridLate) == .dayTruncated)
        #expect(cause(doc, "论文投哪了", run([], system: .pipeline), hybridLate) == .rankedOut)
        #expect(cause(doc, "论文投哪了", run([], system: .pipeline), run([])) == .notRetrieved)
        #expect(cause(doc, "论文投哪了", run([], system: .pipeline), run([["E2"]])) == .lostInPipeline)
        var scoped = run([], system: .pipeline)
        scoped.dayTimelines = ["2026-11-12"]
        #expect(cause(doc, "11 月 12 日论文投哪了", scoped, hybridLate) == .dateScopeFiltered)
    }

    @Test("end to end on synthetic memory: no answering model, pipeline is cumulative per conversation, memory untouched")
    func endToEnd() async throws {
        let memory = try SyntheticMemory()
        defer { memory.cleanup() }
        let before = try memory.snapshot()
        let catalog = try EvidenceCatalog.build(root: memory.root, timeZone: tokyo)
        let upload = try #require(catalog.units.first { $0.text.hasPrefix("修复 Lumen") })
        let kyoto = try #require(catalog.units.first { $0.text.hasPrefix("预订京都旅馆") })
        func item(_ id: String, _ c: String, turn: Int = 0, _ q: String, _ evidence: [String], type: QAQuestionType = .fact) -> QAItem {
            QAItem(id: id, conversation: c, turn: turn, type: type, subtype: "x", language: "zh", question: q,
                   expectedAnswer: "a", keyPoints: ["a"], evidence: evidence, context: [], absentTerms: [], maxOverlap: 0)
        }
        let dataset = QADataset(createdAt: now, now: now, timeZone: tokyo.identifier, memoryDigest: "d", seed: 1, evidence: catalog.units, items: [
            item("Q1", "C1", "11 月 13 日我修了什么问题？", [upload.id]),
            item("Q2", "C1", turn: 1, "那天还做了什么？", [upload.id], type: .followUp),
            item("Q3", "C2", "我订的旅馆在哪个城市？", [kyoto.id]),
            QAItem(id: "Q4", conversation: "C3", turn: 0, type: .unanswerable, subtype: "absentEntity", language: "zh", question: "我的 Notion 团队版多少钱？",
                   expectedAnswer: "没有记录", keyPoints: ["没有记录"], evidence: [], context: [], absentTerms: ["Notion"], maxOverlap: 0),
        ], egress: QAEgress(), unfilledSlots: 0)
        let index = MemoryIndex(root: memory.root, database: try MemoryIndexDatabase(path: memory.root.appendingPathComponent("i.sqlite").path), timeZone: tokyo)
        let api = MemoryAPI(root: memory.root, index: index, access: .all, timeZone: tokyo)
        let runs = try await QARetrievalRunner(
            dataset: dataset, matcher: QAUnitMatcher(catalog.units), hybrid: api, keyword: api,
            builder: ContextBuilder(language: "Chinese", timeZone: tokyo)
        ).run()
        // 四个系统：pipeline（4K）、pipeline-8k、hybrid、keyword。
        #expect(runs.count == 16)
        let p1 = try #require(runs.first { $0.item == "Q1" && $0.system == .pipeline })
        let p2 = try #require(runs.first { $0.item == "Q2" && $0.system == .pipeline })
        #expect(p1.dayTimelines == ["2026-11-13"] && p1.items.contains { $0.units.contains(upload.id) })
        // 追问：之前给过的记忆在前，这一轮的新内容从 turnStart 开始。
        #expect(p2.turnStart == p1.items.count && p2.items.prefix(p1.items.count).elementsSatisfy(p1.items))
        let h3 = try #require(runs.first { $0.item == "Q3" && $0.system == .hybrid })
        #expect(h3.items.first?.units == [kyoto.id] && h3.productionTop == nil)
        #expect(runs.filter { $0.system == .pipeline8k }.count == 4)

        let (summary, _, _) = QARetrievalReport.evaluate(dataset: dataset, gt: QAGroundTruth.provisional(dataset), runs: runs, embedder: "none", notes: [])
        #expect(summary.scoredQuestions == 2 && summary.excluded.count == 1)
        #expect(summary.systems["pipeline"]?.fullAll == 1)
        #expect(summary.unanswerable["pipeline"]?["absentEntity"]?.questions == 1)
        let text = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self) + QARetrievalReport.metricsMarkdown(summary)
        for leak in ["京都", "Lumen", "Notion", "旅馆", "上传"] { #expect(!text.contains(leak), "summary leaks \(leak)") }
        #expect(try memory.snapshot().filter { $0.key.hasSuffix(".md") } == before)

        let html = try QAGroundTruthSheet.html(dataset: dataset, runs: runs, catalog: catalog)
        #expect(html.contains("\"memoryDigest\":\"d\"") && !html.contains("__DATA__"))
        // 候选里有种子证据，但页面不标出哪条是种子。
        #expect(QAGroundTruthSheet.candidates(for: dataset.items[2], dataset: dataset, runs: runs, catalog: catalog).contains(kyoto.id))
        #expect(!html.contains("seed") && !html.contains("evidence"))
    }
}

private extension Sequence where Element: Equatable {
    func elementsSatisfy<S: Sequence>(_ other: S) -> Bool where S.Element == Element { Array(self) == Array(other) }
}

import AmaiAssistant
import AmaiCore
import AmaiMemory
import Foundation
import os
import Testing
@testable import AmaiQAEval

// 全部使用合成数据。

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
/// 2026-11-19 12:00 JST（星期四）。
private let now = ISO8601DateFormatter().date(from: "2026-11-19T03:00:00Z")!

/// 合成记忆：长期记忆两个文件、四天的 daily（11-13 与 11-14 之间、11-16 之后有空档）。
struct SyntheticMemory {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("amai-qa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("daily"), withIntermediateDirectories: true)
        try write("work.md", """
        # 工作

        <!-- amai:memory:begin · x -->
        ### Lumen
        - 〔决策〕放弃 CloudKit，改用自建同步服务，因为需要支持 Android <!-- src:2026-11-12 -->
        - 修复了离线重连后重复上传附件的问题 <!-- src:2026-11-13 -->
        - 笔记导出时附件路径的处理方案还没定 <!-- src:2026-11-14 -->
        ### Orbit
        - 数据标注工具的前端改用 React 重写 <!-- src:2026-11-10 -->
        <!-- amai:memory:end -->
        """)
        try write("general.md", """
        # 综合

        <!-- amai:memory:begin · x -->
        ### 背景
        - 博士二年级，研究方向是多模态检索 <!-- src:2026-11-01 -->
        - 住在东京，习惯晚上写代码 <!-- src:2026-11-02 -->
        <!-- amai:memory:end -->
        """)
        try day("2026-11-12", ["09:00–11:00 讨论 Lumen 的同步方案|比较了 CloudKit 与自建服务", "14:00–15:30 阅读多模态检索论文|读完两篇关于视频检索的论文"])
        try day("2026-11-13", ["10:00–12:00 修复 Lumen 的上传缺陷|离线重连后附件会重复上传", "16:00–17:00 健身房跑步|跑了 5 公里"])
        try day("2026-11-15", ["13:00–14:00 整理组会幻灯片|准备周一组会的汇报", "20:00–21:00 预订京都旅馆|订了 12 月三晚的旅馆"])
        try day("2026-11-16", ["09:30–10:30 回复导师邮件|确认开题报告的提交时间"])
    }

    func write(_ file: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func day(_ name: String, _ entries: [String]) throws {
        var lines = ["# \(name)", "", "## 时间线", "", "<!-- amai:timeline:begin · x -->"]
        for (index, entry) in entries.enumerated() {
            let parts = entry.split(separator: "|").map(String.init)
            lines.append("- \(parts[0]) <!-- seg:\(name)-\(index) conf:0.90 -->")
            if parts.count > 1 { lines.append("  \(parts[1])") }
        }
        lines.append("<!-- amai:timeline:end -->")
        try write("daily/\(name).md", lines.joined(separator: "\n"))
    }

    /// 所有文件的内容（用来确认没有被改动）。
    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in QAWorkspace.memoryFiles(in: root) { result[file] = try Data(contentsOf: root.appendingPathComponent(file)) }
        return result
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("amai-qa-ws-\(UUID().uuidString)", isDirectory: true)
}

private func removeReadOnly(_ url: URL) {
    _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", url.path]).waitUntilExit()
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Text

@Suite("QA eval text")
struct QATextTests {
    @Test("normalization makes the timeline line and the search-result line of one entry comparable")
    func normalization() {
        let timeline = "- 09:00–11:00 讨论 Lumen 的同步方案 — 比较了 CloudKit 与自建服务"
        let search = "- [timeline 2026-11-12] 09:00–11:00 讨论 Lumen 的同步方案 比较了 CloudKit 与自建服务"
        let unit = QAEvidence(id: "E1", kind: .timelineEntry, category: .daily, file: "daily/2026-11-12.md", text: "讨论 Lumen 的同步方案 — 比较了 CloudKit 与自建服务")
        #expect(QAText.normalize(timeline).contains(unit.fingerprint))
        #expect(QAText.normalize(search).contains(unit.fingerprint))
        #expect(unit.fingerprint.count == QAText.fingerprintLength)
    }

    @Test("longest common substring and script detection")
    func helpers() {
        #expect(QAText.longestCommonSubstring("我上周修了什么缺陷", "修复lumen的上传缺陷") == 2)
        #expect(QAText.longestCommonSubstring("abcdef", "zcdez") == 3)
        #expect(QAText.script(of: "我那天做了什么？") == "zh")
        #expect(QAText.script(of: "What did I decide about sync?") == "en")
        #expect(QAText.script(of: "先週の木曜日に何をしましたか") == "ja")
    }

    @Test("relative date expressions are computed from the fixed now")
    func relativeDates() {
        let zh = QADates.relativeExpressions(for: "2026-11-13", now: now, timeZone: tokyo, language: "zh")
        #expect(zh.contains("6 天前") && zh.contains("上周五"))
        let en = QADates.relativeExpressions(for: "2026-11-18", now: now, timeZone: tokyo, language: "en")
        #expect(en.contains("yesterday") && en.contains("this Wednesday"))
        let ja = QADates.relativeExpressions(for: "2026-11-17", now: now, timeZone: tokyo, language: "ja")
        #expect(ja.contains("一昨日") && ja.contains("今週の火曜日"))
        #expect(QADates.relativeExpressions(for: "2026-11-19", now: now, timeZone: tokyo, language: "zh").isEmpty)
    }
}

// MARK: - Workspace

@Suite("QA eval workspace")
struct QAWorkspaceTests {
    @Test("prepare copies the memory read-only and never touches the source")
    func prepare() throws {
        let memory = try SyntheticMemory()
        defer { memory.cleanup() }
        try memory.write(".hidden.md", "not copied")
        let before = try memory.snapshot()
        let dir = temporaryDirectory()
        defer { removeReadOnly(dir) }
        let workspace = QAWorkspace(root: dir)
        let manifest = try workspace.prepare(from: memory.root)

        #expect(manifest.files.count == 6)
        #expect(try memory.snapshot() == before)
        #expect(try workspace.verifyCopy() == manifest.digest)
        // 副本只读：写入会失败。
        #expect(throws: (any Error).self) { try "x".write(to: workspace.memory.appendingPathComponent("work.md"), atomically: false, encoding: .utf8) }
        #expect(throws: (any Error).self) { try "x".write(to: workspace.memory.appendingPathComponent("new.md"), atomically: false, encoding: .utf8) }
        // 不能重复准备。
        #expect(throws: QAWorkspace.WorkspaceError.self) { try workspace.prepare(from: memory.root) }
    }

    @Test("the workspace may not overlap the memory or protected directories")
    func overlap() throws {
        let memory = try SyntheticMemory()
        defer { memory.cleanup() }
        #expect(throws: QAWorkspace.WorkspaceError.self) {
            try QAWorkspace(root: memory.root.appendingPathComponent("eval")).prepare(from: memory.root)
        }
        let protected = temporaryDirectory()
        #expect(throws: QAWorkspace.WorkspaceError.self) {
            try QAWorkspace(root: protected.appendingPathComponent("eval")).prepare(from: memory.root, protected: [protected])
        }
    }
}

// MARK: - Catalog & plan

@Suite("QA eval plan")
struct QAPlanTests {
    @Test("the catalog reads entries, timeline segments and days through MemoryAPI")
    func catalog() throws {
        let memory = try SyntheticMemory()
        defer { memory.cleanup() }
        let catalog = try EvidenceCatalog.build(root: memory.root, timeZone: tokyo)
        #expect(catalog.days == ["2026-11-12", "2026-11-13", "2026-11-15", "2026-11-16"])
        let decision = try #require(catalog.units.first { $0.text.contains("CloudKit") && $0.kind == .item })
        #expect(decision.file == "work.md" && decision.section == "Lumen" && decision.date == "2026-11-12")
        let segment = try #require(catalog.units.first { $0.kind == .timelineEntry && $0.text.hasPrefix("修复 Lumen") })
        #expect(segment.date == "2026-11-13" && segment.time == "10:00–12:00")
        #expect(segment.text == "修复 Lumen 的上传缺陷 — 离线重连后附件会重复上传")
        #expect(catalog.mentions("cloudkit") && !catalog.mentions("Notion"))
    }

    @Test("the default plan has 100 questions, is reproducible by seed, and picks no-record dates without files")
    func plan() throws {
        #expect(QAQuotas().totalQuestions == 100)
        let memory = try SyntheticMemory()
        defer { memory.cleanup() }
        let catalog = try EvidenceCatalog.build(root: memory.root, timeZone: tokyo)
        var a = QAPlanner(catalog: catalog, now: now, timeZone: tokyo, seed: 7)
        var b = QAPlanner(catalog: catalog, now: now, timeZone: tokyo, seed: 7)
        let slots = a.plan(QAQuotas())
        #expect(slots == b.plan(QAQuotas()))
        // 合成记忆很小，凑不齐 6 组三条相关的追问证据；其余槽位都排得出来。
        let other = slots.filter { $0.type != .followUp }.reduce(0) { $0 + $1.turns }
        #expect(other == 100 - 18)
        #expect(slots.contains { $0.type == .followUp })
        for slot in slots where slot.subtype == "noRecordDate" {
            #expect(!catalog.days.contains(slot.date!))
        }
        for slot in slots where slot.subtype == "ordering" {
            let dates = slot.evidence.compactMap { catalog.unit($0)?.date }
            #expect(dates.count == 2 && dates[0] < dates[1])
        }
        #expect(slots.filter { $0.type == .crossLingual }.allSatisfy { $0.language != "zh" })
        // "什么时候"与"谁先"只用只出现一次的事。
        let singular = Set(a.singularDatedUnits.map(\.id))
        #expect(catalog.units.contains { $0.text.hasPrefix("整理组会幻灯片") && singular.contains($0.id) })
        for slot in slots where slot.subtype == "when" || slot.subtype == "ordering" {
            #expect(slot.evidence.allSatisfy(singular.contains))
        }
    }
}

// MARK: - Generation

/// 出题模型的假实现：按调用顺序返回脚本，并记录收到的提示词。
final class ScriptedQuestionModel: QAQuestionModel, @unchecked Sendable {
    let identifier = "fake:questions"
    let sendsDataOffDevice = true
    private let state: OSAllocatedUnfairLock<(replies: [@Sendable (String) -> String], prompts: [String])>

    init(_ replies: [@Sendable (String) -> String]) {
        state = OSAllocatedUnfairLock(initialState: (replies, []))
    }

    var prompts: [String] { state.withLock { $0.prompts } }

    func generate(system: String, user: String, schemaJSON: String) async throws -> String {
        let reply = state.withLock { s -> (@Sendable (String) -> String)? in
            s.prompts.append(user)
            return s.replies.isEmpty ? nil : s.replies.removeFirst()
        }
        return reply?(user) ?? "{}"
    }
}

private func reply(_ slot: String, _ question: String, answer: String = "答案", absent: [String] = []) -> [String: Any] {
    ["slot": slot, "turns": [["question": question, "answer": answer, "keyPoints": ["要点"]]], "absentTerms": absent]
}

private func json(_ questions: [[String: Any]]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["questions": questions]), as: UTF8.self)
}

@Suite("QA eval generation")
struct QAGenerationTests {
    @Test("copied wording and terms that exist in memory are rejected, retried with the reason, then accepted")
    func validation() async throws {
        let memory = try SyntheticMemory()
        defer { memory.cleanup() }
        try memory.write("finance.md", "# 财务\n\n<!-- amai:memory:begin · x -->\n### 订阅\n- API 密钥 sk-ant-abcdefghijklmnopqrstuvwx 已轮换 <!-- src:2026-11-11 -->\n<!-- amai:memory:end -->")
        let catalog = try EvidenceCatalog.build(root: memory.root, timeZone: tokyo)
        let fact = try #require(catalog.units.first { $0.text.contains("CloudKit") && $0.kind == .item })
        let secret = try #require(catalog.units.first { $0.text.contains("sk-ant") })
        let slots = [
            QASlot(id: "S001", type: .fact, subtype: "document", language: "zh", turns: 1, evidence: [fact.id], context: []),
            QASlot(id: "S002", type: .unanswerable, subtype: "absentEntity", language: "zh", turns: 1, evidence: [], context: [secret.id]),
        ]
        let model = ScriptedQuestionModel([
            { _ in json([
                reply("S001", "我为什么放弃 CloudKit，改用自建同步服务？"),
                reply("S002", "我在 CloudKit 上花了多少钱？", absent: ["CloudKit"]),
            ]) },
            { _ in json([
                reply("S001", "当初同步方案为啥没选苹果自家的云？", answer: "因为要支持 Android（2026-11-12）"),
                reply("S002", "我给 Notion 的团队版付了多少订阅费？", absent: ["Notion"]),
            ]) },
        ])
        var planner = QAPlanner(catalog: catalog, now: now, timeZone: tokyo, seed: 1)
        let output = await QAGenerator(catalog: catalog, model: model, now: now, timeZone: tokyo).run(slots, planner: &planner)

        #expect(output.items.map(\.question) == ["当初同步方案为啥没选苹果自家的云？", "我给 Notion 的团队版付了多少订阅费？"])
        #expect(output.items[0].evidence == [fact.id] && output.items[1].evidence.isEmpty && output.items[1].absentTerms == ["Notion"])
        #expect(output.items.allSatisfy { $0.maxOverlap <= 8 })
        #expect(output.rejections["copied wording"] == 1 && output.rejections["not absent"] == 1)
        #expect(model.prompts.count == 2 && model.prompts[1].contains("previous attempts"))
        // 凭据在发出之前被脱敏；整份记忆里其他条目没有被发出。
        #expect(!model.prompts.joined().contains("sk-ant-abcdefghijklmnopqrstuvwx"))
        #expect(output.egress.redactions >= 1)
        #expect(output.egress.evidenceUnitsSent == 2 && output.egress.evidenceUnitsTotal == catalog.units.count)
        #expect(!model.prompts.joined().contains("多模态检索"))
    }

    @Test("relative-date questions must use a given expression and no absolute date; slots that keep failing are reported")
    func relativeDate() async throws {
        let memory = try SyntheticMemory()
        defer { memory.cleanup() }
        let catalog = try EvidenceCatalog.build(root: memory.root, timeZone: tokyo)
        let unit = try #require(catalog.units.first { $0.text.hasPrefix("修复 Lumen") })
        let slot = QASlot(id: "S001", type: .temporal, subtype: "relativeDate", language: "zh", turns: 1, evidence: [unit.id], context: [])
        let model = ScriptedQuestionModel([
            { prompt in
                #expect(prompt.contains("\"上周五\""))
                return json([reply("S001", "我 2026-11-13 那天修了哪个毛病？")])
            },
            { _ in json([reply("S001", "上周五我在 Lumen 里主要处理了什么毛病？")]) },
        ])
        var planner = QAPlanner(catalog: catalog, now: now, timeZone: tokyo, seed: 1)
        let output = await QAGenerator(catalog: catalog, model: model, now: now, timeZone: tokyo).run([slot], planner: &planner)
        #expect(output.items.count == 1 && output.items[0].question.hasPrefix("上周五"))

        var options = QAGenerator.Options()
        options.retries = 0
        let silent = ScriptedQuestionModel([])
        let failed = await QAGenerator(catalog: catalog, model: silent, now: now, timeZone: tokyo, options: options).run([slot], planner: &planner)
        #expect(failed.items.isEmpty && failed.unfilled.count == 1)
    }
}

// MARK: - Runner

/// 回答模型的假实现：每次回复固定文字，并记录收到的请求。
final class EchoChatModel: ChatModel, @unchecked Sendable {
    let identifier = "fake:answer"
    let sendsDataOffDevice = false
    let supportsImages = false
    let supportsTools = false
    let replies: [String]
    private let state = OSAllocatedUnfairLock(initialState: (count: 0, requests: [ChatRequest]()))

    init(_ replies: [String]) { self.replies = replies }

    var requests: [ChatRequest] { state.withLock { $0.requests } }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let text = state.withLock { s -> String in
            s.requests.append(request)
            defer { s.count += 1 }
            return s.count < replies.count ? replies[s.count] : "ok"
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.yield(.finished(ChatUsage()))
            continuation.finish()
        }
    }
}

private func dataset(_ catalog: EvidenceCatalog, items: [QAItem]) -> QADataset {
    QADataset(
        createdAt: now, now: now, timeZone: tokyo.identifier, memoryDigest: "d", seed: 1,
        evidence: catalog.units, items: items, egress: QAEgress(), unfilledSlots: 0
    )
}

private func item(_ id: String, _ conversation: String, turn: Int = 0, type: QAQuestionType = .fact, _ question: String, evidence: [String]) -> QAItem {
    QAItem(
        id: id, conversation: conversation, turn: turn, type: type, subtype: "x", language: "zh", question: question,
        expectedAnswer: "a", keyPoints: ["a"], evidence: evidence, context: [], absentTerms: [], maxOverlap: 0
    )
}

@Suite("QA eval runner")
struct QARunnerTests {
    @Test("questions go through AssistantSession; recall is measured on the real prompt and accumulates within a conversation")
    func run() async throws {
        let memory = try SyntheticMemory()
        defer { memory.cleanup() }
        let before = try memory.snapshot()
        let catalog = try EvidenceCatalog.build(root: memory.root, timeZone: tokyo)
        let upload = try #require(catalog.units.first { $0.text.hasPrefix("修复 Lumen") })
        let run = try #require(catalog.units.first { $0.text.hasPrefix("健身房跑步") })
        let kyoto = try #require(catalog.units.first { $0.text.hasPrefix("预订京都旅馆") })
        let data = dataset(catalog, items: [
            item("Q001", "C001", "11 月 13 日我修了什么问题？", evidence: [upload.id]),
            item("Q002", "C001", turn: 1, type: .followUp, "那天下午还做了什么？", evidence: [upload.id, run.id]),
            item("Q003", "C002", "我订的旅馆是在哪个城市？", evidence: [kyoto.id]),
        ])
        let model = EchoChatModel(["修复了重复上传（2026-11-13）。", "去跑步了。", "京都。"])
        let index = MemoryIndex(
            root: memory.root,
            database: try MemoryIndexDatabase(path: memory.root.appendingPathComponent("index.sqlite").path), timeZone: tokyo
        )
        let api = MemoryAPI(root: memory.root, index: index, access: .all, timeZone: tokyo)
        let session = AssistantSession(
            model: model, memory: api, live: nil, builder: ContextBuilder(language: "Chinese", timeZone: tokyo),
            clock: QAFixedClock(date: now)
        )
        var answers: [QAAnswer] = []
        try await QARunner(dataset: data, session: session).run(record: { answers.append($0) })

        #expect(answers.map(\.item) == ["Q001", "Q002", "Q003"])
        #expect(answers.map(\.answer) == ["修复了重复上传（2026-11-13）。", "去跑步了。", "京都。"])
        #expect(answers.allSatisfy { $0.error == nil })
        // 第一问按日期取了整天的时间线：两条证据都已在提示词里；追问沿用。
        #expect(answers[0].recalledEvidence == [upload.id])
        #expect(answers[0].memoryShown.contains("Timeline for 2026-11-13"))
        #expect(Set(answers[1].recalledEvidence) == [upload.id, run.id])
        #expect(answers[0].sources.contains("daily/2026-11-13.md##2026-11-13"))
        #expect(answers[0].sourceMatchedEvidence == [upload.id])
        // 新的对话从头开始：第三问的请求里没有前两问。
        let third = try #require(model.requests.last)
        #expect(third.messages.count == 1 && third.messages[0].text.hasSuffix("我订的旅馆是在哪个城市？"))
        #expect(third.messages[0].text.contains("Time: 2026-11-19 12:00 (Thu)"))
        #expect(third.tools.isEmpty)
        #expect(try memory.snapshot().filter { $0.key.hasSuffix(".md") } == before)
    }

    @Test("daily evidence counts as recalled only when it appears under its own day")
    func datedRecall() {
        let routine = QAEvidence(id: "E1", kind: .timelineEntry, category: .daily, file: "daily/2026-11-11.md", date: "2026-11-11", text: "回复邮件和 Slack")
        let note = QAEvidence(id: "E2", kind: .item, category: .work, file: "work.md", text: "每周五整理一次进度")
        let digest = QAEvidence(id: "E3", kind: .daySummary, category: .daily, file: "daily/2026-11-12.md", date: "2026-11-12", text: "主要在推进 Lumen 的同步")
        let otherDays = "Entries found for this question, most relevant first:\n- [timeline 2026-11-16] 15:00–16:30 回复邮件和 Slack\n- [work › Work] 每周五整理一次进度"
        #expect(QARunner.recalled([routine, note], in: otherDays) == ["E2"])
        let sameDay = otherDays + "\n\nTimeline for 2026-11-11:\nSummary: 活跃 5 小时。\n\n- 主要在做别的\n- 15:00–16:30 回复邮件和 Slack"
        #expect(QARunner.recalled([routine, note], in: sameDay) == ["E1", "E2"])
        let range = "Daily records from 2026-11-10 to 2026-11-12, newest first:\n- 2026-11-12: 活跃 6 小时。 主要在推进 Lumen 的同步\n- 2026-11-11: 回复邮件和 Slack"
        #expect(QARunner.recalled([routine, digest], in: range) == ["E1", "E3"])
        #expect(QARunner.recalled([routine], in: "- [timeline 2026-11-12] 回复邮件和 Slack\n- 回复邮件和 Slack").isEmpty)
    }

    @Test("memory block extraction")
    func memoryBlock() {
        let prompt = ContextBuilder(language: "Chinese").userMessage(contextBlock: "<context>\n</context>", memory: "- a\n- b", screenNote: nil, question: "q")
        #expect(QARunner.memoryBlock(in: prompt) == "- a\n- b")
        #expect(QARunner.memoryBlock(in: "User's message:\nq").isEmpty)
    }
}

// MARK: - Judge & report

@Suite("QA eval judge and report")
struct QAJudgeReportTests {
    /// 评分规则是固定的：改动它必须同时提升版本号并更新这里的摘要，不能为了成绩悄悄修改。
    @Test("the rubric is pinned")
    func rubricPinned() {
        #expect(QARubric.version == "qa-rubric-v1")
        #expect(QARubric.sha256 == "02fc8811577c49a6179ffe5640cb8f0b91f14f7baba51093830fd58b324d3443")
    }

    @Test("judge output is parsed strictly and retried once")
    func judge() async {
        let item = item("Q001", "C001", "q", evidence: [])
        let good = EchoChatModel(["Sure:\n```json\n{\"verdict\": \"partial\", \"abstained\": false, \"unsupported_claims\": [\"去了大阪\"], \"rationale\": \"r\"}\n```"])
        let j = await QAJudge(model: good).judge(item: item, evidence: [], context: [], previous: [], memoryShown: "", answer: "a")
        #expect(j.verdict == .partial && j.abstained == false && j.unsupportedClaims == ["去了大阪"] && j.isUngrounded)
        #expect(j.rubric == QARubric.id)
        #expect(good.requests.first?.temperature == 0)

        // 自相矛盾：可回答的题说没有记录却判 correct → 按规则第 2 条改为 incorrect，并记录改正。
        let contradictory = EchoChatModel(["{\"verdict\": \"correct\", \"abstained\": true, \"unsupported_claims\": [], \"rationale\": \"r\"}"])
        let fixed = await QAJudge(model: contradictory).judge(item: item, evidence: [], context: [], previous: [], memoryShown: "", answer: "没有记录")
        #expect(fixed.verdict == .incorrect && fixed.adjustment != nil)
        var unanswerable = item
        unanswerable.type = .unanswerable
        let kept = await QAJudge(model: EchoChatModel(["{\"verdict\": \"correct\", \"abstained\": true, \"unsupported_claims\": [], \"rationale\": \"r\"}"]))
            .judge(item: unanswerable, evidence: [], context: [], previous: [], memoryShown: "", answer: "没有记录")
        #expect(kept.verdict == .correct && kept.adjustment == nil)

        let bad = EchoChatModel(["looks right", "{\"verdict\": \"great\"}"])
        let failed = await QAJudge(model: bad).judge(item: item, evidence: [], context: [], previous: [], memoryShown: "", answer: "a")
        #expect(failed.verdict == nil && failed.error == "unparseable" && bad.requests.count == 2)
    }

    @Test("failures are classified; the summary contains no memory text")
    func report() throws {
        let unit = QAEvidence(id: "E1", kind: .item, category: .work, file: "work.md", section: "Lumen", date: "2026-11-12", text: "放弃 CloudKit 改用自建同步服务")
        let items = [
            item("Q1", "C1", "为什么不用苹果的云？", evidence: ["E1"]),
            item("Q2", "C2", "同步方案定了吗？", evidence: ["E1"]),
            item("Q3", "C3", "那个旅馆在哪？", evidence: ["E1"]),
            QAItem(id: "Q4", conversation: "C4", turn: 0, type: .unanswerable, subtype: "absentEntity", language: "zh",
                   question: "我买的 Notion 会员多少钱？", expectedAnswer: "没有记录", keyPoints: ["没有记录"], evidence: [],
                   context: [], absentTerms: ["Notion"], maxOverlap: 2),
        ]
        let data = QADataset(createdAt: now, now: now, timeZone: tokyo.identifier, memoryDigest: "d", seed: 1,
                             evidence: [unit], items: items, egress: QAEgress(), unfilledSlots: 0)
        func answer(_ id: String, recalled: [String], error: String? = nil) -> QAAnswer {
            var timings = QAAnswer.Timings()
            timings.firstTextMs = 200
            timings.totalMs = 900
            return QAAnswer(item: id, answer: "回答里提到 CloudKit", error: error, sources: [], memoryShown: "- [work › Lumen] 放弃 CloudKit 改用自建同步服务",
                            recalledEvidence: recalled, sourceMatchedEvidence: recalled, timings: timings)
        }
        func judgment(_ id: String, _ verdict: QAJudgment.Verdict, abstained: Bool = false, claims: [String] = []) -> QAJudgment {
            QAJudgment(item: id, verdict: verdict, abstained: abstained, unsupportedClaims: claims, rationale: "r",
                       adjustment: nil, error: nil, judge: "fake:judge", rubric: QARubric.id)
        }
        let records = QAReport.records(
            dataset: data,
            answers: [answer("Q1", recalled: ["E1"]), answer("Q2", recalled: []), answer("Q3", recalled: [], error: "Boom"), answer("Q4", recalled: [])],
            judgments: [judgment("Q1", .correct), judgment("Q2", .incorrect, abstained: true), judgment("Q4", .incorrect, claims: ["花了 98 元"])]
        )
        #expect(records.map(\.failures) == [[], ["retrieval-miss", "false-abstain"], ["pipeline-error"], ["unanswerable-answered", "ungrounded"]])
        let summary = QAReport.summary(dataset: data, records: records, answerer: "a", judge: "j", embedder: "e", notes: [])
        #expect(summary.overall.correct == .init(1, of: 3))
        #expect(summary.answerable.fullRecall == .init(1, of: 2))
        #expect(summary.answerable.evidenceRecall == 0.5)
        #expect(summary.unanswerableAnswered == .init(1, of: 1))
        #expect(summary.overall.ungrounded == .init(1, of: 3))
        #expect(summary.falseAbstention == .init(1, of: 2))
        #expect(summary.overall.pipelineErrors == 1)
        #expect(summary.latency["firstTextMs"]?.p50 == 200)
        #expect(summary.rubricConsistent)

        let encoded = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
            + QAReport.metricsMarkdown(summary)
        for text in ["CloudKit", "苹果", "Notion", "98 元", "旅馆", "同步"] {
            #expect(!encoded.contains(text), "summary leaks \(text)")
        }
        let full = QAReport.markdown(summary: summary, records: records, dataset: data)
        #expect(full.contains("### retrieval-miss (1)") || full.contains("### retrieval-miss（1）") || full.contains("retrieval-miss"))
        #expect(full.contains("我买的 Notion 会员多少钱？"))
    }
}

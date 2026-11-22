import AmaiAssistant
import AmaiCore
import AmaiExtraction
import AmaiInference
import AmaiMemory
import AmaiPerception
import AmaiQAEval
import Foundation

/// 端到端：脚本化的设备活动 → 正式采集（ScreenCapturer、原始缓冲）→ 正式抽取（Vision OCR + 本地视觉模型切分）
/// → 写入 daily 与记忆整理（本地模型）→ 索引与检索 → 助手作答 → 独立 Judge。
///
/// 除了最终答案，还按关键词追踪每道题的信息在哪一步丢失（屏幕 → OCR → 片段 → 记忆文件 → 提示词 → 答案），
/// 并检查口令与密钥在任何产物中都不出现。全部是合成数据，只用本机模型。
public enum EndToEndSuite {
    public static let id = "e2e"

    struct Stage: Codable {
        var question: String
        var screen: Bool
        var ocr: Bool
        var segments: Bool
        var memoryFiles: Bool
        var prompt: Bool
        var verdict: String?
    }

    public static func run(_ ctx: BenchmarkContext) async -> SuiteResult {
        let title = "端到端"
        guard let vision = ctx.models.vision else { return .skipped(id, title, reason: "没有可用的视觉模型（抽取）") }
        guard let memoryTag = ctx.models.memory else { return .skipped(id, title, reason: "没有可用的记忆整理模型") }
        guard let answerTag = ctx.models.answer, let judgeTag = ctx.models.judge else {
            return .skipped(id, title, reason: "没有可用的作答或 Judge 模型")
        }
        let started = Date()
        var result = SuiteResult(id: id, title: title)
        result.models = ["vision": vision, "memory": memoryTag, "answer": answerTag, "judge": judgeTag, "embedder": ctx.models.embedder ?? "none"]
        let work = ctx.scratch("e2e")
        do {
            let scriptURL = ctx.fixture("activity-day.json")
            let script = try ActivityScript.load(scriptURL)
            result.datasets = [ctx.dataset("activity-day", scriptURL)]
            let tz = script.tz

            // 1. 采集
            ctx.log("端到端：采集")
            let raw = work.appendingPathComponent("raw", isDirectory: true)
            let trace = try await SimulatedCapture.run(script, root: raw)
            let capture = PerceptionSuite.coverageMetrics(trace, script: script).filter { ["perception.capture.timeCoverage", "perception.capture.privacyLeak"].contains($0.id) }
            result.metrics += capture.map { m in var m = m; m.id = m.id.replacingOccurrences(of: "perception.", with: "e2e."); return m }

            // 2. 抽取
            ctx.log("端到端：抽取（\(vision)）")
            let end = script.end
            let clock = FixedBenchmarkClock(date: end.addingTimeInterval(120))
            let spool = try RawSpool(root: raw, limits: .default, clock: clock, timeZone: tz)
            let store = try ExtractionStore(root: work.appendingPathComponent("extracted", isDirectory: true), timeZone: tz)
            try await store.saveState(.init(processedUntil: script.start.addingTimeInterval(-1)))
            let provider = MLXModelProvider(modelTag: vision)
            var options = ExtractionPipeline.Options()
            options.maxBatchesPerRun = 1
            let pipeline = ExtractionPipeline(
                dependencies: .init(reader: SpoolReader(spool: spool, timeZone: tz), model: provider, ocr: VisionTextRecognizer(), store: store, clock: clock, timeZone: tz),
                options: options
            )
            let extractionStarted = Date()
            while await pipeline.runOnce(force: true) > 0 {}
            let status = await pipeline.status
            let extractionSeconds = Date().timeIntervalSince(extractionStarted)
            await provider.unload(reason: "benchmark e2e extraction finished")
            if let error = status.lastError { result.notes.append("抽取停止原因：\(status.state.rawValue) · \(error)") }
            let segments = await store.segments(on: script.day).sorted { $0.timeRange.start < $1.timeRange.start }
            let observations = await store.observations(on: script.day)
            result.metrics += extractionMetrics(script: script, segments: segments, observations: observations, status: status, seconds: extractionSeconds)

            // 3. 记忆
            ctx.log("端到端：记忆整理（\(memoryTag)）")
            let memoryRoot = work.appendingPathComponent("memory", isDirectory: true)
            let memoryStore = try MemoryStore(root: memoryRoot, timeZone: tz)
            _ = try await memoryStore.writeDailyTimeline(day: script.day, segments: segments)
            let memoryModel = BenchmarkMemoryModel(provider: MLXModelProvider(modelTag: memoryTag))
            let consolidator = Consolidator(
                store: memoryStore, source: StoreSegmentSource(store: store), model: memoryModel,
                snapshots: SnapshotStore(root: work.appendingPathComponent("snapshots")), stateURL: work.appendingPathComponent("consolidation.json"),
                clock: FixedBenchmarkClock(date: script.day.addingTimeInterval(86_400 + 5 * 3600)), timeZone: tz
            )
            do {
                let report = try await consolidator.consolidateDay(script.day)
                result.notes.append("整理：路由 \(report.routed.map(\.rawValue).joined(separator: ",").isEmpty ? "无" : report.routed.map(\.rawValue).joined(separator: ","))；被拒绝的操作 \(report.rejected.count) 条")
            } catch {
                result.notes.append("记忆整理失败：\(error)（继续用只有时间线的记忆作答）")
            }
            await memoryModel.provider.unload(reason: "benchmark e2e consolidation finished")
            let memoryText = allText(in: memoryRoot, extension: "md")

            // 4. 检索与作答
            ctx.log("端到端：作答（\(answerTag)）与评分（\(judgeTag)）")
            let index = MemoryIndex(root: memoryRoot, database: try MemoryIndexDatabase(path: work.appendingPathComponent("index.sqlite").path), timeZone: tz)
            try await index.refresh()
            var embedder: MLXTextEmbedder?
            if let tag = ctx.models.embedder {
                let e = MLXTextEmbedder(modelTag: tag)
                if e.isAvailable {
                    while try await index.embedPending(using: e) > 0 {}
                    embedder = e
                }
            }
            let dataset = qaDataset(script, digest: SyntheticCorpus.digest(memoryRoot))
            let api = MemoryAPI(root: memoryRoot, index: index, access: MemoryAccess(categories: Set(BenchmarkDefaults.assistantCategories)), embedder: embedder, timeZone: tz)
            let chat = MLXChatModel(modelTag: answerTag)
            let session = AssistantSession(
                model: chat, memory: api, live: nil, builder: ContextBuilder(language: BenchmarkDefaults.answerLanguage),
                clock: QAFixedClock(date: script.day.addingTimeInterval(18 * 3600))
            )
            var answers: [QAAnswer] = []
            try await QARunner(dataset: dataset, session: session).run(record: { answers.append($0) })
            await MLXModelProvider(modelTag: answerTag).unload(reason: "benchmark e2e answering finished")
            await embedder?.unload()
            let judge = MLXTextChatModel(modelTag: judgeTag)
            var judgments: [QAJudgment] = []
            await QAJudge(model: judge).judgeAll(dataset: dataset, answers: Dictionary(answers.map { ($0.item, $0) }, uniquingKeysWith: { _, b in b })) {
                judgments.append($0)
            }
            await judge.unload()
            let records = QAReport.records(dataset: dataset, answers: answers, judgments: judgments)
            let summary = QAReport.summary(dataset: dataset, records: records, answerer: chat.identifier, judge: judge.identifier, embedder: embedder?.identifier ?? "none", notes: [])
            // 证据召回按原文指纹计算，而端到端的"证据"是脚本里的屏幕文字，模型会改写，指纹对不上：不报告。
            result.metrics += QASuite.metrics(summary, records: records, prefix: "e2e.qa")
                .filter { !$0.id.hasSuffix("evidenceRecall") && !$0.id.hasSuffix("correctWhenFullyRecalled") }

            // 5. 信息漏斗与隐私
            let ocrText = observations.filter { $0.kind == .fact }.map(\.content).joined(separator: "\n")
            let segmentText = segments.map { "\($0.title) \($0.summary)" }.joined(separator: "\n")
            var stages: [Stage] = []
            for q in script.questions where !q.anchors.isEmpty {
                let screenText = trace.ticks.filter { $0.outcome == "captured" && q.activities.contains($0.activity) }
                    .compactMap { script.state(at: $0.time)?.spec.visibleText.joined(separator: "\n") }.joined(separator: "\n")
                func has(_ text: String) -> Bool { q.anchors.allSatisfy { TextMetrics.contains(text, $0) } }
                let answer = answers.first { $0.item == q.id }
                stages.append(Stage(
                    question: q.id, screen: has(screenText), ocr: has(ocrText), segments: has(segmentText), memoryFiles: has(memoryText),
                    prompt: has(answer?.memoryShown ?? ""), verdict: judgments.first { $0.item == q.id }?.verdict?.rawValue
                ))
            }
            result.metrics += funnelMetrics(stages)
            let artifacts: [(String, String)] = [
                ("OCR 观察", ocrText), ("活动片段", segmentText), ("记忆文件", memoryText),
                ("提示词", answers.map(\.memoryShown).joined(separator: "\n")), ("回答", answers.map(\.answer).joined(separator: "\n")),
                ("原始缓冲元数据", allText(in: raw, extension: "jsonl") + allText(in: raw, extension: "json")),
            ]
            var leaks: [String] = []
            for (name, canary) in script.canaries.sorted(by: { $0.key < $1.key }) {
                for (artifact, text) in artifacts where TextMetrics.contains(text, canary) { leaks.append("\(name) → \(artifact)") }
            }
            result.metrics.append(Metric(
                id: "e2e.privacy.canaryLeaks", name: "口令 / 密钥 / 暂停期间内容出现在产物中的次数", value: Double(leaks.count), unit: .count,
                direction: .lowerIsBetter, groundTruth: .synthetic,
                note: "检查 \(script.canaries.count) 个标记 × \(artifacts.count) 类产物（视频帧本身不检查）" + (leaks.isEmpty ? "" : "：" + leaks.joined(separator: "，"))
            ))

            try ctx.writeDetail("e2e-funnel.json", stages)
            try ctx.writeDetail("e2e-segments.md", text: segments.map { s in
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                f.timeZone = tz
                return "- \(f.string(from: s.timeRange.start))–\(f.string(from: s.timeRange.end)) [\(s.category.rawValue)] \(s.title)（\(s.provider)，conf \(String(format: "%.2f", s.confidence))）\n  \(s.summary)"
            }.joined(separator: "\n") + "\n")
            try ctx.writeDetail("e2e-qa-records.jsonl", text: try BenchmarkFiles.lines(records))
            try ctx.writeDetail("e2e-memory.md", text: memoryText)
            result.details = ["details/e2e-funnel.json", "details/e2e-segments.md", "details/e2e-qa-records.jsonl", "details/e2e-memory.md"]
            result.notes.append("一小时的合成活动，规模小：每个比例的分母只有个位数到几十，适合发现退化，不适合精确比较。")
        } catch {
            result.status = .failed
            result.reason = "\(error)"
        }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    // MARK: - Extraction metrics

    static func extractionMetrics(script: ActivityScript, segments: [ActivitySegment], observations: [Observation], status: ExtractionStatus, seconds: Double) -> [Metric] {
        let policy = ExclusionListPolicy.defaultExcludedBundleIds
        // 有屏幕内容、用户在场、时长足以成段（≥ 3 分钟，抽取会把更短的片段并入相邻片段）的活动。
        let scored = script.activities.filter { a in
            script.expected(a, excludedBundleIds: policy) == .capture && a.idle != true && script.range(a).duration >= 180
        }
        var matched = 0, categoryHit = 0, categoryTotal = 0, appHit = 0
        var boundaryErrors: [Double] = []
        for a in scored {
            let r = script.range(a)
            let best = segments.max { overlap($0.timeRange, r) < overlap($1.timeRange, r) }
            guard let s = best else { continue }
            let union = max(s.timeRange.end, r.end).timeIntervalSince(min(s.timeRange.start, r.start))
            let iou = union > 0 ? overlap(s.timeRange, r) / union : 0
            if iou >= 0.5 {
                matched += 1
                boundaryErrors.append((abs(s.timeRange.start.timeIntervalSince(r.start)) + abs(s.timeRange.end.timeIntervalSince(r.end))) / 2 / 60)
                if s.apps.contains(a.bundleId) || s.apps.contains(a.app) { appHit += 1 }
                if let c = a.category {
                    categoryTotal += 1
                    if s.category == c { categoryHit += 1 }
                }
            }
        }
        // 不在场（无键鼠输入）的时段应被识别为离开。
        let idle = script.activities.filter { $0.idle == true && script.expected($0, excludedBundleIds: policy) == .capture }
        let idleHit = idle.filter { a in
            let r = script.range(a)
            let covering = segments.filter { overlap($0.timeRange, r) >= r.duration * 0.5 }
            return covering.contains { $0.category == .idle }
        }.count
        // 抽取中的 OCR：与当时屏幕上的文字比较。
        var errors = 0, length = 0
        for o in observations where o.kind == .fact && o.provider == "vision-ocr" {
            guard let state = script.state(at: o.timeRange.start) else { continue }
            let e = TextMetrics.characterErrors(reference: state.spec.visibleText.joined(separator: "\n"), hypothesis: o.content)
            errors += e.errors
            length += e.length
        }
        return [
            .ratio("e2e.timeline.activityMatch", "时间线准确率（活动与片段 IoU ≥ 0.5）", matched, scored.count, direction: .higherIsBetter, gt: .synthetic,
                   note: "只评价 ≥ 3 分钟、用户在场、应采集的活动"),
            Metric(id: "e2e.timeline.boundaryError", name: "片段边界平均误差", value: boundaryErrors.isEmpty ? nil : boundaryErrors.reduce(0, +) / Double(boundaryErrors.count),
                   unit: .minutes, direction: .lowerIsBetter, groundTruth: .synthetic),
            .ratio("e2e.timeline.app", "片段应用归属正确", appHit, matched, direction: .higherIsBetter, gt: .synthetic),
            .ratio("e2e.timeline.category", "片段类别与期望一致", categoryHit, categoryTotal, direction: .higherIsBetter, gt: .synthetic,
                   note: "类别是人工给出的期望，有主观成分"),
            .ratio("e2e.timeline.idle", "离开时段识别为 idle", idleHit, idle.count, direction: .higherIsBetter, gt: .synthetic),
            Metric(id: "e2e.ocr.cer", name: "抽取中的 OCR 字符错误率", value: length == 0 ? nil : Double(errors) / Double(length),
                   numerator: Double(errors), denominator: Double(length), unit: .ratio, direction: .lowerIsBetter, groundTruth: .synthetic,
                   note: "含脱敏替换与存储截断的影响"),
            Metric(id: "e2e.extraction.seconds", name: "抽取耗时（一小时活动）", value: seconds, unit: .seconds, direction: .lowerIsBetter, groundTruth: .measured),
            Metric(id: "e2e.extraction.segments", name: "片段数", value: Double(segments.count), unit: .count, direction: .info, groundTruth: .measured),
            Metric(id: "e2e.extraction.fallbackBatches", name: "兜底窗口数（模型失败）", value: Double(status.fallbackBatches), unit: .count, direction: .lowerIsBetter, groundTruth: .measured),
        ]
    }

    static func overlap(_ a: TimeRange, _ b: TimeRange) -> TimeInterval {
        max(0, min(a.end, b.end).timeIntervalSince(max(a.start, b.start)))
    }

    static func funnelMetrics(_ stages: [Stage]) -> [Metric] {
        let n = stages.count
        func count(_ f: (Stage) -> Bool) -> Int { stages.filter(f).count }
        return [
            .ratio("e2e.funnel.screen", "信息保留·屏幕被采到", count(\.screen), n, direction: .higherIsBetter, gt: .synthetic),
            .ratio("e2e.funnel.ocr", "信息保留·OCR", count { $0.screen && $0.ocr }, n, direction: .higherIsBetter, gt: .anchor),
            .ratio("e2e.funnel.segments", "信息保留·活动片段", count(\.segments), n, direction: .higherIsBetter, gt: .anchor,
                   note: "片段由模型改写，关键词不出现不一定是丢了信息"),
            .ratio("e2e.funnel.memory", "信息保留·记忆文件", count(\.memoryFiles), n, direction: .higherIsBetter, gt: .anchor),
            .ratio("e2e.funnel.prompt", "信息保留·进入提示词", count(\.prompt), n, direction: .higherIsBetter, gt: .anchor),
            .ratio("e2e.funnel.answer", "信息保留·回答正确（Judge）", count { $0.verdict == "correct" }, n, direction: .higherIsBetter, gt: .judge),
        ]
    }

    // MARK: - Helpers

    static func qaDataset(_ script: ActivityScript, digest: String) -> QADataset {
        var evidence: [QAEvidence] = []
        for a in script.activities {
            let text = a.screens.map { $0.spec.visibleText.joined(separator: "；") }.joined(separator: " / ")
            evidence.append(QAEvidence(id: a.id, kind: .userNote, category: .daily, file: "script:\(a.app)", date: script.date, time: "\(a.start)–\(a.end)", text: text))
        }
        let items = script.questions.map { q in
            QAItem(
                id: q.id, conversation: q.id, turn: 1, type: QAQuestionType(rawValue: q.type) ?? .fact, subtype: q.subtype, language: q.language,
                question: q.question, expectedAnswer: q.expectedAnswer, keyPoints: q.keyPoints,
                // 无法回答的题不给 Judge 看被排除 / 暂停时段的屏幕内容：那些内容按设计不在记忆里。
                evidence: q.type == "unanswerable" ? [] : q.activities, context: [],
                absentTerms: q.absentTerms ?? [], maxOverlap: 0
            )
        }
        var egress = QAEgress()
        egress.generator = "hand-written (\(script.name))"
        return QADataset(createdAt: script.day, now: script.day.addingTimeInterval(18 * 3600), timeZone: script.timeZone, memoryDigest: digest, seed: 0,
                         evidence: evidence, items: items, egress: egress, unfilledSlots: 0)
    }

    static func allText(in root: URL, extension ext: String) -> String {
        var text = ""
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == ext {
                text += ((try? String(contentsOf: url, encoding: .utf8)) ?? "") + "\n"
            }
        }
        return text
    }
}

/// 抽取层的存储作为记忆层的片段来源（与 App 的 ExtractionSegmentSource 相同）。
struct StoreSegmentSource: SegmentSource {
    let store: ExtractionStore
    func daysWithUpdates(after: Date?, endingOn: Date, days: Int) async -> [(day: Date, latestUpdate: Date)] {
        await store.daysWithUpdates(after: after, endingOn: endingOn, days: days)
    }
    func segments(on day: Date) async -> [ActivitySegment] { await store.segments(on: day) }
    func observations(on day: Date) async -> [Observation] { await store.observations(on: day) }
}

import AmaiAssistant
import AmaiCore
import AmaiInference
import AmaiMemory
import AmaiQAEval
import Foundation

/// 助手默认可读的分区（与 App 的 AssistantConfiguration.defaultCategories 一致）。
enum BenchmarkDefaults {
    static let assistantCategories: [MemoryCategory] = [.general, .work, .goals, .daily]
    static let answerLanguage = "Chinese"
}

/// 在合成语料上建索引（关键词，有向量模型时补算向量）。
struct PreparedCorpus {
    var corpus: SyntheticCorpus
    var index: MemoryIndex
    var embedder: MLXTextEmbedder?
    var embedded: Int

    static func prepare(_ ctx: BenchmarkContext, scratch: String) async throws -> PreparedCorpus {
        let root = ctx.scratch(scratch)
        let corpus = try await SyntheticCorpus.build(
            corpus: ctx.fixture("synthetic-memory.json"), questions: ctx.fixture("synthetic-qa.json"),
            at: root.appendingPathComponent("memory", isDirectory: true)
        )
        let index = MemoryIndex(
            root: corpus.root, database: try MemoryIndexDatabase(path: root.appendingPathComponent("index.sqlite").path),
            timeZone: corpus.timeZone
        )
        try await index.refresh()
        var embedder: MLXTextEmbedder?
        var embedded = 0
        if let tag = ctx.models.embedder {
            let e = MLXTextEmbedder(modelTag: tag)
            if e.isAvailable {
                while true {
                    let n = try await index.embedPending(using: e)
                    embedded += n
                    if n == 0 { break }
                }
                embedder = e
            }
        }
        return PreparedCorpus(corpus: corpus, index: index, embedder: embedder, embedded: embedded)
    }

    func api(embedder: (any TextEmbedder)?) -> MemoryAPI {
        MemoryAPI(
            root: corpus.root, index: index, access: MemoryAccess(categories: Set(BenchmarkDefaults.assistantCategories)),
            embedder: embedder, timeZone: corpus.timeZone
        )
    }

    var datasets: (BenchmarkContext) -> [DatasetRef] {
        { ctx in [ctx.dataset("synthetic-memory", ctx.fixture("synthetic-memory.json")), ctx.dataset("synthetic-qa", ctx.fixture("synthetic-qa.json"))] }
    }
}

// MARK: - Retrieval

public enum RetrievalSuite {
    public static let id = "retrieval"

    public static func run(_ ctx: BenchmarkContext) async -> SuiteResult {
        let started = Date()
        var result = SuiteResult(id: id, title: "记忆检索")
        do {
            let prepared = try await PreparedCorpus.prepare(ctx, scratch: "retrieval")
            let corpus = prepared.corpus
            result.datasets = prepared.datasets(ctx)
            let embedderName = prepared.embedder?.identifier ?? "none (keyword only)"
            result.models["embedder"] = embedderName
            if prepared.embedder == nil {
                result.notes.append("没有向量模型：hybrid 与 pipeline 退回纯关键词检索，与 keyword 相同")
            }
            ctx.log("检索：\(corpus.retrievalDataset.items.count) 道题，证据条目 \(corpus.catalog.units.count) 条，向量块 \(prepared.embedded)")
            let runner = QARetrievalRunner(
                dataset: corpus.retrievalDataset, matcher: QAUnitMatcher(corpus.catalog.units),
                hybrid: prepared.api(embedder: prepared.embedder), keyword: prepared.api(embedder: nil),
                builder: ContextBuilder(language: BenchmarkDefaults.answerLanguage)
            )
            let runs = try await runner.run()
            let notes = ["合成语料（synthetic-memory.json），GT 按构造已知；可读分区与 App 默认一致：\(BenchmarkDefaults.assistantCategories.map(\.rawValue).joined(separator: ", "))"]
            let (summary, _, misses) = QARetrievalReport.evaluate(
                dataset: corpus.retrievalDataset, gt: corpus.groundTruth, runs: runs, embedder: embedderName, notes: notes
            )
            result.metrics = metrics(summary)
            try ctx.writeDetail("retrieval-summary.json", summary)
            try ctx.writeDetail("retrieval-report.md", text: QARetrievalReport.markdown(summary: summary, misses: misses, runs: runs, catalog: corpus.catalog))
            result.details = ["details/retrieval-summary.json", "details/retrieval-report.md"]
            await prepared.embedder?.unload()
        } catch {
            result.status = .failed
            result.reason = "\(error)"
        }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    static func metrics(_ s: QARetrievalReport.Summary, prefix: String = "retrieval", gt: GroundTruthKind = .synthetic, origin: DataOrigin = .synthetic) -> [Metric] {
        var m: [Metric] = []
        let n = Double(s.scoredQuestions)
        func value(_ id: String, _ name: String, _ v: Double?, _ dir: MetricDirection = .higherIsBetter, unit: MetricUnit = .ratio, note: String? = nil) -> Metric {
            Metric(id: id, name: name, value: v, denominator: unit == .ratio ? n : nil, unit: unit, direction: dir, groundTruth: gt, origin: origin, note: note)
        }
        for (system, label) in [("pipeline", "助手管线（4K 预算）"), ("hybrid", "混合检索"), ("keyword", "纯关键词")] {
            guard let g = s.systems[system] else { continue }
            let p = "\(prefix).\(system)"
            for k in [1, 3, 6, 10] {
                m.append(value("\(p).recall@\(k)", "Recall@\(k)·\(label)", g.recallAtK["@\(k)"]))
            }
            for k in [1, 3, 6] {
                m.append(value("\(p).precision@\(k)", "Precision@\(k)·\(label)", g.precisionAtK["@\(k)"],
                               note: k == 1 ? nil : "每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K"))
            }
            m.append(value("\(p).ndcg@6", "nDCG@6·\(label)", g.ndcgAtK["@6"], unit: .score))
            if system == "pipeline" {
                m.append(value("\(p).evidenceCoverage", "证据覆盖率（所需信息点进入提示词的比例）", g.recallAll))
                m.append(value("\(p).fullCoverage", "证据完整率（所需信息点全部进入提示词）", g.fullAll))
                m.append(Metric(id: "\(p).meanTokens", name: "提示词中记忆的平均 token", value: g.meanTokens, unit: .count, direction: .info, groundTruth: .measured, origin: origin))
            } else {
                m.append(value("\(p).recall@4K", "4K 预算内的证据覆盖率·\(label)", g.recallAtBudget["4K"]))
            }
        }
        // 无法回答 / 与记忆无关的问题：返回了内容的比例越低越好（噪声）。
        for system in ["pipeline", "hybrid"] {
            guard let groups = s.unanswerable[system] else { continue }
            for (subtype, f) in groups.sorted(by: { $0.key < $1.key }) {
                m.append(Metric(
                    id: "\(prefix).\(system).noise.\(subtype)", name: "无关问题仍返回记忆的比例·\(system)·\(subtype)", value: f.anyRetrieved,
                    denominator: Double(f.questions), unit: .ratio, direction: subtype == "falsePremise" ? .info : .lowerIsBetter, groundTruth: gt, origin: origin,
                    note: subtype == "falsePremise" ? "错误前提的题，相关记忆有助于反驳，不算噪声" : nil
                ))
            }
        }
        if let auroc = s.topScoreAUROC["hybrid"] ?? nil {
            m.append(Metric(id: "\(prefix).hybrid.abstainAUROC", name: "第一名得分区分可回答 / 无法回答（AUROC）", value: auroc, unit: .score, direction: .higherIsBetter, groundTruth: gt, origin: origin))
        }
        for system in ["pipeline", "hybrid", "keyword"] {
            if let d = s.latencyMs[system] {
                m.append(Metric(id: "\(prefix).\(system).latency.p50", name: "检索延迟中位数·\(system)", value: d.p50, unit: .milliseconds, direction: .lowerIsBetter, groundTruth: .measured, origin: origin, note: "评测机器上测得"))
            }
        }
        return m
    }
}

// MARK: - QA

public enum QASuite {
    public static let id = "qa"

    public static func run(_ ctx: BenchmarkContext) async -> SuiteResult {
        let started = Date()
        var result = SuiteResult(id: id, title: "AI 问答")
        guard let answerTag = ctx.models.answer else {
            return .skipped(id, "AI 问答", reason: "没有可用的作答模型")
        }
        guard let judgeTag = ctx.models.judge else {
            return .skipped(id, "AI 问答", reason: "没有可用的 Judge 模型：问答正确率需要独立的 Judge 评分")
        }
        do {
            let prepared = try await PreparedCorpus.prepare(ctx, scratch: "qa")
            let dataset = prepared.corpus.qaDataset
            result.datasets = prepared.datasets(ctx)
            result.models = ["answer": answerTag, "judge": judgeTag, "embedder": prepared.embedder?.identifier ?? "none (keyword only)"]

            ctx.log("问答：\(dataset.items.count) 道题，作答 \(answerTag)")
            let model = MLXChatModel(modelTag: answerTag)
            await model.prepare(ChatRequest(system: "warm up", messages: []))
            let session = AssistantSession(
                model: model, memory: prepared.api(embedder: prepared.embedder), live: nil,
                builder: ContextBuilder(language: BenchmarkDefaults.answerLanguage), clock: QAFixedClock(date: dataset.now)
            )
            var answers: [QAAnswer] = []
            try await QARunner(dataset: dataset, session: session, stats: {
                let stats = await model.prefixStats.chat
                return (stats.promptTokens, stats.cachedTokens)
            }).run(record: { answers.append($0) })
            await MLXModelProvider(modelTag: answerTag).unload(reason: "benchmark qa answering finished")
            await prepared.embedder?.unload()

            ctx.log("问答：Judge \(judgeTag)")
            let judgeModel = MLXTextChatModel(modelTag: judgeTag)
            var judgments: [QAJudgment] = []
            await QAJudge(model: judgeModel).judgeAll(
                dataset: dataset, answers: Dictionary(answers.map { ($0.item, $0) }, uniquingKeysWith: { _, b in b })
            ) { judgments.append($0) }
            await judgeModel.unload()

            let records = QAReport.records(dataset: dataset, answers: answers, judgments: judgments)
            let summary = QAReport.summary(
                dataset: dataset, records: records, answerer: model.identifier, judge: judgeModel.identifier,
                embedder: result.models["embedder"]!, notes: ["合成语料与手写题目（synthetic-qa.json），标准答案按构造已知；判定由本地 Judge 给出"]
            )
            result.metrics = metrics(summary, records: records)
            try ctx.writeDetail("qa-summary.json", summary)
            try ctx.writeDetail("qa-records.jsonl", text: try BenchmarkFiles.lines(records))
            try ctx.writeDetail("qa-report.md", text: QAReport.markdown(summary: summary, records: records, dataset: dataset))
            result.details = ["details/qa-summary.json", "details/qa-records.jsonl", "details/qa-report.md"]
            if summary.judgeAdjustments > 0 { result.notes.append("Judge 自相矛盾、按评分规则明文条款改正 \(summary.judgeAdjustments) 次") }
            result.notes.append("Judge 是 7B 本地模型，判定有噪声；关键点命中率是不依赖 Judge 的严格对照（措辞不同也算未命中）。")
        } catch {
            result.status = .failed
            result.reason = "\(error)"
        }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    static func metrics(_ s: QAReport.Summary, records: [QARecord], prefix: String = "qa", origin: DataOrigin = .synthetic) -> [Metric] {
        func rate(_ id: String, _ name: String, _ r: QAReport.Rate, _ dir: MetricDirection, gt: GroundTruthKind = .judge, note: String? = nil) -> Metric {
            Metric(id: "\(prefix).\(id)", name: name, value: r.rate, numerator: Double(r.count), denominator: Double(r.total), unit: .ratio,
                   direction: dir, groundTruth: gt, origin: origin, note: note)
        }
        var m: [Metric] = [
            rate("correct", "正确率（可回答的题）", s.answerable.correct, .higherIsBetter),
            Metric(id: "\(prefix).lenient", name: "宽松得分（correct 1、partial 0.5）", value: s.answerable.lenientScore, unit: .ratio, direction: .higherIsBetter, groundTruth: .judge, origin: origin),
            rate("hallucination", "幻觉率（回答含无依据的说法）", s.overall.ungrounded, .lowerIsBetter, note: "Judge 列出的、既不被证据也不被所给记忆支持的关于用户的说法；可能漏报"),
            rate("correctRefusal", "正确拒答率（无法回答的题明确说没有记录）", s.unanswerable.correct, .higherIsBetter),
            rate("unanswerableAnswered", "无法回答却作答（编造或接受错误前提）", s.unanswerableAnswered, .lowerIsBetter),
            rate("falseAbstention", "错误拒答率（可回答却说没有记录）", s.falseAbstention, .lowerIsBetter),
            rate("correctWhenFullyRecalled", "证据齐全时的正确率（作答能力）", s.correctWhenFullyRecalled, .higherIsBetter),
        ]
        if let recall = s.answerable.evidenceRecall {
            m.append(Metric(id: "\(prefix).evidenceRecall", name: "证据召回（进入提示词）", value: recall, unit: .ratio, direction: .higherIsBetter,
                            groundTruth: origin == .synthetic ? .synthetic : .provisional, origin: origin))
        }
        if !records.isEmpty {
            // 不依赖 Judge 的严格对照：回答（归一化后）包含全部关键点原文。
            let answerable = records.filter { $0.item.isAnswerable && $0.answer?.error == nil }
            let hit = answerable.filter { r in r.item.keyPoints.allSatisfy { TextMetrics.contains(r.answer?.answer ?? "", $0) } }
            m.append(.ratio("\(prefix).keyPointExact", "关键点原文命中率（严格，不用 Judge）", hit.count, answerable.count, direction: .higherIsBetter, gt: .anchor,
                            origin: origin, note: "措辞不同即算未命中，是正确率的保守对照"))
        }
        for (key, name) in [("firstTextMs", "首字延迟中位数"), ("totalMs", "回答总耗时中位数")] {
            if let d = s.latency[key], let p50 = d.p50 {
                m.append(Metric(id: "\(prefix).latency.\(key).p50", name: name, value: Double(p50), unit: .milliseconds, direction: .lowerIsBetter,
                                groundTruth: .measured, origin: origin, note: "评测机器上测得"))
            }
        }
        return m
    }
}

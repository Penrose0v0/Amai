import AmaiQAEval
import Foundation

/// 导入真实记忆问答评测（`amai-memory qa-eval`，docs/qa-eval.md）已有的汇总。
///
/// 只读取工作目录里的 `summary.json` 与检索的 `retrieval/summary*.json`——它们只含计数、比例与耗时，
/// 不含记忆正文。不重新运行（真实记忆的题目由出题模型写成，重跑与否由使用者决定）。
/// 题目与标准答案由出题模型根据抽样证据写成、判定由本地 Judge 给出，因此问答指标标为「模型 Judge」；
/// 检索在人工 GT 导入之前只有临时 GT，标为「临时 GT」，不作结论。
public enum RealDataImport {
    public static let id = "real"

    public static func run(_ ctx: BenchmarkContext) -> SuiteResult {
        guard let workdir = ctx.qaWorkdir else {
            return .skipped(id, "真实记忆（导入 qa-eval 结果）", reason: "没有给出 --qa-workdir")
        }
        var result = SuiteResult(id: id, title: "真实记忆（导入 qa-eval 结果）")
        let started = Date()
        let display = workdir.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        do {
            let summaryURL = workdir.appendingPathComponent("summary.json")
            guard FileManager.default.fileExists(atPath: summaryURL.path) else {
                return .skipped(id, result.title, reason: "\(display) 里没有 summary.json（先运行 qa-eval report）")
            }
            let s = try BenchmarkFiles.decoder().decode(QAReport.Summary.self, from: Data(contentsOf: summaryURL))
            // 数据集摘要：dataset.json 的哈希（只用于判断两次导入是否同一套题，不读取内容）。
            let datasetURL = workdir.appendingPathComponent("dataset.json")
            result.datasets.append(DatasetRef(name: "real-qa-dataset", path: display, sha256: TextMetrics.sha256(file: datasetURL), origin: .real))
            result.models = ["answer": s.answerer, "judge": s.judge, "embedder": s.embedder]
            result.metrics += QASuite.metrics(s, records: [], prefix: "real.qa", origin: .real)
            result.notes.append("问答：\(s.answerable.questions) 道可回答、\(s.unanswerable.questions) 道无法回答；题目由 \(s.questionGenerator.generator) 根据抽样证据写成，评分规则 \(s.rubric)\(s.rubricConsistent ? "" : "（**不一致**）")；结果生成于 \(ISO8601DateFormatter().string(from: s.generatedAt))，不是本次运行重新得到的")

            let retrieval = workdir.appendingPathComponent("retrieval", isDirectory: true)
            let human = retrieval.appendingPathComponent("summary.json")
            let provisional = retrieval.appendingPathComponent("summary-provisional.json")
            if let url = [human, provisional].first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                let r = try BenchmarkFiles.decoder().decode(QARetrievalReport.Summary.self, from: Data(contentsOf: url))
                let gt: GroundTruthKind = r.groundTruth == .human ? .human : .provisional
                result.metrics += RetrievalSuite.metrics(r, prefix: "real.retrieval", gt: gt, origin: .real)
                    .filter { !$0.id.contains(".noise.") && !$0.id.contains("pipeline8k") }
                result.notes.append("检索：\(r.groundTruth == .human ? "人工标注 GT" : "**临时 GT（出题时的种子证据，未经人工确认），只用于诊断，不作结论**")；参与评分 \(r.scoredQuestions) 道")
            } else {
                result.metrics.append(.missing("real.retrieval.pipeline.recall@6", "真实记忆检索 Recall@6", reason: "还没有运行 qa-eval retrieval", direction: .higherIsBetter, origin: .real))
            }
            if r(human) == nil {
                result.metrics.append(.missing(
                    "real.retrieval.humanGT", "真实记忆检索（人工 GT）",
                    reason: "人工标注尚未导入（qa-eval gt-sheet → gt-import）；当前只有临时 GT", direction: .higherIsBetter, origin: .real
                ))
            }
        } catch {
            result.status = .failed
            result.reason = "\(error)"
        }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    private static func r(_ url: URL) -> URL? { FileManager.default.fileExists(atPath: url.path) ? url : nil }
}

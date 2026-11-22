import AmaiAssistant
import AmaiMemory
import Foundation

/// 小数的分布（延迟毫秒、检索得分）。
public struct QADistribution: Codable, Sendable, Equatable {
    public var n: Int
    public var mean: Double?
    public var p50: Double?
    public var p90: Double?
    public var max: Double?

    public init(_ values: [Double]) {
        let sorted = values.sorted()
        n = sorted.count
        guard !sorted.isEmpty else { return }
        func r(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        func rank(_ p: Double) -> Double { sorted[Swift.min(sorted.count - 1, Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
        mean = r(sorted.reduce(0, +) / Double(sorted.count))
        p50 = r(rank(0.5))
        p90 = r(rank(0.9))
        max = r(sorted.last!)
    }
}

/// 检索评测的汇总（不含任何记忆正文）与报告。
public enum QARetrievalReport {
    public struct Summary: Codable, Sendable {
        public var generatedAt: Date
        public var now: Date
        public var memoryDigest: String
        public var embedder: String
        public var groundTruth: QAGroundTruth.Source
        public var annotator: String?
        /// 参与评分的可回答题数、被标注为排除的题数（按原因）、尚未标注的题数。
        public var scoredQuestions: Int
        public var excluded: [String: Int]
        public var unannotated: Int
        public var requirementsPerQuestion: QADistribution
        public var systems: [String: QARetrievalMetrics.Group]
        public var byType: [String: [String: QARetrievalMetrics.Group]]
        public var bySubtype: [String: [String: QARetrievalMetrics.Group]]
        /// 延迟（毫秒）。pipeline 是会话里记忆检索那一步（`Timings.memoryMs`，整毫秒）。
        public var latencyMs: [String: QADistribution]
        /// hybrid 取 50 条时的前 6 名与正式调用（取 6 条）给出的条目一致的比例。
        /// 只有优化前保存的结果有（当时正式调用取 6 条）。
        public var deepTopAgreesWithProduction: Double?
        public var unanswerable: [String: [String: QARetrievalMetrics.FalseRetrieval]]
        /// 第一名得分区分可回答与无法回答（absentEntity、noRecordDate）的 AUROC。
        public var topScoreAUROC: [String: Double?]
        /// pipeline 漏掉的信息点按原因计数。
        public var pipelineMisses: [String: Int]
        public var pipelineMissedRequirements: Int
        /// 漏掉的信息点在 hybrid（取 50 条）中的名次；没找到的不计入。
        public var missedHybridRank: QADistribution
        /// 漏掉、hybrid 前 50 名也没有、但纯关键词能找到的信息点数。
        public var missedFoundByKeywordOnly: Int
        public var notes: [String]
    }

    public struct Miss: Sendable {
        public var item: QAItem
        public var requirement: Int
        public var units: [QAGroundTruth.Unit]
        public var cause: QARetrievalMetrics.Cause
        public var hybridRank: Int?
        public var keywordRank: Int?
    }

    public static func evaluate(
        dataset: QADataset, gt: QAGroundTruth, runs: [QARetrievalRun], embedder: String, notes: [String]
    ) -> (summary: Summary, scores: [QARetrievalMetrics.Score], misses: [Miss]) {
        let timeZone = TimeZone(identifier: dataset.timeZone) ?? .current
        var table: [String: [QARetrievalSystem: QARetrievalRun]] = [:]
        for run in runs { table[run.item, default: [:]][run.system] = run }
        let items = Dictionary(dataset.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var scores: [QARetrievalMetrics.Score] = []
        var excluded: [String: Int] = [:]
        var unannotated = 0
        var misses: [Miss] = []
        var requirementCounts: [Double] = []
        for item in dataset.items where item.isAnswerable {
            guard let entry = gt.items[item.id] else { unannotated += 1; continue }
            if let reason = entry.excluded { excluded[reason, default: 0] += 1; continue }
            guard !entry.requirements.isEmpty, let runs = table[item.id] else { unannotated += 1; continue }
            requirementCounts.append(Double(entry.requirements.count))
            for system in QARetrievalSystem.allCases {
                if let run = runs[system] { scores.append(QARetrievalMetrics.score(run, entry: entry)) }
            }
            // pipeline 漏掉的信息点：按全部给出的内容（含同一段对话之前各轮）。
            if let pipeline = runs[.pipeline] {  // 漏检归因只对正式配置（4K）做
                let score = QARetrievalMetrics.score(pipeline, entry: entry)
                let previous = dataset.conversations.first { $0.contains { $0.id == item.id } }?
                    .filter { $0.turn < item.turn }.map(\.question) ?? []
                for (index, hit) in score.firstHit.enumerated() where hit == nil {
                    let requirement = entry.requirements[index]
                    let found = QARetrievalMetrics.cause(
                        requirement: requirement, pipeline: pipeline, hybrid: runs[.hybrid], item: item,
                        previousQuestions: previous, now: dataset.now, timeZone: timeZone
                    )
                    let ids = Set(requirement.map(\.id))
                    let keywordRank = runs[.keyword]?.items.firstIndex { !Set($0.units).isDisjoint(with: ids) }.map { $0 + 1 }
                    misses.append(Miss(item: item, requirement: index, units: requirement, cause: found.cause, hybridRank: found.hybridRank, keywordRank: keywordRank))
                }
            }
        }

        func groups(_ filter: (QAItem) -> String) -> [String: [String: QARetrievalMetrics.Group]] {
            var result: [String: [String: QARetrievalMetrics.Group]] = [:]
            for system in QARetrievalSystem.allCases {
                let mine = scores.filter { $0.system == system }
                result[system.rawValue] = Dictionary(grouping: mine) { filter(items[$0.item]!) }.mapValues(QARetrievalMetrics.group)
            }
            return result
        }

        // 无法回答的题。
        var unanswerable: [String: [String: QARetrievalMetrics.FalseRetrieval]] = [:]
        var auroc: [String: Double?] = [:]
        for system in QARetrievalSystem.allCases {
            var bySubtype: [String: [QARetrievalRun]] = [:]
            for item in dataset.items where !item.isAnswerable {
                if let run = table[item.id]?[system] { bySubtype[item.subtype, default: []].append(run) }
            }
            unanswerable[system.rawValue] = bySubtype.mapValues { runs in
                let turnItems = runs.map { Array($0.items[$0.turnStart...]) }
                return QARetrievalMetrics.FalseRetrieval(
                    questions: runs.count,
                    anyRetrieved: QARetrievalMetrics.mean(turnItems.map { $0.isEmpty ? 0 : 1 }),
                    meanItems: QARetrievalMetrics.mean(turnItems.map { Double($0.count) }),
                    meanTokens: QARetrievalMetrics.mean(turnItems.map { Double($0.reduce(0) { $0 + $1.tokens }) }),
                    topScore: QADistribution(runs.compactMap { $0.items.first?.score })
                )
            }
            if system != .pipeline {
                let positive = scores.filter { $0.system == system }.map { table[$0.item]?[system]?.items.first?.score ?? 0 }
                let negative = dataset.items.filter { !$0.isAnswerable && $0.subtype != "falsePremise" }
                    .map { table[$0.id]?[system]?.items.first?.score ?? 0 }
                auroc[system.rawValue] = QARetrievalMetrics.auroc(positive: positive, negative: negative)
            }
        }

        let hybridRuns = runs.filter { $0.system == .hybrid && $0.productionTop != nil }
        let agreement = hybridRuns.map { run -> Double in
            let production = run.items.prefix(QALegacyRecall.maxEntries).map { Set($0.units) }
            let deep = run.productionTop!.map(Set.init)
            return deep == production ? 1 : 0
        }
        var latency: [String: QADistribution] = [:]
        for system in QARetrievalSystem.allCases {
            latency[system.rawValue] = QADistribution(runs.filter { $0.system == system }.map(\.ms))
            let deep = runs.filter { $0.system == system }.compactMap(\.deepMs)
            if !deep.isEmpty { latency[system.rawValue + "(取 50 条)"] = QADistribution(deep) }
        }
        var causes: [String: Int] = [:]
        for miss in misses { causes[miss.cause.rawValue, default: 0] += 1 }

        let summary = Summary(
            generatedAt: Date(), now: dataset.now, memoryDigest: dataset.memoryDigest, embedder: embedder,
            groundTruth: gt.source, annotator: gt.annotator,
            scoredQuestions: scores.filter { $0.system == .pipeline }.count, excluded: excluded, unannotated: unannotated,
            requirementsPerQuestion: QADistribution(requirementCounts),
            systems: Dictionary(uniqueKeysWithValues: QARetrievalSystem.allCases.map { s in
                (s.rawValue, QARetrievalMetrics.group(scores.filter { $0.system == s }))
            }),
            byType: groups { $0.type.rawValue },
            bySubtype: groups { "\($0.type.rawValue)/\($0.subtype)" },
            latencyMs: latency,
            deepTopAgreesWithProduction: agreement.isEmpty ? nil : QARetrievalMetrics.mean(agreement),
            unanswerable: unanswerable,
            topScoreAUROC: auroc,
            pipelineMisses: causes,
            pipelineMissedRequirements: misses.count,
            missedHybridRank: QADistribution(misses.compactMap { $0.hybridRank.map(Double.init) }),
            missedFoundByKeywordOnly: misses.filter { $0.hybridRank == nil && $0.keywordRank != nil }.count,
            notes: notes
        )
        return (summary, scores, misses)
    }

    // MARK: - Markdown

    static func pct(_ x: Double?) -> String { x.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
    static func num(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "—" }

    static func row(_ name: String, _ g: QARetrievalMetrics.Group) -> String {
        "| \(name) | \(g.questions) | \(pct(g.recallAtK["@1"])) | \(pct(g.recallAtK["@3"])) | \(pct(g.recallAtK["@6"])) | \(pct(g.recallAtK["@10"])) | \(pct(g.recallAtK["@20"])) | \(pct(g.fullAtK["@6"])) | \(pct(g.fullAtK["@20"])) | \(pct(g.precisionAtK["@6"])) | \(num(g.ndcgAtK["@6"])) | \(num(g.ndcgAtK["@10"])) | \(pct(g.recallAll)) | \(pct(g.fullAll)) | \(pct(g.recallAtBudget["4K"])) | \(pct(g.fullAtBudget["4K"])) | \(pct(g.recallAtBudget["8K"])) | \(pct(g.fullAtBudget["8K"])) | \(String(format: "%.1f / %.0f", g.meanItems, g.meanTokens)) |"
    }

    /// 指标（不含记忆正文）。
    public static func metricsMarkdown(_ s: Summary) -> String {
        var lines: [String] = []
        let source = switch s.groundTruth {
        case .human: "人工标注" + (s.annotator.map { "（\($0)）" } ?? "")
        case .synthetic: "合成数据（所需记录按构造已知）"
        case .provisionalSeed: "**临时 GT：出题时的种子证据，未经人工确认；追问题不计入**"
        }
        lines.append("- 标准证据：\(source)；参与评分 \(s.scoredQuestions) 道，排除 \(s.excluded.values.reduce(0, +)) 道\(s.excluded.isEmpty ? "" : "（" + s.excluded.keys.sorted().map { "\($0) \(s.excluded[$0]!)" }.joined(separator: "，") + "）")，未标注 \(s.unannotated) 道；每题信息点 平均 \(num(s.requirementsPerQuestion.mean))")
        if let agreement = s.deepTopAgreesWithProduction {
            lines.append("- 向量模型：`\(s.embedder)`。（优化前的结果）hybrid / keyword 的前 6 名是正式条数（6 条）的结果，之后接取 50 条时的其余结果；取 50 条时前 6 名与之一致的比例：\(pct(agreement))")
        } else {
            lines.append("- 向量模型：`\(s.embedder)`。hybrid / keyword 与 MemoryRecall 的调用相同（取 50 条）。")
        }
        lines.append("")
        let header = "| 分组 | 题数 | R@1 | R@3 | R@6 | R@10 | R@20 | Full@6 | Full@20 | P@6 | nDCG@6 | nDCG@10 | R(全部) | Full(全部) | R@4K | Full@4K | R@8K | Full@8K | 平均项数 / token |"
        let divider = "|" + String(repeating: "---|", count: 20)
        for system in QARetrievalSystem.allCases {
            guard let all = s.systems[system.rawValue] else { continue }
            lines.append("### \(system.rawValue)")
            lines.append("")
            lines += [header, divider, row("**全部**", all)]
            for type in QAQuestionType.allCases {
                if let g = s.byType[system.rawValue]?[type.rawValue] { lines.append(row(type.rawValue, g)) }
            }
            for key in (s.bySubtype[system.rawValue] ?? [:]).keys.sorted() {
                lines.append(row("· \(key)", s.bySubtype[system.rawValue]![key]!))
            }
            lines.append("")
        }
        lines.append("R@K：信息点召回；Full：所需信息点全部召回；P@K：前 K 项中相关项的比例（分母为 K，所以上限约为信息点数 / K）；@4K / @8K：按顺序装入，直到下一项超出 4096 / 8192 token。pipeline 的列表含同一段对话之前各轮给过的记忆。")
        lines.append("")
        lines.append("### 无法回答的题（误检）")
        lines.append("")
        lines.append("| 系统 | 细分类型 | 题数 | 返回了内容 | 平均项数 | 平均 token | 第一名得分 p50 / max |")
        lines.append("|---|---|---|---|---|---|---|")
        for system in QARetrievalSystem.allCases {
            for (subtype, f) in (s.unanswerable[system.rawValue] ?? [:]).sorted(by: { $0.key < $1.key }) {
                lines.append("| \(system.rawValue) | \(subtype) | \(f.questions) | \(pct(f.anyRetrieved)) | \(String(format: "%.1f", f.meanItems)) | \(String(format: "%.0f", f.meanTokens)) | \(num(f.topScore.p50)) / \(num(f.topScore.max)) |")
            }
        }
        lines.append("")
        lines.append("- 第一名得分区分可回答 / 无法回答（absentEntity、noRecordDate）的 AUROC：" + s.topScoreAUROC.keys.sorted().map { "\($0) \(num(s.topScoreAUROC[$0] ?? nil))" }.joined(separator: "，"))
        lines.append("")
        lines.append("### 延迟（毫秒）")
        lines.append("")
        lines.append("| 系统 | n | 平均 | p50 | p90 | 最大 |")
        lines.append("|---|---|---|---|---|---|")
        for key in s.latencyMs.keys.sorted() {
            let d = s.latencyMs[key]!
            lines.append("| \(key) | \(d.n) | \(num(d.mean)) | \(num(d.p50)) | \(num(d.p90)) | \(num(d.max)) |")
        }
        lines.append("")
        lines.append("pipeline 是会话中记忆检索那一步（日期规则 + 正式条数的混合检索 + 组装，整毫秒）；hybrid / keyword 是正式条数（6 条）的一次 `MemoryAPI.search`；\"取 50 条\"只为看更深的名次，不代表正式延迟。")
        lines.append("")
        lines.append("### pipeline 漏掉的信息点（\(s.pipelineMissedRequirements) 个）")
        lines.append("")
        for cause in QARetrievalMetrics.Cause.allCases {
            lines.append("- \(cause.rawValue)：\(s.pipelineMisses[cause.rawValue] ?? 0)")
        }
        lines.append("- 漏掉的信息点在 hybrid（取 50 条）中的名次：n \(s.missedHybridRank.n)，p50 \(num(s.missedHybridRank.p50))，p90 \(num(s.missedHybridRank.p90))；hybrid 前 50 名没有、纯关键词能找到：\(s.missedFoundByKeywordOnly)")
        return lines.joined(separator: "\n")
    }

    /// 优化前后在同一份 GT 上的对比（不含记忆正文）。
    public static func comparisonMarkdown(before: Summary, after: Summary) -> String {
        var lines = [
            "| 系统 | 题数 | R(全部) | Full(全部) | nDCG@10 | R@4K | Full@4K | R@8K | Full@8K | 平均 token | 延迟 p50 / p90（毫秒） |",
            "|---|---|---|---|---|---|---|---|---|---|---|",
        ]
        func row(_ name: String, _ summary: Summary, _ system: String) {
            guard let g = summary.systems[system], g.questions > 0 else { return }
            let d = summary.latencyMs[system]
            lines.append("| \(name) | \(g.questions) | \(pct(g.recallAll)) | \(pct(g.fullAll)) | \(num(g.ndcgAtK["@10"])) | \(pct(g.recallAtBudget["4K"])) | \(pct(g.fullAtBudget["4K"])) | \(pct(g.recallAtBudget["8K"])) | \(pct(g.fullAtBudget["8K"])) | \(String(format: "%.0f", g.meanTokens)) | \(num(d?.p50)) / \(num(d?.p90)) |")
        }
        row("pipeline · 优化前（前 6 条 + 截断）", before, "pipeline")
        row("pipeline · 优化后 4K", after, "pipeline")
        row("pipeline · 优化后 8K", after, "pipeline-8k")
        row("hybrid · 优化前（前 6 条为取 6 条的结果）", before, "hybrid")
        row("hybrid · 优化后（取 50 条）", after, "hybrid")
        row("keyword · 优化前", before, "keyword")
        row("keyword · 优化后", after, "keyword")
        lines.append("")
        lines.append("按题型的 Full(全部)（pipeline：优化前 → 4K → 8K）：")
        lines.append("")
        lines.append("| 题型 | 题数 | 优化前 | 4K | 8K | R(全部) 优化前 → 4K |")
        lines.append("|---|---|---|---|---|---|")
        let keys = Set((before.bySubtype["pipeline"] ?? [:]).keys).union((after.bySubtype["pipeline"] ?? [:]).keys).sorted()
        for key in keys {
            let b = before.bySubtype["pipeline"]?[key], a = after.bySubtype["pipeline"]?[key], a8 = after.bySubtype["pipeline-8k"]?[key]
            lines.append("| \(key) | \(a?.questions ?? b?.questions ?? 0) | \(pct(b?.fullAll)) | \(pct(a?.fullAll)) | \(pct(a8?.fullAll)) | \(pct(b?.recallAll)) → \(pct(a?.recallAll)) |")
        }
        lines.append("")
        func misses(_ s: Summary) -> String {
            QARetrievalMetrics.Cause.allCases.map { "\($0.rawValue) \(s.pipelineMisses[$0.rawValue] ?? 0)" }.joined(separator: "，")
        }
        lines.append("- pipeline 漏掉的信息点：优化前 \(before.pipelineMissedRequirements)（\(misses(before))）；优化后 4K \(after.pipelineMissedRequirements)（\(misses(after))）")
        func falseHits(_ s: Summary, _ system: String) -> String {
            (s.unanswerable[system] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \(pct($0.value.anyRetrieved)) / \(String(format: "%.0f", $0.value.meanTokens)) token" }.joined(separator: "，")
        }
        lines.append("- 无法回答的题（返回了内容 / 平均 token）：优化前 \(falseHits(before, "pipeline"))；优化后 4K \(falseHits(after, "pipeline"))；8K \(falseHits(after, "pipeline-8k"))")
        return lines.joined(separator: "\n")
    }

    /// 完整报告：指标加失败案例（含记忆正文，只留在本机）。
    public static func markdown(summary: Summary, misses: [Miss], runs: [QARetrievalRun], catalog: EvidenceCatalog) -> String {
        var lines = [
            "# 记忆检索评测",
            "",
            "> 本文件含真实记忆原文，只留在本机，不要上传或提交。",
            "",
        ]
        lines += summary.notes.map { "- \($0)" }
        lines += ["", "## 指标", "", metricsMarkdown(summary), "", "## pipeline 漏掉的信息点", ""]
        var table: [String: QARetrievalRun] = [:]
        for run in runs where run.system == .pipeline { table[run.item] = run }
        for cause in QARetrievalMetrics.Cause.allCases {
            let group = misses.filter { $0.cause == cause }
            guard !group.isEmpty else { continue }
            lines += ["### \(cause.rawValue)（\(group.count)）", ""]
            for miss in group {
                let item = miss.item
                lines.append("#### \(item.id) · \(item.type.rawValue)/\(item.subtype) · 信息点 \(String(UnicodeScalar(UInt8(65 + miss.requirement))))")
                lines.append("")
                lines.append("- **问题**：\(item.question)")
                lines.append("- **需要的记录**（任一即可）：")
                for unit in miss.units {
                    lines.append("  - \(catalog.unit(unit.id)?.labeled ?? unit.id)")
                }
                lines.append("- **hybrid 名次**：\(miss.hybridRank.map(String.init) ?? "前 50 名没有")；**keyword 名次**：\(miss.keywordRank.map(String.init) ?? "前 50 名没有")")
                if let run = table[item.id] {
                    let turn = Array(run.items[run.turnStart...])
                    lines.append("- **pipeline 这一轮给出**：\(turn.count) 项、\(turn.reduce(0) { $0 + $1.tokens }) token；整天时间线：\(run.dayTimelines.isEmpty ? "无" : run.dayTimelines.joined(separator: ", "))；被截断：\(run.truncatedDays.isEmpty ? "无" : run.truncatedDays.joined(separator: ", "))")
                    for entry in turn.prefix(8) { lines.append("  - \(entry.text.prefix(120))") }
                    if turn.count > 8 { lines.append("  - …") }
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Annotation sheet

/// 人工标注 GT 用的本地网页（单个 HTML 文件，数据内嵌，不联网）。
/// 每道可回答的题给出候选记录池：种子证据、各检索方式的前几名、pipeline 取出的整天时间线，合并后按时间排序，
/// 不标出来自哪种方式，也不标出哪条是种子；另可在整个记忆中搜索补充。
public enum QAGroundTruthSheet {
    /// 人工标注的代表性子集：按题型分层、按种子抽取，不看任何检索结果（避免挑到优化正好修好的题）。
    /// 覆盖多证据（ordering 两条证据、追问）、跨语言、日期与追问（只取第 2、3 轮：它们依赖上文）。
    public static let subsetQuotas: [(String, Int)] = [
        ("fact/document", 3), ("fact/timeline", 3),
        ("temporal/relativeDate", 3), ("temporal/when", 3), ("temporal/ordering", 4),
        ("crossLingual/english", 3), ("crossLingual/japanese", 3),
        ("followUp/sameDay", 4), ("followUp/sameTopic", 4),
    ]

    public static func subset(_ dataset: QADataset, seed: UInt64) -> [String] {
        var random = QARandom(seed: seed)
        var chosen: [String] = []
        for (key, count) in subsetQuotas {
            var pool = dataset.items.filter { $0.isAnswerable && "\($0.type.rawValue)/\($0.subtype)" == key && ($0.type != .followUp || $0.turn > 0) }
            pool.shuffle(using: &random)
            if key.hasPrefix("followUp") {
                // 每段对话先各取一轮，再补足。
                var picked: [QAItem] = []
                for item in pool where !picked.contains(where: { $0.conversation == item.conversation }) { picked.append(item) }
                for item in pool where !picked.contains(item) { picked.append(item) }
                pool = picked
            }
            chosen += pool.prefix(count).map(\.id)
        }
        let order = Dictionary(dataset.items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return chosen.sorted { order[$0]! < order[$1]! }
    }

    public static func candidates(for item: QAItem, dataset: QADataset, runs: [QARetrievalRun], catalog: EvidenceCatalog) -> [String] {
        let conversation = dataset.conversations.first { $0.contains { $0.id == item.id } } ?? [item]
        var ids = Set<String>()
        for turn in conversation {
            ids.formUnion(turn.evidence)
            for run in runs where run.item == turn.id {
                switch run.system {
                case .pipeline, .pipeline8k:
                    ids.formUnion(run.items.flatMap(\.units))
                    for day in run.dayTimelines { ids.formUnion(catalog.units.filter { $0.category == .daily && $0.date == day }.map(\.id)) }
                case .hybrid: ids.formUnion(run.items.prefix(10).flatMap(\.units))
                case .keyword: ids.formUnion(run.items.prefix(5).flatMap(\.units))
                }
            }
        }
        let order = Dictionary(catalog.units.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }

    /// - Parameters:
    ///   - runs: 用来合并候选池的检索结果。对比优化前后时两边的结果都要放进来，任何一边找到的记录都能被标注。
    ///   - only: 只标注这些题（nil 为全部可回答的题）。
    public static func html(dataset: QADataset, runs: [QARetrievalRun], catalog: EvidenceCatalog, only: [String]? = nil) throws -> String {
        let previous: (QAItem) -> [String] = { item in
            dataset.conversations.first { $0.contains { $0.id == item.id } }?.filter { $0.turn < item.turn }.map(\.question) ?? []
        }
        let selected = only.map(Set.init)
        let items: [[String: Any]] = dataset.items.filter { $0.isAnswerable && (selected?.contains($0.id) ?? true) }.map { item in
            [
                "id": item.id, "type": "\(item.type.rawValue)/\(item.subtype)", "language": item.language,
                "question": item.question, "previous": previous(item), "reference": item.expectedAnswer,
                "candidates": candidates(for: item, dataset: dataset, runs: runs, catalog: catalog),
            ]
        }
        var units: [String: [String: String]] = [:]
        for unit in catalog.units {
            var where_ = unit.file
            if let section = unit.section, !section.isEmpty { where_ += " › \(section)" }
            var when = unit.date ?? ""
            if let time = unit.time { when += " \(time)" }
            units[unit.id] = ["where": where_, "when": when, "text": unit.text]
        }
        let payload: [String: Any] = ["memoryDigest": dataset.memoryDigest, "now": ISO8601DateFormatter().string(from: dataset.now), "items": items, "units": units]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            .replacingOccurrences(of: "</", with: "<\\/")
        return template.replacingOccurrences(of: "__DATA__", with: json)
    }

    static let template = #"""
    <!doctype html>
    <html lang="zh-Hans"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>检索 GT 标注</title>
    <style>
    :root{--bg:#fbfaf8;--fg:#1d1d1f;--muted:#6e6e73;--line:#e3e1dc;--card:#fff;--accent:#2f6fde;--a:#2f6fde;--b:#1f9d6b;--c:#c47a12;--d:#a2479b;--warn:#b3261e}
    @media (prefers-color-scheme:dark){:root{--bg:#17171a;--fg:#ececef;--muted:#9a9aa2;--line:#2e2e33;--card:#202024;--accent:#6ea0ff;--warn:#ff8a80}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans",sans-serif}
    header{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;flex-wrap:wrap;gap:8px;align-items:center}
    header .grow{flex:1}button,select,input,textarea{font:inherit;color:inherit}
    button{border:1px solid var(--line);background:var(--card);border-radius:8px;padding:4px 10px;cursor:pointer}button.primary{background:var(--accent);color:#fff;border-color:var(--accent)}
    main{max-width:980px;margin:0 auto;padding:16px}
    .help{color:var(--muted);font-size:13px;border:1px solid var(--line);border-radius:10px;padding:10px 14px;background:var(--card)}
    .q{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:14px 0}
    .q h2{font-size:16px;margin:2px 0 6px}.meta{color:var(--muted);font-size:12px}.prev{color:var(--muted);font-size:13px;margin:4px 0}
    .ref{font-size:13px;color:var(--muted);border-left:3px solid var(--line);padding-left:8px;margin:8px 0}
    .cand{display:flex;gap:10px;align-items:flex-start;padding:6px 0;border-top:1px dashed var(--line)}
    .cand .t{flex:1}.cand .w{color:var(--muted);font-size:12px}
    .seg{display:flex;flex-shrink:0}.seg button{border-radius:0;padding:2px 8px;min-width:30px}.seg button:first-child{border-radius:8px 0 0 8px}.seg button:last-child{border-radius:0 8px 8px 0}
    .seg button.on[data-l=none]{background:var(--line)}.seg button.on[data-l=A]{background:var(--a);color:#fff}.seg button.on[data-l=B]{background:var(--b);color:#fff}.seg button.on[data-l=C]{background:var(--c);color:#fff}.seg button.on[data-l=D]{background:var(--d);color:#fff}
    .row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:10px}.done{color:var(--b);font-weight:600}.todo{color:var(--warn)}
    .search{margin-top:10px}.search input{width:100%;padding:6px 10px;border:1px solid var(--line);border-radius:8px;background:var(--bg)}
    .results{max-height:260px;overflow:auto}textarea{width:100%;min-height:36px;border:1px solid var(--line);border-radius:8px;background:var(--bg);padding:6px}
    @media (max-width:600px){.cand{flex-direction:column}}
    </style></head><body>
    <header><strong>检索 GT 标注</strong><span id="progress" class="meta"></span><span class="grow"></span>
    <label class="meta"><input type="checkbox" id="onlyTodo"> 只看未完成</label>
    <button id="import">导入进度</button><button class="primary" id="export">导出标注</button><input type="file" id="file" accept=".json" hidden></header>
    <main>
    <div class="help">
    <p><b>任务</b>：为每道题标出<b>回答它必需的记录</b>。不同的必需信息点用 A / B / C / D 区分；同一个信息点有几条记录都能提供时（同一件事在长期记忆和当天时间线里都有），给它们标<b>同一个字母</b>。与回答无关、或只是"沾边"的记录保持"无"。</p>
    <p>候选来自多种检索方式与出题时的记录，合并后按文件与时间排序，不显示来源。候选里缺了需要的记录，就用每题下方的搜索在全部记忆里找。"参考答案"是出题模型写的，只帮助理解题意，<b>不是标注依据</b>：请以记忆原文为准；记忆不足以回答、或题目本身有问题时，选"排除"并写明原因。</p>
    <p>每题标好后点"这题标好了"。进度自动保存在本浏览器；完成后点"导出标注"，再运行 <code>amai-memory qa-eval gt-import --workdir … --file 导出的文件</code>。本文件含真实记忆原文，只在本机打开。</p>
    </div>
    <div id="list"></div></main>
    <script>
    const DATA = __DATA__;
    const KEY = "amai-gt-" + DATA.memoryDigest;
    const LABELS = ["none","A","B","C","D"];
    let state = {};
    try { state = JSON.parse(localStorage.getItem(KEY) || "{}") } catch (e) { state = {} }
    function save(){ try { localStorage.setItem(KEY, JSON.stringify(state)) } catch (e) {} progress() }
    function entry(id){ return state[id] || (state[id] = {labels:{}, extra:[], excluded:"", note:"", done:false}) }
    function esc(s){ return String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])) }
    function progress(){ const n = DATA.items.filter(i => entry(i.id).done).length; document.getElementById("progress").textContent = `已完成 ${n} / ${DATA.items.length}` }
    function candRow(qid, uid){
      const u = DATA.units[uid]; if (!u) return "";
      const l = entry(qid).labels[uid] || "none";
      return `<div class="cand"><div class="t"><div class="w">${esc(u.where)} · ${esc(u.when)}</div>${esc(u.text)}</div><div class="seg">` +
        LABELS.map(x => `<button data-q="${qid}" data-u="${uid}" data-l="${x}" class="${x===l?"on":""}">${x==="none"?"无":x}</button>`).join("") + `</div></div>`
    }
    function render(){
      const only = document.getElementById("onlyTodo").checked;
      document.getElementById("list").innerHTML = DATA.items.filter(i => !only || !entry(i.id).done).map(i => {
        const e = entry(i.id);
        const ids = [...new Set([...i.candidates, ...e.extra])];
        return `<section class="q" id="${i.id}"><div class="meta">${i.id} · ${esc(i.type)} · ${e.done ? '<span class="done">已标好</span>' : '<span class="todo">未完成</span>'}</div>` +
          (i.previous.length ? `<div class="prev">之前的提问：${i.previous.map(esc).join(" → ")}</div>` : "") +
          `<h2>${esc(i.question)}</h2><div class="ref">参考答案（出题模型写的，不是标注依据）：${esc(i.reference)}</div>` +
          ids.map(u => candRow(i.id, u)).join("") +
          `<div class="search"><input data-search="${i.id}" placeholder="在全部记忆中搜索，补充候选里没有的记录"><div class="results" id="r-${i.id}"></div></div>` +
          `<div class="row"><select data-ex="${i.id}"><option value="">参与评测</option>` +
          ["题目有歧义","记忆不足以回答","参考答案与记忆不符","其他"].map(r => `<option ${e.excluded===r?"selected":""}>${r}</option>`).join("") +
          `</select><textarea data-note="${i.id}" placeholder="备注（可选）">${esc(e.note)}</textarea>` +
          `<button class="primary" data-done="${i.id}">${e.done ? "取消完成" : "这题标好了"}</button></div></section>`
      }).join("");
    }
    document.addEventListener("click", ev => {
      const b = ev.target.closest("button"); if (!b) return;
      if (b.dataset.l) { const e = entry(b.dataset.q); e.labels[b.dataset.u] = b.dataset.l; e.done = false; save();
        b.parentElement.querySelectorAll("button").forEach(x => x.classList.toggle("on", x === b)); return }
      if (b.dataset.add) { const e = entry(b.dataset.add); if (!e.extra.includes(b.dataset.u)) e.extra.push(b.dataset.u); save(); render(); return }
      if (b.dataset.done) { const e = entry(b.dataset.done);
        const labeled = Object.values(e.labels).some(l => l !== "none");
        if (!e.done && !labeled && !e.excluded) { alert("还没有标出任何必需记录；如果记忆不足以回答，请选择排除原因。"); return }
        e.done = !e.done; save(); render(); return }
    });
    document.addEventListener("change", ev => {
      const t = ev.target;
      if (t.dataset.ex) { entry(t.dataset.ex).excluded = t.value; save() }
      if (t.dataset.note) { entry(t.dataset.note).note = t.value; save() }
      if (t.id === "onlyTodo") render();
    });
    document.addEventListener("input", ev => {
      const t = ev.target; if (!t.dataset.search) return;
      const q = t.value.trim().toLowerCase(); const box = document.getElementById("r-" + t.dataset.search);
      if (q.length < 2) { box.innerHTML = ""; return }
      const hits = Object.entries(DATA.units).filter(([id, u]) => (u.text + " " + u.where + " " + u.when).toLowerCase().includes(q)).slice(0, 40);
      box.innerHTML = hits.map(([id, u]) => `<div class="cand"><div class="t"><div class="w">${esc(u.where)} · ${esc(u.when)}</div>${esc(u.text)}</div><button data-add="${t.dataset.search}" data-u="${id}">加入候选</button></div>`).join("") || '<div class="meta">没有匹配</div>';
    });
    document.getElementById("export").onclick = () => {
      const items = {};
      for (const i of DATA.items) { const e = entry(i.id); items[i.id] = {labels: e.labels, excluded: e.excluded, note: e.note, done: e.done} }
      const blob = new Blob([JSON.stringify({memoryDigest: DATA.memoryDigest, exportedAt: new Date().toISOString(), items, state}, null, 1)], {type: "application/json"});
      const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "gt-annotations.json"; a.click();
    };
    document.getElementById("import").onclick = () => document.getElementById("file").click();
    document.getElementById("file").onchange = async ev => {
      const f = ev.target.files[0]; if (!f) return;
      const data = JSON.parse(await f.text());
      if (data.memoryDigest !== DATA.memoryDigest) { alert("这份进度对应的记忆副本不同，无法导入。"); return }
      state = data.state || {}; save(); render();
    };
    progress(); render();
    </script></body></html>
    """#
}

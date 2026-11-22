import Foundation

/// 一道题的完整记录：题目、管线输出、判定。含记忆正文，只留在本机。
public struct QARecord: Codable, Sendable {
    public var item: QAItem
    public var answer: QAAnswer?
    public var judgment: QAJudgment?
    /// 失败类别（见 `QAReport.Failure`）。
    public var failures: [String]
    /// 可回答的题：所需证据中进入了提示词的比例。
    public var evidenceRecall: Double?
}

/// 汇总。`Summary` 只有计数、比例与耗时，不含任何记忆正文，可以单独查看或分享。
public enum QAReport {
    public enum Failure: String, CaseIterable, Sendable {
        /// 管线出错（模型报错、取消等）。
        case pipelineError = "pipeline-error"
        /// Judge 没有给出合格判定，不计入依赖判定的指标。
        case judgeError = "judge-error"
        /// 可回答的题答错，且所需证据没有全部进入提示词：检索的问题。
        case retrievalMiss = "retrieval-miss"
        /// 可回答的题答错，但所需证据都在提示词里：作答的问题。
        case answerError = "answer-error"
        /// 可回答的题，助手却说没有记录。
        case falseAbstain = "false-abstain"
        /// 无法回答的题没有正确处理（编造了答案，或接受了错误前提）。
        case unanswerableAnswered = "unanswerable-answered"
        /// 回答中有既不被证据、也不被所给记忆支持的说法。
        case ungrounded = "ungrounded"
    }

    public struct Rate: Codable, Sendable, Equatable {
        public var count: Int
        public var total: Int
        public var rate: Double?

        init(_ count: Int, of total: Int) {
            self.count = count
            self.total = total
            self.rate = total > 0 ? (Double(count) / Double(total) * 1000).rounded() / 1000 : nil
        }
    }

    public struct Distribution: Codable, Sendable, Equatable {
        public var n: Int
        public var mean: Int?
        public var p50: Int?
        public var p90: Int?
        public var max: Int?

        init(_ values: [Int]) {
            let sorted = values.sorted()
            n = sorted.count
            guard !sorted.isEmpty else { return }
            func rank(_ p: Double) -> Int { sorted[Swift.min(sorted.count - 1, Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
            mean = sorted.reduce(0, +) / sorted.count
            p50 = rank(0.5)
            p90 = rank(0.9)
            max = sorted.last
        }
    }

    public struct Group: Codable, Sendable, Equatable {
        public var questions: Int
        /// 可回答的题：所需证据进入提示词的平均比例。
        public var evidenceRecall: Double?
        /// 可回答的题：所需证据全部进入提示词的比例。
        public var fullRecall: Rate?
        /// 可回答的题：所需证据所在的文件（daily 还要同一天）全部出现在来源列表中的比例。
        public var sourceRecall: Rate?
        public var correct: Rate
        public var partial: Rate
        /// 正确记 1，部分正确记 0.5。
        public var lenientScore: Double?
        public var ungrounded: Rate
        public var abstained: Rate
        public var pipelineErrors: Int
        public var judgeErrors: Int
    }

    public struct Summary: Codable, Sendable {
        public var generatedAt: Date
        public var now: Date
        public var memoryDigest: String
        public var answerer: String
        public var judge: String
        public var embedder: String
        public var rubric: String
        /// 所有判定是否都用的是当前这份评分规则（标识含摘要）。
        public var rubricConsistent: Bool
        public var questionGenerator: QAEgress
        public var unfilledSlots: Int
        public var overall: Group
        public var answerable: Group
        public var unanswerable: Group
        public var byType: [String: Group]
        public var bySubtype: [String: Group]
        /// 可回答的题：证据全部召回与未全部召回时各自的正确率（区分检索与作答）。
        public var correctWhenFullyRecalled: Rate
        public var correctWhenNotFullyRecalled: Rate
        /// 可回答的题，助手说没有记录。
        public var falseAbstention: Rate
        /// 无法回答的题没有正确处理。
        public var unanswerableAnswered: Rate
        /// 跨语言题：用提问的语言回答的比例（按文字判断，不参与评分）。
        public var crossLingualAnsweredInQuestionLanguage: Rate
        public var latency: [String: Distribution]
        public var promptTokens: Distribution
        public var cachedPromptTokens: Distribution
        /// 问题与证据原文的最长公共片段（归一化后的字符数）。
        public var questionEvidenceOverlap: Distribution
        public var failures: [String: Int]
        /// 按评分规则明文条款改正的 Judge 判定数（Judge 自相矛盾）。
        public var judgeAdjustments: Int
        public var notes: [String]
    }

    // MARK: - Build

    public static func records(dataset: QADataset, answers: [QAAnswer], judgments: [QAJudgment]) -> [QARecord] {
        let answerTable = Dictionary(answers.map { ($0.item, $0) }, uniquingKeysWith: { _, b in b })
        let judgmentTable = Dictionary(judgments.map { ($0.item, $0) }, uniquingKeysWith: { _, b in b })
        return dataset.items.map { item in
            let answer = answerTable[item.id]
            let judgment = judgmentTable[item.id]
            var recall: Double?
            if item.isAnswerable, let answer, !item.evidence.isEmpty {
                recall = Double(Set(answer.recalledEvidence).intersection(item.evidence).count) / Double(item.evidence.count)
            }
            return QARecord(item: item, answer: answer, judgment: judgment, failures: failures(item, answer, judgment, recall), evidenceRecall: recall)
        }
    }

    static func failures(_ item: QAItem, _ answer: QAAnswer?, _ judgment: QAJudgment?, _ recall: Double?) -> [String] {
        guard let answer else { return [] }
        if answer.error != nil { return [Failure.pipelineError.rawValue] }
        guard let judgment, let verdict = judgment.verdict else { return [Failure.judgeError.rawValue] }
        var result: [Failure] = []
        if item.isAnswerable {
            if verdict != .correct { result.append((recall ?? 0) < 1 ? .retrievalMiss : .answerError) }
            if judgment.abstained == true { result.append(.falseAbstain) }
        } else if verdict != .correct {
            result.append(.unanswerableAnswered)
        }
        if judgment.isUngrounded { result.append(.ungrounded) }
        return result.map(\.rawValue)
    }

    static func group(_ records: [QARecord]) -> Group {
        let answered = records.filter { $0.answer != nil }
        let judged = answered.filter { $0.answer?.error == nil && $0.judgment?.verdict != nil }
        let answerable = answered.filter { $0.item.isAnswerable && $0.answer?.error == nil }
        let recalls = answerable.compactMap(\.evidenceRecall)
        let correct = judged.filter { $0.judgment?.verdict == .correct }.count
        let partial = judged.filter { $0.judgment?.verdict == .partial }.count
        func round(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        return Group(
            questions: records.count,
            evidenceRecall: recalls.isEmpty ? nil : round(recalls.reduce(0, +) / Double(recalls.count)),
            fullRecall: answerable.isEmpty ? nil : Rate(recalls.filter { $0 >= 1 }.count, of: answerable.count),
            sourceRecall: answerable.isEmpty ? nil : Rate(answerable.filter { record in
                Set(record.answer?.sourceMatchedEvidence ?? []).isSuperset(of: record.item.evidence)
            }.count, of: answerable.count),
            correct: Rate(correct, of: judged.count),
            partial: Rate(partial, of: judged.count),
            lenientScore: judged.isEmpty ? nil : round((Double(correct) + 0.5 * Double(partial)) / Double(judged.count)),
            ungrounded: Rate(judged.filter { $0.judgment?.isUngrounded == true }.count, of: judged.count),
            abstained: Rate(judged.filter { $0.judgment?.abstained == true }.count, of: judged.count),
            pipelineErrors: answered.filter { $0.answer?.error != nil }.count,
            judgeErrors: answered.filter { $0.answer?.error == nil && $0.judgment?.verdict == nil }.count
        )
    }

    public static func summary(
        dataset: QADataset, records: [QARecord], answerer: String, judge: String, embedder: String, notes: [String]
    ) -> Summary {
        let ok = records.filter { $0.answer != nil && $0.answer?.error == nil }
        let judged = ok.filter { $0.judgment?.verdict != nil }
        let answerableJudged = judged.filter(\.item.isAnswerable)
        let full = answerableJudged.filter { ($0.evidenceRecall ?? 0) >= 1 }
        let notFull = answerableJudged.filter { ($0.evidenceRecall ?? 0) < 1 }
        let cross = ok.filter { $0.item.type == .crossLingual }
        var failures: [String: Int] = [:]
        for record in records { for f in record.failures { failures[f, default: 0] += 1 } }
        let timings = ok.compactMap { $0.answer?.timings }
        return Summary(
            generatedAt: Date(), now: dataset.now, memoryDigest: dataset.memoryDigest,
            answerer: answerer, judge: judge, embedder: embedder, rubric: QARubric.id,
            rubricConsistent: records.compactMap(\.judgment).allSatisfy { $0.rubric == QARubric.id },
            questionGenerator: dataset.egress, unfilledSlots: dataset.unfilledSlots,
            overall: group(records),
            answerable: group(records.filter(\.item.isAnswerable)),
            unanswerable: group(records.filter { !$0.item.isAnswerable }),
            byType: Dictionary(grouping: records, by: { $0.item.type.rawValue }).mapValues(group),
            bySubtype: Dictionary(grouping: records, by: { "\($0.item.type.rawValue)/\($0.item.subtype)" }).mapValues(group),
            correctWhenFullyRecalled: Rate(full.filter { $0.judgment?.verdict == .correct }.count, of: full.count),
            correctWhenNotFullyRecalled: Rate(notFull.filter { $0.judgment?.verdict == .correct }.count, of: notFull.count),
            falseAbstention: Rate(answerableJudged.filter { $0.judgment?.abstained == true }.count, of: answerableJudged.count),
            unanswerableAnswered: Rate(
                judged.filter { !$0.item.isAnswerable && $0.judgment?.verdict != .correct }.count,
                of: judged.filter { !$0.item.isAnswerable }.count
            ),
            crossLingualAnsweredInQuestionLanguage: Rate(
                cross.filter { QAText.script(of: $0.answer?.answer ?? "") == $0.item.language }.count, of: cross.count
            ),
            latency: [
                "firstTextMs": Distribution(timings.compactMap(\.firstTextMs)),
                "totalMs": Distribution(timings.map(\.totalMs)),
                "preparationMs": Distribution(timings.map(\.preparationMs)),
                "memoryMs": Distribution(timings.map(\.memoryMs)),
                "prepareMs": Distribution(timings.map(\.prepareMs)),
            ],
            promptTokens: Distribution(timings.compactMap(\.promptTokens)),
            cachedPromptTokens: Distribution(timings.compactMap(\.cachedPromptTokens)),
            questionEvidenceOverlap: Distribution(dataset.items.map(\.maxOverlap)),
            failures: failures,
            judgeAdjustments: records.filter { $0.judgment?.adjustment != nil }.count,
            notes: notes
        )
    }

    // MARK: - Markdown

    static func percent(_ rate: Rate?) -> String {
        guard let rate, let value = rate.rate else { return "—" }
        return String(format: "%.1f%% (%d/%d)", value * 100, rate.count, rate.total)
    }

    static func number(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
    }

    /// 指标表（不含记忆正文）。
    public static func metricsMarkdown(_ s: Summary) -> String {
        var lines = [
            "| 分组 | 题数 | 证据召回 | 全部召回 | 来源召回 | 正确 | 部分正确 | 宽松得分 | 无依据回答 | 表示无记录 | 出错（管线/Judge） |",
            "|---|---|---|---|---|---|---|---|---|---|---|",
        ]
        func row(_ name: String, _ g: Group) {
            lines.append("| \(name) | \(g.questions) | \(number(g.evidenceRecall)) | \(percent(g.fullRecall)) | \(percent(g.sourceRecall)) | \(percent(g.correct)) | \(percent(g.partial)) | \(number(g.lenientScore)) | \(percent(g.ungrounded)) | \(percent(g.abstained)) | \(g.pipelineErrors)/\(g.judgeErrors) |")
        }
        row("**全部**", s.overall)
        row("可回答", s.answerable)
        row("无法回答", s.unanswerable)
        for type in QAQuestionType.allCases { if let g = s.byType[type.rawValue] { row(type.rawValue, g) } }
        for key in s.bySubtype.keys.sorted() { row("· \(key)", s.bySubtype[key]!) }
        lines.append("")
        lines.append("- 证据全部召回时正确率 \(percent(s.correctWhenFullyRecalled))；未全部召回时 \(percent(s.correctWhenNotFullyRecalled))")
        lines.append("- 可回答的题说没有记录：\(percent(s.falseAbstention))；无法回答的题没有正确处理：\(percent(s.unanswerableAnswered))")
        lines.append("- 跨语言题用提问语言作答（按文字判断）：\(percent(s.crossLingualAnsweredInQuestionLanguage))")
        lines.append("")
        lines.append("| 延迟（毫秒） | n | 平均 | p50 | p90 | 最大 |")
        lines.append("|---|---|---|---|---|---|")
        for key in ["firstTextMs", "totalMs", "preparationMs", "memoryMs", "prepareMs"] {
            guard let d = s.latency[key] else { continue }
            lines.append("| \(key) | \(d.n) | \(d.mean.map(String.init) ?? "—") | \(d.p50.map(String.init) ?? "—") | \(d.p90.map(String.init) ?? "—") | \(d.max.map(String.init) ?? "—") |")
        }
        lines.append("")
        lines.append("- 提示词 token：平均 \(s.promptTokens.mean.map(String.init) ?? "—")，p90 \(s.promptTokens.p90.map(String.init) ?? "—")；命中缓存的 token：平均 \(s.cachedPromptTokens.mean.map(String.init) ?? "—")")
        lines.append("- 问题与证据原文的最长公共片段（归一化字符数）：平均 \(s.questionEvidenceOverlap.mean.map(String.init) ?? "—")，最大 \(s.questionEvidenceOverlap.max.map(String.init) ?? "—")")
        lines.append("- Judge 判定与评分规则条款矛盾、按条款改正：\(s.judgeAdjustments) 道")
        lines.append("- 失败计数：" + (s.failures.isEmpty ? "无" : s.failures.keys.sorted().map { "\($0) \(s.failures[$0]!)" }.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }

    /// 完整报告：指标加失败案例（含记忆正文，只留在本机）。
    public static func markdown(summary s: Summary, records: [QARecord], dataset: QADataset) -> String {
        var lines = [
            "# 真实记忆问答评测",
            "",
            "> 本文件含真实记忆原文，只留在本机，不要上传或提交。",
            "",
            "- 评测中的\"现在\"：\(ISO8601DateFormatter().string(from: s.now)) · 记忆副本摘要 `\(s.memoryDigest.prefix(16))`",
            "- 被测模型 `\(s.answerer)` · 向量模型 `\(s.embedder)` · Judge `\(s.judge)` · 评分规则 `\(s.rubric)`\(s.rubricConsistent ? "" : " ⚠︎ 判定使用了不同版本的评分规则")",
            "- 出题模型 `\(s.questionGenerator.generator)`（\(s.questionGenerator.sendsDataOffDevice ? "离开本机" : "本地")）：\(s.questionGenerator.calls) 次调用，发出证据 \(s.questionGenerator.evidenceUnitsSent)/\(s.questionGenerator.evidenceUnitsTotal) 条、\(s.questionGenerator.charactersSent) 字符，脱敏 \(s.questionGenerator.redactions) 处；未能出题的槽位 \(s.unfilledSlots) 个",
        ]
        lines += s.notes.map { "- \($0)" }
        lines += ["", "## 指标", "", metricsMarkdown(s), ""]

        let evidence = Dictionary(dataset.evidence.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let failed = records.filter { !$0.failures.isEmpty }
        lines += ["## 失败案例（\(failed.count)）", ""]
        for failure in Failure.allCases {
            let group = failed.filter { $0.failures.first == failure.rawValue }
            guard !group.isEmpty else { continue }
            lines += ["### \(failure.rawValue) (\(group.count))", ""]
            for record in group { lines += describe(record, evidence: evidence) }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ record: QARecord, evidence: [String: QAEvidence]) -> [String] {
        let item = record.item
        var lines = ["#### \(item.id) · \(item.type.rawValue)/\(item.subtype) · \(item.conversation) 第 \(item.turn + 1) 轮", ""]
        lines.append("- **问题**：\(item.question)")
        lines.append("- **标准答案**：\(item.expectedAnswer)")
        lines.append("- **要点**：" + item.keyPoints.joined(separator: "; "))
        if !item.evidence.isEmpty {
            let recalled = Set(record.answer?.recalledEvidence ?? [])
            lines.append("- **证据**（召回 \(number(record.evidenceRecall))）：")
            for id in item.evidence {
                guard let unit = evidence[id] else { continue }
                lines.append("  - \(recalled.contains(id) ? "✓" : "✗") \(unit.labeled)")
            }
        }
        if !item.absentTerms.isEmpty { lines.append("- **记忆中不存在的词**：" + item.absentTerms.joined(separator: ", ")) }
        if let answer = record.answer {
            if let error = answer.error { lines.append("- **管线错误**：\(error)") }
            lines.append("- **来源**：" + (answer.sources.isEmpty ? "无" : answer.sources.joined(separator: ", ")))
            lines.append("- **回答**：" + answer.answer.replacingOccurrences(of: "\n", with: " ⏎ "))
        }
        if let j = record.judgment {
            if let error = j.error {
                lines.append("- **Judge**：失败（\(error)）")
            } else {
                if let adjustment = j.adjustment { lines.append("- **判定改正**：\(adjustment)") }
                lines.append("- **Judge**：\(j.verdict?.rawValue ?? "?"), abstained=\(j.abstained.map { String($0) } ?? "?") — \(j.rationale)")
                if !j.unsupportedClaims.isEmpty { lines.append("- **无依据的说法**：" + j.unsupportedClaims.joined(separator: " | ")) }
            }
        }
        lines.append("- **失败类别**：" + record.failures.joined(separator: ", "))
        lines.append("")
        return lines
    }
}

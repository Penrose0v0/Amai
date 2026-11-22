import AmaiCore
import Foundation

/// Judge 对一道题的判定。
public struct QAJudgment: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        case correct
        case partial
        case incorrect
    }

    public var item: String
    public var verdict: Verdict?
    /// 回答是否表示"没有记录 / 不知道"（同时又给出猜测时也算）。
    public var abstained: Bool?
    /// 以事实口吻陈述、但既不被证据原文也不被助手当时看到的记忆支持的关于用户的说法。
    public var unsupportedClaims: [String]
    public var rationale: String
    /// Judge 的判定与评分规则的明文条款自相矛盾、按条款改正时的说明（见 `QAJudge.enforceRubric`）。
    public var adjustment: String?
    /// Judge 没能给出合格判定时的原因（不含内容）。此时该题不计入依赖判定的指标，单独统计。
    public var error: String?
    public var judge: String
    public var rubric: String

    /// 是否属于"无依据回答"。
    public var isUngrounded: Bool { !unsupportedClaims.isEmpty }
}

/// 评分规则。**固定**：改动必须提升 `version`，并且不能为了某次评测的成绩而改。
/// 每次判定都记录规则的版本与 SHA-256，汇总时检查所有判定用的是同一份规则。
public enum QARubric {
    public static let version = "qa-rubric-v1"

    public static let system = """
    You are a strict, impartial grader. A personal AI assistant answered a question from its user about the user's own past, using the user's memory notes. You decide whether the assistant's answer is correct, using the REFERENCE ANSWER, KEY POINTS and the ORIGINAL EVIDENCE as ground truth.

    Grading rules:
    1. Language does not matter. Judge meaning, not wording. Any correct paraphrase or translation counts.
    2. For an ANSWERABLE question:
       - "correct": the answer contains every key point (dates must be the same day as the evidence when a key point involves a date) and states nothing that contradicts the reference or the evidence. Extra details that are true are fine.
       - "partial": at least one key point is present and none is contradicted, but another key point is missing; or the answer is right but includes a minor wrong detail.
       - "incorrect": the main key point is missing or wrong, the answer contradicts the evidence, or the assistant says it has no record / does not know.
    3. For an UNANSWERABLE question (the memory has no record of it, or the question rests on a false premise):
       - "correct": the assistant clearly says it has no record of this (or, for a false premise, that its memory does not support the premise) and does not present invented specifics as fact.
       - "partial": it says it is unsure or has no record, but still offers specific invented details as likely.
       - "incorrect": it answers as if the thing were recorded, or accepts the false premise.
    4. "abstained": true if the answer says it has no record, cannot find it, or does not know (even if it then guesses); otherwise false.
    5. "unsupported_claims": list every statement in the answer that is presented as a FACT about the user (what they did, said, decided, own, plan, or when) and that is supported by NEITHER the ORIGINAL EVIDENCE NOR the MEMORY SHOWN TO THE ASSISTANT. Do not list: general knowledge, restatements of the question, the assistant saying it has no record, or statements clearly marked as a guess or suggestion. Quote each claim briefly. Use an empty list when there are none.
    6. Do not reward length or confidence. Do not penalize brevity. Ignore formatting.

    Reply with ONLY one JSON object, no other text:
    {"verdict": "correct" | "partial" | "incorrect", "abstained": true | false, "unsupported_claims": ["..."], "rationale": "one or two sentences"}
    """

    public static var sha256: String { QAText.sha256(version + "\n" + system) }
    /// 记在每条判定上的规则标识：版本加摘要前缀。
    public static var id: String { "\(version)@\(sha256.prefix(12))" }

    /// Judge 看到的记忆最多这么多字符（截断时注明）。
    static let memoryLimit = 6000

    public static func prompt(
        item: QAItem, evidence: [QAEvidence], context: [QAEvidence], previous: [(question: String, answer: String)],
        memoryShown: String, answer: String
    ) -> String {
        var lines: [String] = []
        lines.append("QUESTION TYPE: " + (item.isAnswerable
            ? "ANSWERABLE"
            : "UNANSWERABLE (\(item.subtype == "falsePremise" ? "false premise" : "not in memory"))"))
        if !previous.isEmpty {
            lines.append("")
            lines.append("EARLIER TURNS OF THIS CONVERSATION:")
            for (index, turn) in previous.enumerated() {
                lines.append("User (\(index + 1)): \(turn.question)")
                lines.append("Assistant (\(index + 1)): \(turn.answer)")
            }
        }
        lines.append("")
        lines.append("QUESTION: \(item.question)")
        lines.append("")
        lines.append("REFERENCE ANSWER: \(item.expectedAnswer)")
        lines.append("KEY POINTS:")
        lines += item.keyPoints.map { "- \($0)" }
        lines.append("")
        lines.append("ORIGINAL EVIDENCE:")
        if evidence.isEmpty {
            lines.append(item.isAnswerable ? "(none)" : "(none: the memory has no record that answers this question)")
        } else {
            lines += evidence.map { "- \($0.labeled)" }
        }
        if !item.isAnswerable, !context.isEmpty {
            lines.append("Related memory that does NOT answer the question:")
            lines += context.map { "- \($0.labeled)" }
        }
        lines.append("")
        lines.append("MEMORY SHOWN TO THE ASSISTANT (retrieved for this conversation):")
        let shown = memoryShown.trimmingCharacters(in: .whitespacesAndNewlines)
        if shown.isEmpty {
            lines.append("(nothing)")
        } else if shown.count > memoryLimit {
            lines.append(String(shown.prefix(memoryLimit)) + "\n[… truncated]")
        } else {
            lines.append(shown)
        }
        lines.append("")
        lines.append("ASSISTANT'S ANSWER:")
        lines.append(answer.isEmpty ? "(empty)" : answer)
        return lines.joined(separator: "\n")
    }
}

/// 用一个独立的模型按 `QARubric` 判定。温度 0；输出不是合格 JSON 时重试一次。
public struct QAJudge: Sendable {
    public let model: any ChatModel

    public init(model: any ChatModel) {
        self.model = model
    }

    public func judge(
        item: QAItem, evidence: [QAEvidence], context: [QAEvidence], previous: [(question: String, answer: String)],
        memoryShown: String, answer: String
    ) async -> QAJudgment {
        let prompt = QARubric.prompt(
            item: item, evidence: evidence, context: context, previous: previous, memoryShown: memoryShown, answer: answer
        )
        var messages: [ChatMessage] = [.user(prompt)]
        var failure = "unparseable"
        for attempt in 0..<2 {
            let request = ChatRequest(system: QARubric.system, messages: messages, maxTokens: 700, temperature: 0, ephemeral: true)
            do {
                let raw = try await model.complete(request)
                if let judgment = Self.parse(raw, item: item.id, judge: model.identifier) {
                    return Self.enforceRubric(judgment, item: item)
                }
                failure = "unparseable"
                if attempt == 0 {
                    messages += [.assistant(raw), .user("That was not a valid JSON object in the required format. Reply with ONLY the JSON object.")]
                }
            } catch {
                failure = "judge error: \(String(describing: type(of: error)))"
                break
            }
        }
        return QAJudgment(
            item: item.id, verdict: nil, abstained: nil, unsupportedClaims: [], rationale: "", adjustment: nil, error: failure,
            judge: model.identifier, rubric: QARubric.id
        )
    }

    /// 按对话顺序判定数据集中已作答的题：追问看得到同一段对话之前的问答与累计给过的记忆。
    /// 跳过 `done` 中的题与作答出错的题。返回本次判定的题数。
    @discardableResult
    public func judgeAll(
        dataset: QADataset, answers: [String: QAAnswer], skipping done: Set<String> = [],
        record: (QAJudgment) throws -> Void
    ) async rethrows -> Int {
        var count = 0
        for conversation in dataset.conversations {
            var previous: [(question: String, answer: String)] = []
            var shown = ""
            for item in conversation {
                guard let answer = answers[item.id] else { continue }
                shown += (shown.isEmpty ? "" : "\n") + answer.memoryShown
                defer { previous.append((item.question, answer.answer)) }
                guard !done.contains(item.id), answer.error == nil else { continue }
                let judgment = await judge(
                    item: item, evidence: dataset.evidence(item.evidence), context: dataset.evidence(item.context),
                    previous: previous, memoryShown: shown, answer: answer.answer
                )
                try record(judgment)
                count += 1
            }
        }
        return count
    }

    static func parse(_ raw: String, item: String, judge: String) -> QAJudgment? {
        guard let object = QAJSON.object(in: raw),
              let verdict = (object["verdict"] as? String).flatMap({ QAJudgment.Verdict(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) })
        else { return nil }
        let abstained: Bool?
        switch object["abstained"] {
        case let value as Bool: abstained = value
        case let value as String: abstained = ["true", "yes"].contains(value.lowercased())
        default: abstained = nil
        }
        guard let abstained else { return nil }
        let claims = (object["unsupported_claims"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return QAJudgment(
            item: item, verdict: verdict, abstained: abstained, unsupportedClaims: claims,
            rationale: object["rationale"] as? String ?? "", adjustment: nil, error: nil, judge: judge, rubric: QARubric.id
        )
    }

    /// 规则第 2 条写明：可回答的题，助手说没有记录 / 不知道即为 incorrect。小模型 Judge 有时一边判 abstained=true
    /// 一边给 correct/partial；这里按条款机械改正，并记下改正，汇总里单独计数。
    /// 只执行规则已有的明文条款，不新增标准，也只会让判定更严。
    static func enforceRubric(_ judgment: QAJudgment, item: QAItem) -> QAJudgment {
        var judgment = judgment
        if item.isAnswerable, judgment.abstained == true, let verdict = judgment.verdict, verdict != .incorrect {
            judgment.adjustment = "rule 2: abstained on an answerable question, \(verdict.rawValue) → incorrect"
            judgment.verdict = .incorrect
        }
        return judgment
    }
}

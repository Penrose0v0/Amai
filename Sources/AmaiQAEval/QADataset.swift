import AmaiMemory
import CryptoKit
import Foundation

// 真实记忆问答评测的数据契约。
//
// 一次评测的所有文件都在一个工作目录里（不在仓库内）：
//   memory/          真实记忆的只读副本
//   support/index/   副本的派生索引
//   dataset.json     题目、标准答案与证据原文
//   answers.jsonl    被测管线的逐题输出
//   judgments.jsonl  Judge 的逐题判定
//   summary.json     汇总指标（不含任何记忆正文）
//   records.jsonl / report.md  逐题记录与失败案例（含记忆正文，只留在本机）

public enum QAQuestionType: String, Codable, Sendable, CaseIterable {
    /// 事实检索：措辞与记忆不同的改写问题。
    case fact
    /// 时间推理：相对日期、先后顺序、间隔、"什么时候"。
    case temporal
    /// 跨语言：用英文或日文问中文记忆里的事。
    case crossLingual
    /// 连续追问：同一段对话里的后续问题，依赖上文的指代（"那天""它"）。
    case followUp
    /// 无法回答：记忆里没有的事、没有记录的日期、与记忆矛盾的前提。
    case unanswerable
}

/// 一条可作为证据的记忆（取自副本，原文保留，供出题与 Judge 使用）。
public struct QAEvidence: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// 长期记忆文件中的一条条目。
        case item
        /// 时间线中的一个片段（标题与摘要）。
        case timelineEntry
        /// 日终摘要中的一行。
        case daySummary
        /// 用户手写内容中的一行。
        case userNote
    }

    public var id: String
    public var kind: Kind
    public var category: MemoryCategory
    /// 记忆目录下的相对路径。
    public var file: String
    public var section: String?
    /// 对应的日期（daily 是当天；长期记忆是最近的来源日期）。
    public var date: String?
    /// 时间线片段的起止时间（"09:00–12:10"）。
    public var time: String?
    public var text: String
    /// 用来判断"这条证据是否放进了提示词"的归一化文字片段，见 `QAText.fingerprint`。
    public var fingerprint: String

    public init(
        id: String, kind: Kind, category: MemoryCategory, file: String, section: String? = nil,
        date: String? = nil, time: String? = nil, text: String
    ) {
        self.id = id
        self.kind = kind
        self.category = category
        self.file = file
        self.section = section
        self.date = date
        self.time = time
        self.text = text
        self.fingerprint = QAText.fingerprint(text)
    }

    /// 给出题模型和 Judge 看的一行：`[daily/2026-11-06.md · 2026-11-06 09:00–12:10] 文字`。
    public var labeled: String {
        var where_ = file
        if let section, !section.isEmpty { where_ += " › \(section)" }
        var when = date ?? ""
        if let time { when += (when.isEmpty ? "" : " ") + time }
        return "[\(where_)\(when.isEmpty ? "" : " · \(when)")] \(text)"
    }
}

/// 一道题（连续追问的每一轮各算一道）。
public struct QAItem: Codable, Sendable, Equatable {
    public var id: String
    /// 同一段对话的题共用一个编号，按 `turn` 依次在同一个会话里提问；其余题各自一段新对话。
    public var conversation: String
    public var turn: Int
    public var type: QAQuestionType
    /// 细分类型，例如 relativeDate、ordering、absentEntity、noRecordDate、falsePremise。
    public var subtype: String
    /// 提问所用语言（zh / en / ja）。
    public var language: String
    public var question: String
    public var expectedAnswer: String
    /// 正确回答必须包含的要点（无法回答的题是期望的行为）。
    public var keyPoints: [String]
    /// 回答所需的证据编号。无法回答的题为空。
    public var evidence: [String]
    /// 出题时给出、但回答不需要的邻近记忆（无法回答的题用来说明"记忆里有什么"）。
    public var context: [String]
    /// 无法回答的题：在整个记忆副本中都不出现的关键词（生成后已校验）。
    public var absentTerms: [String]
    /// 问题与证据原文的最长公共片段（归一化后的字符数），用来排除照抄原文的题。
    public var maxOverlap: Int

    public init(
        id: String, conversation: String, turn: Int, type: QAQuestionType, subtype: String, language: String,
        question: String, expectedAnswer: String, keyPoints: [String], evidence: [String], context: [String],
        absentTerms: [String], maxOverlap: Int
    ) {
        self.id = id
        self.conversation = conversation
        self.turn = turn
        self.type = type
        self.subtype = subtype
        self.language = language
        self.question = question
        self.expectedAnswer = expectedAnswer
        self.keyPoints = keyPoints
        self.evidence = evidence
        self.context = context
        self.absentTerms = absentTerms
        self.maxOverlap = maxOverlap
    }

    public var isAnswerable: Bool { type != .unanswerable }
}

/// 出题时发往出题模型的内容统计（隐私审计用，不含内容本身）。
public struct QAEgress: Codable, Sendable, Equatable {
    public var generator: String = ""
    public var sendsDataOffDevice = false
    public var calls = 0
    /// 发出的不同证据条目数，以及占整个记忆副本条目数的比例。
    public var evidenceUnitsSent = 0
    public var evidenceUnitsTotal = 0
    public var charactersSent = 0
    /// 发出前被脱敏替换的片段数。
    public var redactions = 0

    public init() {}
}

public struct QADataset: Codable, Sendable {
    public var version = 1
    public var createdAt: Date
    /// 评测中的"现在"。被测会话的时钟固定在这一刻，"昨天""上周三"都相对它解释，结果可复现。
    public var now: Date
    public var timeZone: String
    /// 记忆副本的摘要（`QAWorkspace.digest`），保证题目与被测记忆是同一份。
    public var memoryDigest: String
    public var seed: UInt64
    public var evidence: [QAEvidence]
    public var items: [QAItem]
    public var egress: QAEgress
    /// 计划生成但没能产出合格题目的槽位数（多次重试后仍失败）。
    public var unfilledSlots: Int

    public init(
        createdAt: Date, now: Date, timeZone: String, memoryDigest: String, seed: UInt64,
        evidence: [QAEvidence], items: [QAItem], egress: QAEgress, unfilledSlots: Int
    ) {
        self.createdAt = createdAt
        self.now = now
        self.timeZone = timeZone
        self.memoryDigest = memoryDigest
        self.seed = seed
        self.evidence = evidence
        self.items = items
        self.egress = egress
        self.unfilledSlots = unfilledSlots
    }

    public func evidence(_ ids: [String]) -> [QAEvidence] {
        let table = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { table[$0] }
    }

    /// 按对话分组，组内按轮次排序；对话顺序与题目在数据集中的顺序一致。
    public var conversations: [[QAItem]] {
        var order: [String] = []
        var groups: [String: [QAItem]] = [:]
        for item in items {
            if groups[item.conversation] == nil { order.append(item.conversation) }
            groups[item.conversation, default: []].append(item)
        }
        return order.map { groups[$0]!.sorted { $0.turn < $1.turn } }
    }
}

// MARK: - Text

/// 评测中用到的文字处理：归一化、证据指纹、照抄检测。
public enum QAText {
    /// 只保留字母与数字（含汉字、假名），转小写。标点、空白、符号、列表符号、时间里的冒号都去掉，
    /// 这样同一条记忆在提示词里的不同排版（"- 09:00–12:10 标题 — 摘要" 与 "[timeline …] 09:00–12:10 标题 摘要"）归一化后一致。
    public static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 证据指纹：归一化后的前 24 个字符。提示词里的记忆可能被截断（"[…]"），只取开头更稳；
    /// 24 个字符足以区分不同的条目。
    public static let fingerprintLength = 24

    public static func fingerprint(_ text: String) -> String {
        String(normalize(text).prefix(fingerprintLength))
    }

    /// 两段文字（已归一化）的最长公共子串长度。
    public static func longestCommonSubstring(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        var best = 0
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }

    /// 回答主要用的是哪种文字：ja（含假名）、zh（汉字为主）、en（拉丁字母为主）。
    /// 只用于跨语言题"是否用提问的语言回答"的统计，不参与评分。
    public static func script(of text: String) -> String {
        var kana = 0, han = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: kana += 1
            case 0x4E00...0x9FFF: han += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        if kana >= 2 { return "ja" }
        if han == 0, latin == 0 { return "unknown" }
        return han * 2 >= latin ? "zh" : "en"
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
}

/// 可复现的伪随机数（SplitMix64）：同一个种子、同一份记忆副本得到同一组抽样。
public struct QARandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

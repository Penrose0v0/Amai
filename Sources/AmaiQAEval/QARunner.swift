import AmaiAssistant
import AmaiCore
import AmaiMemory
import Foundation

/// 被测管线对一道题的输出。
public struct QAAnswer: Codable, Sendable, Equatable {
    public var item: String
    public var answer: String
    /// 管线出错时的错误类型（不含内容）。
    public var error: String?
    /// 这一轮放进提示词的记忆来源（`MemorySource.id`）。
    public var sources: [String]
    /// 这一轮提示词里的 <memory> 块原文（Judge 判断"有无依据"时使用）。
    public var memoryShown: String
    /// 截至这一轮（含同一段对话的前几轮）出现在提示词里的证据编号——证据原文的指纹出现在记忆块中。
    public var recalledEvidence: [String]
    /// 截至这一轮，来源列表里包含其所在文件（daily 还要求日期一致）的证据编号。
    public var sourceMatchedEvidence: [String]
    public var timings: Timings

    public struct Timings: Codable, Sendable, Equatable {
        /// 提交到开始调用模型（检索记忆、组装提示词）。
        public var preparationMs = 0
        public var memoryMs = 0
        /// 提交到第一个字。
        public var firstTextMs: Int?
        /// 提交到回答完整结束。
        public var totalMs = 0
        /// 提交前的准备（面板唤出时的预热与预填充）用了多久。
        public var prepareMs = 0
        public var promptTokens: Int?
        public var cachedPromptTokens: Int?

        public init() {}
    }
}

/// 读取模型的缓存统计（本地 MLX 模型有；其他实现返回 nil）。
public typealias QAModelStats = @Sendable () async -> (promptTokens: Int, cachedTokens: Int)?

/// 让数据集里的题目逐一经过助手的真实问答管线（`AssistantSession`：后端检索记忆 → 组装提示词 → 模型流式生成）。
///
/// - 每段对话开始前 `reset()`，与界面上"新对话"相同；同一段对话的追问在同一个会话里依次提问；
/// - 每轮提交前先 `prepare()`，与界面在面板唤出和上一轮结束后做的一样（没有屏幕上下文：评测不读屏幕）；
/// - 会话的时钟固定在数据集的 `now`，"昨天""上周三"的解释可复现；
/// - 不写记忆，不保存会话记录。
public struct QARunner {
    public let dataset: QADataset
    public let session: AssistantSession
    public let stats: QAModelStats?

    public init(dataset: QADataset, session: AssistantSession, stats: QAModelStats? = nil) {
        self.dataset = dataset
        self.session = session
        self.stats = stats
    }

    /// 已经有结果的题跳过（中断后可以接着跑）；每完成一道调用一次 `record`。
    public func run(
        skipping done: Set<String> = [], record: (QAAnswer) throws -> Void, log: (String) -> Void = { _ in }
    ) async throws {
        let evidence = Dictionary(dataset.evidence.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let conversations = dataset.conversations
        for (index, conversation) in conversations.enumerated() {
            if conversation.allSatisfy({ done.contains($0.id) }) { continue }
            await session.reset()
            var shownSoFar = ""
            var sourcesSoFar: [MemorySource] = []
            for item in conversation {
                let prepareStarted = Date()
                await session.prepare()
                var answer = QAAnswer(
                    item: item.id, answer: "", error: nil, sources: [], memoryShown: "",
                    recalledEvidence: [], sourceMatchedEvidence: [], timings: .init()
                )
                answer.timings.prepareMs = Self.ms(since: prepareStarted)
                let started = Date()
                var turnSources: [MemorySource] = []
                do {
                    // 默认选项：与界面提交一致。会话没有屏幕读取器，上下文块里只有时间。
                    for try await event in session.send(item.question) {
                        if case .finished(let text, let sources) = event {
                            answer.answer = text
                            turnSources = sources
                        }
                    }
                } catch {
                    answer.error = String(describing: type(of: error))
                }
                answer.timings.totalMs = Self.ms(since: started)
                let timings = await session.lastTimings
                if answer.error == nil {
                    answer.timings.preparationMs = timings.preparationMs
                    answer.timings.memoryMs = timings.memoryMs
                    answer.timings.firstTextMs = timings.firstTextMs
                    if let stats = await stats?() {
                        answer.timings.promptTokens = stats.promptTokens
                        answer.timings.cachedPromptTokens = stats.cachedTokens
                    }
                    // 出错的轮次会从会话历史中撤回，所以只有成功的轮次才取提示词。
                    let transcript = await session.transcript
                    let prompt = transcript.last { $0.role == .user }?.text ?? ""
                    answer.memoryShown = Self.memoryBlock(in: prompt)
                }
                shownSoFar += "\n" + answer.memoryShown
                sourcesSoFar += turnSources
                answer.sources = turnSources.map(\.id)
                let needed = item.evidence.compactMap { evidence[$0] }
                answer.recalledEvidence = Self.recalled(needed, in: shownSoFar)
                answer.sourceMatchedEvidence = Self.sourceMatched(needed, sources: sourcesSoFar)
                try record(answer)
            }
            log("对话 \(index + 1)/\(conversations.count) 完成")
        }
    }

    static func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    /// 取出 `ContextBuilder.userMessage` 组装的 <memory> 块。
    static func memoryBlock(in prompt: String) -> String {
        guard let start = prompt.range(of: "<memory>\n"),
              let end = prompt.range(of: "\n</memory>", range: start.upperBound..<prompt.endIndex) else { return "" }
        return String(prompt[start.upperBound..<end.lowerBound])
    }

    /// 指纹出现在记忆文字中的证据。daily 的证据还要求出现在同一天的内容里：
    /// 反复出现的日常（"回复邮件"）在很多天都有，只比文字会把别的日子的条目算成召回。
    static func recalled(_ evidence: [QAEvidence], in memory: String) -> [String] {
        let lines = datedLines(memory)
        return evidence.filter { unit in
            guard !unit.fingerprint.isEmpty else { return false }
            return lines.contains { line in
                (unit.category != .daily || line.date == unit.date) && line.text.contains(unit.fingerprint)
            }
        }.map(\.id)
    }

    /// 记忆块按行归一化，并标出每一行属于哪一天（`MemoryRecall` 的三种写法）：
    /// "Timeline for D:" 段落里的行（直到下一个段落标题）、"- [timeline D] …"、日期区间里的 "- D: …"。
    static func datedLines(_ memory: String) -> [(date: String?, text: String)] {
        let dated = try! NSRegularExpression(pattern: #"^(Timeline for |- \[timeline |- )(\d{4}-\d{2}-\d{2})"#)
        var current: String?
        var result: [(date: String?, text: String)] = []
        for raw in memory.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let match = dated.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(match.range(at: 2), in: line) {
                let date = String(line[r])
                // 整天的时间线开启一个段落；单条检索结果与区间里的一天只标注自己这一行。
                current = line.hasPrefix("Timeline for ") ? date : nil
                result.append((date, QAText.normalize(line)))
                continue
            }
            if line.hasPrefix("Entries found") || line.hasPrefix("Daily records") || line.hasPrefix("- [") {
                current = nil
            }
            result.append((current, QAText.normalize(line)))
        }
        return result
    }

    /// 来源列表中包含其文件（daily 要求同一天；长期记忆在两边都有小节名时要求小节一致）的证据。
    static func sourceMatched(_ evidence: [QAEvidence], sources: [MemorySource]) -> [String] {
        evidence.filter { unit in
            sources.contains { source in
                guard source.file == unit.file else { return false }
                if unit.category == .daily { return source.date == unit.date }
                if let a = source.section, let b = unit.section, !a.isEmpty, !b.isEmpty { return a == b }
                return true
            }
        }.map(\.id)
    }
}

/// 固定在某一刻的时钟。
public struct QAFixedClock: AmaiClock {
    public let date: Date
    public init(date: Date) { self.date = date }
    public func now() -> Date { date }
    public func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

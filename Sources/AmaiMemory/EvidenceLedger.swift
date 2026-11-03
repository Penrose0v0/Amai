import AmaiCore
import Foundation

/// 一条可被整理结果引用的依据。依据的类型由**代码**根据它的来源决定，模型只能引用编号，
/// 不能声明依据类型（ADR-0006）。
public struct EvidenceEntry: Sendable, Equatable {
    public enum Basis: String, Sendable {
        /// 用户本人写下的内容：daily 中系统区块之外的手写部分，或分区文件的手写部分。
        case userStatement = "S"
        /// 采集元数据：某时段前台使用的应用（抽取层的 `fact` 观察），不含屏幕文字。
        case observation = "F"
        /// 抽取层的模型推断：活动片段的标题与摘要。
        case inference = "I"
        /// 已有记忆条目（General 汇总时引用各分区的条目），沿用该条目的依据。
        case memory = "M"
        /// 日终摘要（模型生成）。
        case digest = "D"
    }

    public let id: String
    public let basis: Basis
    /// 依据所属日期（YYYY-MM-DD），整理结果的来源日期由此得出。
    public let day: String
    public let text: String
    /// `observation` 依据涉及的应用名。
    public let apps: [String]
    /// `memory` 依据的原条目依据类型。
    public let memoryKind: MemoryEntryKind?
    /// `memory` 依据的原条目来源日期；引用它的条目继承这些来源。
    public let sourceDays: [String]

    public init(id: String, basis: Basis, day: String, text: String, apps: [String] = [], memoryKind: MemoryEntryKind? = nil, sourceDays: [String] = []) {
        self.id = id
        self.basis = basis
        self.day = day
        self.text = text
        self.apps = apps
        self.memoryKind = memoryKind
        self.sourceDays = sourceDays
    }
}

/// 整理时提供给模型的依据清单，以及从引用推导依据类型的规则。
public struct EvidenceLedger: Sendable, Equatable {
    public private(set) var entries: [EvidenceEntry] = []

    public init(entries: [EvidenceEntry] = []) {
        self.entries = entries
    }

    public subscript(id: String) -> EvidenceEntry? {
        entries.first { $0.id == id.trimmingCharacters(in: .whitespaces) }
    }

    public var hasUserStatements: Bool { entries.contains { $0.basis == .userStatement } }

    @discardableResult
    public mutating func append(
        _ basis: EvidenceEntry.Basis, prefix: String? = nil, day: String, text: String,
        apps: [String] = [], memoryKind: MemoryEntryKind? = nil, sourceDays: [String] = []
    ) -> String {
        let p = prefix ?? basis.rawValue
        let n = entries.filter { $0.id.hasPrefix(p) && Int($0.id.dropFirst(p.count)) != nil }.count + 1
        entries.append(EvidenceEntry(id: "\(p)\(n)", basis: basis, day: day, text: text, apps: apps, memoryKind: memoryKind, sourceDays: sourceDays))
        return "\(p)\(n)"
    }

    // MARK: - Kind derivation

    public struct Derivation: Sendable, Equatable {
        public let kind: MemoryEntryKind
        public let sources: [String]
        /// 实际被采纳的依据编号。
        public let cited: [String]
    }

    /// 根据引用推导条目的依据类型与来源日期：
    /// - 只看引用的依据**从哪里来**，不看模型怎么说；
    /// - 用户陈述（S/U）要求条目内容确实出自该陈述（字符二元组覆盖率），转述过度时按推断处理；
    /// - 采集元数据（F）要求条目提到其中的应用，否则不采纳该引用；
    /// - 多个依据取最弱的一个（unknown < inferred < observed < stated），由汇总得到的条目不会是 confirmed；
    /// - 没有任何可采纳的依据时返回 nil：调用方应当拒绝写入。
    public func derive(text: String, citing ids: [String]) -> Derivation? {
        var kinds: [MemoryEntryKind] = []
        var days: Set<String> = []
        var cited: [String] = []
        for id in ids {
            guard let e = self[id], !cited.contains(e.id) else { continue }
            let kind: MemoryEntryKind
            switch e.basis {
            case .userStatement:
                kind = Self.coverage(of: text, in: e.text) >= Self.statementCoverage ? .stated : .inferred
            case .observation:
                guard e.apps.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { continue }
                kind = .observed
            case .inference, .digest:
                kind = .inferred
            case .memory:
                let k = e.memoryKind ?? .unknown
                kind = k == .confirmed ? .stated : k
            }
            kinds.append(kind)
            if e.sourceDays.isEmpty { days.insert(e.day) } else { days.formUnion(e.sourceDays) }
            cited.append(e.id)
        }
        guard let weakest = kinds.min(by: { $0.rank < $1.rank }) else { return nil }
        return Derivation(kind: weakest, sources: days.filter(MemoryItems.isDate).sorted(), cited: cited)
    }

    /// 条目文字中有多少比例的字符二元组出现在陈述里。只用来**降低**依据等级，不用来授予依据。
    static let statementCoverage = 0.4
    static let framingPattern = #"\d{4}\s*[-年./]\s*\d{1,2}\s*(月|[-./])?\s*(\d{1,2}\s*日?)?(中旬|上旬|下旬)?(那一周|那周|当天)?|用户(本人)?(自述|表示|提到|称|说)?|自述|据用户"#

    static func coverage(of text: String, in source: String) -> Double {
        // 日期与"用户表示"这类转述框架不构成新的说法，计算覆盖率前去掉。
        let framed = text.replacingOccurrences(of: framingPattern, with: "", options: .regularExpression)
        let a = Array(MemoryItems.normalize(framed))
        let b = MemoryItems.normalize(source)
        guard a.count >= 2 else { return a.isEmpty ? 0 : (b.contains(a[0]) ? 1 : 0) }
        var sourceGrams = Set<String>()
        let bs = Array(b)
        if bs.count >= 2 { for i in 0..<(bs.count - 1) { sourceGrams.insert(String(bs[i...i + 1])) } }
        var hit = 0
        for i in 0..<(a.count - 1) where sourceGrams.contains(String(a[i...i + 1])) { hit += 1 }
        return Double(hit) / Double(a.count - 1)
    }

    // MARK: - Building

    /// 某一天的依据：用户在 daily 中手写的内容（S）、每个活动片段的应用（F）与模型描述（I）。
    /// 低置信度与兜底片段不作为推断依据。没有片段数据时（例如抽取数据已删除）退回解析 daily 时间线。
    public static func forDay(
        day: String,
        daily: String?,
        segments: [ActivitySegment],
        observations: [Observation],
        timeZone: TimeZone
    ) -> EvidenceLedger {
        var ledger = EvidenceLedger()
        for line in userLines(inDaily: daily ?? "") {
            ledger.append(.userStatement, day: day, text: line)
        }
        let facts = Dictionary(grouping: observations.filter { $0.kind == .fact }, by: \.id)
        let included = segments.filter(TimelineBlock.includes).sorted { $0.timeRange.start < $1.timeRange.start }
        if included.isEmpty {
            for line in timelineLines(daily ?? "") { ledger.append(.inference, day: day, text: line) }
        }
        for s in included {
            let range = "\(hhmm(s.timeRange.start, timeZone))–\(hhmm(s.timeRange.end, timeZone))"
            var apps: [String] = []
            for id in s.observations {
                for o in facts[id] ?? [] {
                    if let app = o.attributes["app"], !apps.contains(app) { apps.append(app) }
                }
            }
            if !apps.isEmpty {
                ledger.append(.observation, day: day, text: "\(range) 前台应用：\(apps.joined(separator: "、"))", apps: apps)
            }
            guard !TimelineBlock.isLowConfidence(s) else { continue }
            let summary = TimelineBlock.sanitize(s.summary)
            let title = TimelineBlock.sanitize(s.title)
            ledger.append(.inference, day: day, text: summary.isEmpty ? "\(range) \(title)" : "\(range) \(title)：\(summary)")
        }
        return ledger
    }

    /// daily 中系统区块之外、由用户写下的内容，逐行（去掉标题、空行与列表符号）。
    static func userLines(inDaily text: String) -> [String] {
        var rest = text
        for block in [Consolidator.digestBlock, TimelineBlock.block] { rest = block.removing(from: rest) }
        return contentLines(rest)
    }

    /// Markdown 中的正文行：去掉标题、空行、列表符号与 HTML 注释；每行最多 300 字，最多 60 行。
    static func contentLines(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            line = line.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
            for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
                break
            }
            line = SecretRedactor.redact(line.trimmingCharacters(in: .whitespaces)).text
            if !line.isEmpty { lines.append(String(line.prefix(300))) }
            if lines.count >= 60 { break }
        }
        return lines
    }

    private static func timelineLines(_ daily: String) -> [String] {
        guard let body = TimelineBlock.block.content(in: daily) else { return [] }
        return body.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- "), !line.contains(TimelineBlock.lowConfidenceTag) else { return nil }
            let text = line.dropFirst(2).replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    /// 给模型看的依据清单。
    public func render() -> String {
        let groups: [(EvidenceEntry.Basis, String)] = [
            (.userStatement, "用户本人写下的内容（S/U，用户陈述）"),
            (.observation, "采集元数据（F，可直接核对的事实：时段与前台应用）"),
            (.inference, "屏幕活动的模型描述（I，推断）"),
            (.digest, "日终摘要（D，推断）"),
            (.memory, "已有记忆条目（M，括号内为该条目的依据类型）"),
        ]
        var parts: [String] = []
        for (basis, title) in groups {
            let list = entries.filter { $0.basis == basis }
            guard !list.isEmpty else { continue }
            parts.append(title + "：")
            for e in list {
                let kind = e.memoryKind.map { "（\($0.rawValue)）" } ?? ""
                parts.append("[\(e.id)] \(e.day) \(e.text)\(kind)")
            }
        }
        return parts.isEmpty ? "（无）" : parts.joined(separator: "\n")
    }

    private static func hhmm(_ date: Date, _ timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

extension MemoryEntryKind {
    /// 依据强弱，用于"取最弱"与"不得以弱覆盖强"。confirmed 只能来自用户确认。
    public var rank: Int {
        switch self {
        case .unknown: 0
        case .inferred: 1
        case .observed: 2
        case .stated: 3
        case .confirmed: 4
        }
    }
}

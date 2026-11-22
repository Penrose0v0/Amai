import AmaiCore
import AmaiMemory
import AmaiQAEval
import Foundation

/// 合成记忆语料（eval/benchmark/fixtures/synthetic-memory.json）：用正式的 `MemoryStore` 写出时间线，
/// 长期记忆文件按 Schema v1 的格式原样写入。
public struct SyntheticCorpusSpec: Codable, Sendable {
    public struct Event: Codable, Sendable {
        public var id: String
        public var date: String
        public var title: String
        public var summary: String
        public var category: ActivityCategory
    }

    public var name: String
    public var description: String
    public var now: Date
    public var timeZone: String
    public var seed: UInt64
    public var firstDay: String
    public var lastDay: String
    public var routinesPerDay: Int
    public var routines: [String]
    public var events: [Event]
    public var documents: [String: String]
}

/// 手写的题目（eval/benchmark/fixtures/synthetic-qa.json）。
public struct SyntheticQASpec: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var id: String
        public var type: QAQuestionType
        public var subtype: String
        public var language: String
        public var question: String
        public var expectedAnswer: String
        public var keyPoints: [String]
        /// 必需的信息点；每个信息点列出能提供它的记录片段（任意一条即可）。
        public var evidence: [[String]]
        public var context: [[String]]?
        public var absentTerms: [String]?
        public var conversation: String?
        public var turn: Int?
        /// 只用于检索的噪声评测（与记忆无关的问题），不参与问答。
        public var retrievalOnly: Bool?
    }

    public var name: String
    public var corpus: String
    public var description: String
    public var items: [Item]
}

public struct SyntheticCorpus: Sendable {
    public var root: URL
    public var spec: SyntheticCorpusSpec
    public var catalog: EvidenceCatalog
    public var timeZone: TimeZone
    /// 全部题目（含只用于检索的）。
    public var retrievalDataset: QADataset
    /// 问答用的题目。
    public var qaDataset: QADataset
    public var groundTruth: QAGroundTruth

    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 写出语料并解析题目。题目引用的片段找不到、或"不存在的词"其实存在时报错（数据集本身有问题）。
    public static func build(corpus corpusURL: URL, questions questionsURL: URL, at root: URL) async throws -> SyntheticCorpus {
        let spec = try decoder().decode(SyntheticCorpusSpec.self, from: Data(contentsOf: corpusURL))
        let qa = try decoder().decode(SyntheticQASpec.self, from: Data(contentsOf: questionsURL))
        let timeZone = TimeZone(identifier: spec.timeZone) ?? .current
        try await write(spec, to: root, timeZone: timeZone)
        let catalog = try EvidenceCatalog.build(root: root, timeZone: timeZone)

        func resolve(_ snippet: String, item: String) throws -> [QAEvidence] {
            let needle = QAText.normalize(snippet)
            let hits = catalog.units.filter { QAText.normalize($0.text).contains(needle) }
            guard !hits.isEmpty else { throw Invalid(description: "\(item)：记忆语料里找不到「\(snippet)」") }
            return hits
        }

        var items: [QAItem] = []
        var gt: [String: QAGroundTruth.Entry] = [:]
        var referenced: [String: QAEvidence] = [:]
        for q in qa.items {
            // 每个信息点：所有能提供它的记录（替代记录）。题目的 evidence 只取每个信息点的第一条（优先时间线），
            // 证据召回按它计算；检索的 GT 认任意一条。
            var requirements: [[QAEvidence]] = []
            for alternatives in q.evidence {
                var units: [QAEvidence] = []
                for snippet in alternatives { units += try resolve(snippet, item: q.id) }
                var seen = Set<String>()
                units = units.filter { seen.insert($0.id).inserted }
                    .sorted { ($0.kind == .timelineEntry ? 0 : 1, $0.id) < ($1.kind == .timelineEntry ? 0 : 1, $1.id) }
                requirements.append(units)
            }
            let context = try (q.context ?? []).flatMap { try $0.flatMap { try resolve($0, item: q.id) } }
            for term in q.absentTerms ?? [] where catalog.mentions(term) {
                throw Invalid(description: "\(q.id)：标为不存在的词「\(term)」其实出现在语料中")
            }
            for u in requirements.flatMap({ $0 }) + context { referenced[u.id] = u }
            let evidence = requirements.compactMap(\.first)
            let overlap = evidence.map { QAText.longestCommonSubstring(QAText.normalize(q.question), QAText.normalize($0.text)) }.max() ?? 0
            items.append(QAItem(
                id: q.id, conversation: q.conversation ?? q.id, turn: q.turn ?? 1, type: q.type, subtype: q.subtype,
                language: q.language, question: q.question, expectedAnswer: q.expectedAnswer, keyPoints: q.keyPoints,
                evidence: evidence.map(\.id), context: context.map(\.id), absentTerms: q.absentTerms ?? [], maxOverlap: overlap
            ))
            if q.type != .unanswerable {
                gt[q.id] = QAGroundTruth.Entry(requirements: requirements.map { $0.map(QAGroundTruth.unit(for:)) }, excluded: nil, note: nil)
            }
        }

        let digest = Self.digest(root)
        var egress = QAEgress()
        egress.generator = "hand-written (\(qa.name))"
        func dataset(_ items: [QAItem]) -> QADataset {
            QADataset(
                createdAt: spec.now, now: spec.now, timeZone: spec.timeZone, memoryDigest: digest, seed: spec.seed,
                evidence: catalog.units.filter { referenced[$0.id] != nil }, items: items, egress: egress, unfilledSlots: 0
            )
        }
        let qaOnly = Set(qa.items.filter { $0.retrievalOnly == true }.map(\.id))
        return SyntheticCorpus(
            root: root, spec: spec, catalog: catalog, timeZone: timeZone,
            retrievalDataset: dataset(items), qaDataset: dataset(items.filter { !qaOnly.contains($0.id) }),
            groundTruth: QAGroundTruth(source: .synthetic, annotator: nil, annotatedAt: nil, memoryDigest: digest, items: gt)
        )
    }

    static func write(_ spec: SyntheticCorpusSpec, to root: URL, timeZone: TimeZone) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MemoryStore(root: root, timeZone: timeZone)
        for (file, text) in spec.documents {
            try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func day(_ s: String) -> Date {
            let p = s.split(separator: "-").compactMap { Int($0) }
            return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
        }
        // 与原检索语料相同的线性同余随机数，种子固定：每次生成的语料完全一致。
        var seed = spec.seed
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var date = day(spec.firstDay)
        let last = day(spec.lastDay)
        while date <= last {
            let name = MemoryDirectory.dayName(for: date, timeZone: timeZone)
            var entries: [(title: String, summary: String, category: ActivityCategory)] =
                (0..<spec.routinesPerDay).map { _ in (spec.routines[random(spec.routines.count)], "", .work) }
            for e in spec.events where e.date == name {
                entries.insert((e.title, e.summary, e.category), at: random(entries.count))
            }
            let dayNumber = Int(date.timeIntervalSince1970 / 86_400)
            let segments = entries.enumerated().map { index, e in
                let start = date.addingTimeInterval(Double(9 + index) * 3600)
                // 片段 id 会写进时间线（seg:…），必须确定，语料的摘要才可复现。
                let id = UUID(uuidString: String(format: "00000000-0000-0000-%04X-%012X", index, dayNumber))!
                return ActivitySegment(
                    id: id, timeRange: TimeRange(start: start, end: start.addingTimeInterval(3600)), title: e.title, summary: e.summary,
                    category: e.category, apps: [], observations: [], confidence: 0.8, provider: "bench:synthetic", updatedAt: start
                )
            }
            _ = try await store.writeDailyTimeline(day: date, segments: segments)
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
    }

    /// 记忆目录的摘要（所有 Markdown 文件的相对路径与内容）。
    static func digest(_ root: URL) -> String {
        var parts: [String] = []
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == "md" {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
                parts.append("\(relative)\t\((try? String(contentsOf: url, encoding: .utf8)) ?? "")")
            }
        }
        return QAText.sha256(parts.sorted().joined(separator: "\n"))
    }
}

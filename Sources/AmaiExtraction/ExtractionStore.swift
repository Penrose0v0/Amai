import AmaiCore
import Foundation

/// 抽取结果的本地存储（docs/architecture.md §4 的 `extracted/`）。
///
/// ```
/// extracted/
/// ├── state.json                 处理水位线
/// └── YYYY-MM-DD/
///     ├── observations.jsonl     观察，一行一个，只追加（删除时整体重写）
///     └── segments.json          活动片段数组，按开始时间排序，按 id 覆盖更新
/// ```
/// 片段归属于其开始时间所在的日期；跨窗口延续时 id 与开始时间不变。
public actor ExtractionStore {
    public struct State: Codable, Sendable, Equatable {
        public var processedUntil: Date?
        public var version = 1

        public init(processedUntil: Date? = nil) {
            self.processedUntil = processedUntil
        }
    }

    public let root: URL
    private let calendar: Calendar
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL, timeZone: TimeZone = .current) throws {
        self.root = root
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - State

    public func loadState() -> State {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let state = try? decoder.decode(State.self, from: data)
        else { return State() }
        return state
    }

    public func saveState(_ state: State) throws {
        try encoder.encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }

    // MARK: - Observations

    public func append(_ observations: [Observation]) throws {
        let byDay = Dictionary(grouping: observations) { dayName($0.timeRange.start) }
        for (day, items) in byDay {
            let url = try dayDirectory(day).appendingPathComponent("observations.jsonl")
            var data = Data()
            for item in items {
                data.append(try encoder.encode(item))
                data.append(0x0A)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        }
    }

    public func observations(on date: Date) -> [Observation] {
        let url = root.appendingPathComponent(dayName(date)).appendingPathComponent("observations.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Observation.self, from: $0) }
    }

    public func observations(ids: Set<UUID>, on date: Date) -> [Observation] {
        observations(on: date).filter { ids.contains($0.id) }
    }

    // MARK: - Segments

    public func segments(on date: Date) -> [ActivitySegment] {
        let url = root.appendingPathComponent(dayName(date)).appendingPathComponent("segments.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([ActivitySegment].self, from: data)) ?? []
    }

    public func upsert(_ segment: ActivitySegment) throws {
        let day = dayName(segment.timeRange.start)
        var list = segments(on: segment.timeRange.start).filter { $0.id != segment.id }
        list.append(segment)
        list.sort { $0.timeRange.start < $1.timeRange.start }
        let url = try dayDirectory(day).appendingPathComponent("segments.json")
        try encoder.encode(list).write(to: url, options: .atomic)
    }

    /// 结束时间不晚于 `date` 的最近一个片段（查当天与前一天）。
    public func latestSegment(endingAtOrBefore date: Date) -> ActivitySegment? {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        return (segments(on: yesterday) + segments(on: date))
            .filter { $0.timeRange.end <= date }
            .max { $0.timeRange.end < $1.timeRange.end }
    }

    /// 删除片段及其关联的观察。原始帧不在这里删除，由 RawSpool 的保留策略处理。
    public func deleteSegment(id: UUID, on date: Date) throws {
        let day = dayName(date)
        let all = segments(on: date)
        guard let target = all.first(where: { $0.id == id }) else { return }
        let dir = try dayDirectory(day)
        try encoder.encode(all.filter { $0.id != id }).write(
            to: dir.appendingPathComponent("segments.json"), options: .atomic
        )
        let drop = Set(target.observations)
        let kept = observations(on: date).filter { !drop.contains($0.id) }
        var data = Data()
        for item in kept {
            data.append(try encoder.encode(item))
            data.append(0x0A)
        }
        try data.write(to: dir.appendingPathComponent("observations.jsonl"), options: .atomic)
    }

    /// 在最近若干天的片段中按文字检索：标题、摘要、应用，以及关联观察的内容（含 OCR 文本）。
    public func search(_ query: String, endingOn date: Date, days: Int = 7) -> [ActivitySegment] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var hits: [ActivitySegment] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            let segs = segments(on: day)
            guard !segs.isEmpty else { continue }
            let obsText = Dictionary(
                observations(on: day).map { ($0.id, $0.content.lowercased()) },
                uniquingKeysWith: { a, _ in a }
            )
            for seg in segs {
                let direct = [seg.title, seg.summary, seg.apps.joined(separator: " ")]
                    .contains { $0.lowercased().contains(q) }
                let viaObs = seg.observations.contains { obsText[$0]?.contains(q) == true }
                if direct || viaObs { hits.append(seg) }
            }
        }
        return hits.sorted { $0.timeRange.start > $1.timeRange.start }
    }

    // MARK: - Helpers

    private func dayName(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func dayDirectory(_ day: String) throws -> URL {
        let url = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

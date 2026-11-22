import AmaiCore
import Foundation
import os

/// 抽取结果的本地存储（docs/architecture.md §4 的 `extracted/`）。
///
/// ```
/// extracted/
/// ├── state.json                 处理水位线
/// ├── pending-commit.json        一批结果的预写日志（只在提交过程中存在，见 `commit`）
/// └── YYYY-MM-DD/
///     ├── observations.jsonl     观察，一行一个，只追加（删除时整体重写）；同一 id 只保留一条
///     ├── segments.json          活动片段数组，按开始时间排序，按 id 覆盖更新
///     └── segments.corrupt-*.json  读不出的 segments.json 被移到这里保留，不被覆盖
/// ```
/// 片段归属于其开始时间所在的日期；跨窗口延续时 id 与开始时间不变。
public actor ExtractionStore {
    /// 一批窗口处理的全部结果。由 `commit` 与水位线一起原子提交。
    public struct BatchOutput: Codable, Sendable, Equatable {
        public var observations: [Observation]
        public var segments: [ActivitySegment]

        public init(observations: [Observation] = [], segments: [ActivitySegment] = []) {
            self.observations = observations
            self.segments = segments
        }
    }

    /// 预写日志的内容：结果与提交后的水位线。
    private struct PendingCommit: Codable {
        var output: BatchOutput
        var state: State
    }

    /// 最近删除过的时间段。删除与抽取并发时（抽取读到帧之后、提交结果之前用户删除了这段时间），
    /// 提交时据此丢弃落在已删除时间段内的结果。只在进程内有效：进程退出后，正在处理的那一批也随之丢弃，
    /// 而原始数据已删除，重启后不会再读到这些帧。
    private struct Tombstone {
        let range: TimeRange
        let recordedAt: Date
    }
    private var tombstones: [Tombstone] = []
    /// 墓碑只需覆盖"删除前已开始、删除后才提交"的一批；一批处理再慢也远短于这个时长。
    static let tombstoneLifetime: TimeInterval = 24 * 3600
    static let maxTombstones = 64

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
    private let clock: any AmaiClock
    private let log = AmaiLog.logger("extraction.store")

    public init(root: URL, timeZone: TimeZone = .current, clock: any AmaiClock = SystemClock()) throws {
        self.root = root
        self.clock = clock
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
        recoverPendingCommit()
        return readState()
    }

    private func readState() -> State {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let state = try? decoder.decode(State.self, from: data)
        else { return State() }
        return state
    }

    public func saveState(_ state: State) throws {
        try encoder.encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }

    // MARK: - Observations

    /// 追加观察。已存在的 id 跳过，重放同一批结果（崩溃恢复）时不会出现重复。
    public func append(_ observations: [Observation]) throws {
        let byDay = Dictionary(grouping: observations) { dayName($0.timeRange.start) }
        for (day, items) in byDay {
            let url = try dayDirectory(day).appendingPathComponent("observations.jsonl")
            var seen = Set(readObservations(url).map(\.id))
            var data = Data()
            for item in items where seen.insert(item.id).inserted {
                data.append(try encoder.encode(item))
                data.append(0x0A)
            }
            guard !data.isEmpty else { continue }
            try AppendOnlyFile.append(data, to: url)
        }
    }

    public func observations(on date: Date) -> [Observation] {
        readObservations(root.appendingPathComponent(dayName(date)).appendingPathComponent("observations.jsonl"))
    }

    private func readObservations(_ url: URL) -> [Observation] {
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
        var list = try segmentsForWriting(day).filter { $0.id != segment.id }
        list.append(segment)
        list.sort { $0.timeRange.start < $1.timeRange.start }
        let url = try dayDirectory(day).appendingPathComponent("segments.json")
        try encoder.encode(list).write(to: url, options: .atomic)
    }

    /// 写入前读取某天的片段。文件存在却读不出（损坏、或将来版本的格式）时，先把它移到
    /// `segments.corrupt-<时间>.json` 保留，再从空列表开始——不能用空列表直接覆盖，否则这一天已有的片段会被静默丢弃。
    private func segmentsForWriting(_ day: String) throws -> [ActivitySegment] {
        let dir = root.appendingPathComponent(day, isDirectory: true)
        let url = dir.appendingPathComponent("segments.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let list = try? decoder.decode([ActivitySegment].self, from: data) { return list }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let aside = dir.appendingPathComponent("segments.corrupt-\(f.string(from: Date())).json")
        try FileManager.default.moveItem(at: url, to: aside)
        log.error("unreadable segments file moved aside: \(aside.lastPathComponent, privacy: .public)")
        return []
    }

    // MARK: - Commit

    /// 原子地提交一批结果并推进水位线。
    ///
    /// 先把结果与新水位线写进预写日志（一次原子写），再写观察、片段、水位线，最后删除日志。
    /// 任何一步之后退出，下次 `loadState` / `commit` 都会从日志补完（观察按 id 去重、片段按 id 覆盖，重放是幂等的）；
    /// 日志写入之前退出则什么都没写，重启后这一批整批重做。因此同一批不会写两遍。
    ///
    /// 落在最近删除过的时间段内的结果在提交时丢弃（见 `Tombstone`）。返回实际写入的片段数。
    @discardableResult
    public func commit(_ output: BatchOutput, state: State) throws -> Int {
        recoverPendingCommit()
        // 水位线已经越过：这一批已由日志补完提交过（例如上次提交在应用中途失败后重试）。
        if let done = readState().processedUntil, let next = state.processedUntil, done >= next { return 0 }
        let kept = withoutErased(output)
        let journal = root.appendingPathComponent("pending-commit.json")
        try encoder.encode(PendingCommit(output: kept, state: state)).write(to: journal, options: .atomic)
        try apply(kept, state: state)
        try FileManager.default.removeItem(at: journal)
        return kept.segments.count
    }

    private func apply(_ output: BatchOutput, state: State) throws {
        try append(output.observations)
        for segment in output.segments { try upsert(segment) }
        try saveState(state)
    }

    /// 上次提交在写完日志之后、删除日志之前中断：补完它。日志读不出（不应发生：它是原子写入的）时丢弃。
    private func recoverPendingCommit() {
        let journal = root.appendingPathComponent("pending-commit.json")
        guard let data = try? Data(contentsOf: journal) else { return }
        do {
            let pending = try decoder.decode(PendingCommit.self, from: data)
            try apply(pending.output, state: pending.state)
            try FileManager.default.removeItem(at: journal)
            log.notice("recovered an interrupted extraction commit")
        } catch {
            log.error("pending commit recovery failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// 去掉与最近删除的时间段重叠的片段（及其观察）和开始于其中的观察，规则与 `deleteData` 一致。
    private func withoutErased(_ output: BatchOutput) -> BatchOutput {
        let now = clock.now()
        tombstones.removeAll { now.timeIntervalSince($0.recordedAt) > Self.tombstoneLifetime }
        guard !tombstones.isEmpty else { return output }
        let ranges = tombstones.map(\.range)
        let dropped = output.segments.filter { s in ranges.contains { $0.start <= s.timeRange.end && $0.end >= s.timeRange.start } }
        let droppedIds = Set(dropped.map(\.id))
        let doomedObservations = Set(dropped.flatMap(\.observations))
        guard !dropped.isEmpty || output.observations.contains(where: { o in ranges.contains { $0.contains(o.timeRange.start) } }) else {
            return output
        }
        log.info("dropped \(dropped.count) segment(s) of a batch that overlaps erased data")
        return BatchOutput(
            observations: output.observations.filter { o in
                !doomedObservations.contains(o.id) && !ranges.contains { $0.contains(o.timeRange.start) }
            },
            segments: output.segments.filter { !droppedIds.contains($0.id) }
        )
    }

    private func recordTombstone(_ range: TimeRange) {
        let now = clock.now()
        // 删除只针对已经发生的时间；删除之后才采集到的数据（时间段延伸到未来时）不受影响。
        let end = min(range.end, now)
        guard end >= range.start else { return }
        tombstones.append(Tombstone(range: TimeRange(start: range.start, end: end), recordedAt: now))
        if tombstones.count > Self.maxTombstones { tombstones.removeFirst(tombstones.count - Self.maxTombstones) }
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
        let all = try segmentsForWriting(day)
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

    /// 最近 `days` 天内有片段在 `after` 之后更新的日期（当天 00:00）及其中最新的 `updatedAt`。
    /// 记忆层据此增量同步。
    public func daysWithUpdates(after: Date?, endingOn date: Date, days: Int) -> [(day: Date, latestUpdate: Date)] {
        var result: [(Date, Date)] = []
        for offset in 0..<max(1, days) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            let updates = segments(on: day).map(\.updatedAt).filter { after == nil || $0 > after! }
            if let latest = updates.max() {
                result.append((calendar.startOfDay(for: day), latest))
            }
        }
        return result
    }

    /// 删除与时间段重叠的全部片段及其观察，以及落在时间段内的其余观察。返回受影响的日期（当天 00:00）。
    @discardableResult
    public func deleteData(overlapping range: TimeRange) throws -> [Date] {
        // 先记下墓碑：之后提交的、正在处理中的那一批若落在这段时间内会被丢弃。
        recordTombstone(range)
        var affected: [Date] = []
        var day = calendar.startOfDay(for: range.start)
        let lastDay = calendar.startOfDay(for: range.end)
        // 片段可能从前一天开始延续进来。
        if let previous = calendar.date(byAdding: .day, value: -1, to: day) { day = previous }
        while day <= lastDay {
            let segs = try segmentsForWriting(dayName(day))
            let doomed = segs.filter { $0.timeRange.start <= range.end && $0.timeRange.end >= range.start }
            let obs = observations(on: day)
            let doomedObs = Set(doomed.flatMap(\.observations))
                .union(obs.filter { range.contains($0.timeRange.start) }.map(\.id))
            if !doomed.isEmpty || !doomedObs.isEmpty {
                let dir = try dayDirectory(dayName(day))
                let keptSegs = segs.filter { s in !doomed.contains { $0.id == s.id } }
                try encoder.encode(keptSegs).write(to: dir.appendingPathComponent("segments.json"), options: .atomic)
                var data = Data()
                for item in obs where !doomedObs.contains(item.id) {
                    data.append(try encoder.encode(item))
                    data.append(0x0A)
                }
                try data.write(to: dir.appendingPathComponent("observations.jsonl"), options: .atomic)
                affected.append(day)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return affected
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

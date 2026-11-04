import AmaiCore
import Foundation

/// 记忆层读取活动片段的接口。由 App 用抽取层的存储实现，
/// 记忆层因此不依赖抽取层（docs/architecture.md §3.1）。
public protocol SegmentSource: Sendable {
    /// 最近 `days` 天内（含 `endingOn` 当天）有片段在 `after` 之后更新的日期（当天 00:00），以及其中最新的更新时间。
    func daysWithUpdates(after: Date?, endingOn: Date, days: Int) async -> [(day: Date, latestUpdate: Date)]
    func segments(on day: Date) async -> [ActivitySegment]
    /// 当天的观察。记忆层只使用 `fact` 观察的应用名与时间（作为 observed 依据），
    /// 不读取其中的屏幕文字，也不接触原始帧。
    func observations(on day: Date) async -> [Observation]
}

extension SegmentSource {
    public func observations(on day: Date) async -> [Observation] { [] }
}

/// 把活动片段同步进 daily 文件，并刷新索引。
///
/// 以片段的 `updatedAt` 作水位线：有片段新增或更新的日期，整天重渲染时间线区块
///（区块完全由系统管理，重渲染是幂等的；删除的片段自然消失）。
public actor MemorySync {
    public struct Status: Sendable, Equatable {
        public var lastSyncAt: Date?
        public var watermark: Date?
        public var daysWritten = 0
        public var filesChanged = 0
        public var lastError: String?

        public init() {}
    }

    private let source: any SegmentSource
    private let store: MemoryStore
    private let index: MemoryIndex
    private let stateURL: URL
    private let clock: any AmaiClock
    private let lookbackDays: Int
    private let log = AmaiLog.logger("memory.sync")
    private var loop: Task<Void, Never>?

    public private(set) var status = Status()

    public init(
        source: any SegmentSource,
        store: MemoryStore,
        index: MemoryIndex,
        stateURL: URL,
        clock: any AmaiClock = SystemClock(),
        lookbackDays: Int = 7
    ) {
        self.source = source
        self.store = store
        self.index = index
        self.stateURL = stateURL
        self.clock = clock
        self.lookbackDays = lookbackDays
        self.status.watermark = Self.loadWatermark(stateURL)
    }

    public func start(interval: TimeInterval = 60) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 同步一轮：写入有更新的日期，然后刷新索引（也会纳入用户在编辑器里的修改）。
    @discardableResult
    public func syncOnce() async -> Int {
        let now = clock.now()
        status.lastError = nil
        let updates = await source.daysWithUpdates(after: status.watermark, endingOn: now, days: lookbackDays)
        var written = 0
        var newWatermark = status.watermark
        for (day, latest) in updates.sorted(by: { $0.day < $1.day }) {
            do {
                try await rewrite(day: day)
                written += 1
                newWatermark = max(newWatermark ?? latest, latest)
            } catch {
                // 一天失败不影响其他天；水位线不越过失败的那天之前的更新。
                status.lastError = String(localized: "写入 \(MemoryDirectory.dayName(for: day, timeZone: .current)) 失败：\(String(describing: error))")
                log.error("daily write failed: \(String(describing: error), privacy: .public)")
                break
            }
        }
        if let newWatermark, newWatermark != status.watermark {
            status.watermark = newWatermark
            Self.saveWatermark(newWatermark, to: stateURL)
        }
        do {
            try await index.refresh()
        } catch {
            status.lastError = String(localized: "索引刷新失败：\(String(describing: error))")
        }
        status.lastSyncAt = now
        status.daysWritten += written
        return written
    }

    /// 立即按当前片段重写某一天（删除片段或时间段后调用）。
    public func rewrite(day: Date) async throws {
        let segments = await source.segments(on: day)
        if try await store.writeDailyTimeline(day: day, segments: segments) {
            status.filesChanged += 1
        }
    }

    private static func loadWatermark(_ url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["watermark"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    private static func saveWatermark(_ date: Date, to url: URL) {
        let obj: [String: Any] = ["watermark": date.timeIntervalSince1970, "version": 1]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

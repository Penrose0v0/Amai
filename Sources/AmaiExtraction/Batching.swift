import AmaiCore
import Foundation

/// 处理窗口参数（Dayflow 经验值）。窗口只是处理单位，不等于一个活动。
public struct BatchingOptions: Sendable, Equatable {
    /// 窗口目标时长。
    public var targetDuration: TimeInterval = 15 * 60
    /// 相邻截图间隔超过此值即切开（离开电脑、睡眠、暂停）。
    public var maxGap: TimeInterval = 2 * 60
    /// 一帧代表其后多长时间（等于截图间隔）。
    public var frameSpan: TimeInterval = 10

    public init() {}
}

/// 一个处理窗口：时间范围内的截图事件（含隐私跳过的占位）与焦点切换事件。
public struct ExtractionBatch: Sendable, Equatable {
    public let id: String
    public let range: TimeRange
    public let events: [PerceptionEvent]
    /// 窗口内最后一个事件的时间，处理成功后作为水位线。
    public let lastEventTime: Date

    /// 可用于理解的截图帧：正常采集且有视频引用。
    public var frames: [PerceptionEvent] {
        events.filter { $0.kind == .screenFrame && $0.sensitivity == .normal && $0.payloadRef != nil }
    }

    public var skipped: [PerceptionEvent] {
        events.filter { $0.sensitivity == .skipped }
    }

    public var focusChanges: [PerceptionEvent] {
        events.filter { $0.kind == .focusChange && $0.sensitivity == .normal }
    }
}

public enum Batcher {
    /// 只返回已经"关闭"的窗口：达到目标时长，或其后出现超过 `maxGap` 的空白，
    /// 或最后一帧距 `now` 已超过 `maxGap`。仍在增长的窗口留到下一轮。
    public static func readyBatches(events: [PerceptionEvent], now: Date, options: BatchingOptions = .init()) -> [ExtractionBatch] {
        let sorted = events.sorted { $0.wallTime < $1.wallTime }
        let points = sorted.filter { $0.kind == .screenFrame }
        guard !points.isEmpty else { return [] }

        var groups: [[PerceptionEvent]] = []
        var current: [PerceptionEvent] = []
        for point in points {
            if let last = current.last, let first = current.first,
               point.wallTime.timeIntervalSince(last.wallTime) > options.maxGap
                || point.wallTime.timeIntervalSince(first.wallTime) >= options.targetDuration {
                groups.append(current)
                current = []
            }
            current.append(point)
        }
        if let last = current.last, now.timeIntervalSince(last.wallTime) > options.maxGap {
            groups.append(current)
        }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let end = last.wallTime.addingTimeInterval(options.frameSpan)
            let inRange = sorted.filter { $0.wallTime >= first.wallTime && $0.wallTime <= last.wallTime }
            return ExtractionBatch(
                id: String(Int(first.wallTime.timeIntervalSince1970)),
                range: TimeRange(start: first.wallTime, end: end),
                events: inRange,
                lastEventTime: last.wallTime
            )
        }
    }
}

/// 空闲判定：键鼠长时间无输入**且**画面基本不变才算离开。
/// 只看键鼠会把看视频、读长文、听会误判为空闲。
public enum IdleClassifier {
    public static func isIdle(
        _ batch: ExtractionBatch,
        idleInputSeconds: Double = 60,
        idleFraction: Double = 0.9,
        staticFraction: Double = 0.8
    ) -> Bool {
        let frames = batch.frames
        guard !frames.isEmpty else { return false }
        let idle = frames.filter { ($0.metadata.idleSeconds ?? 0) >= idleInputSeconds }.count
        guard Double(idle) / Double(frames.count) >= idleFraction else { return false }
        guard frames.count > 1 else { return true }
        let still = frames.dropFirst().filter { $0.metadata.duplicateOf != nil }.count
        return Double(still) / Double(frames.count - 1) >= staticFraction
    }
}

/// 帧筛选：dHash 去重 + 应用切换优先 + 时间均匀采样。
/// 画面相似但有键鼠输入的帧不会因"重复"被丢弃。
public enum FrameSelector {
    public struct Options: Sendable, Equatable {
        public var maxFrames = 15
        /// 距上次输入小于此秒数视为"有键鼠活动"。
        public var activeInputSeconds: Double = 15

        public init() {}
    }

    public static func select(_ frames: [PerceptionEvent], options: Options = .init()) -> [PerceptionEvent] {
        guard !frames.isEmpty else { return [] }
        let sorted = frames.sorted { $0.wallTime < $1.wallTime }

        var priority = Set<Int>([0, sorted.count - 1])
        var candidates: [Int] = []
        for (i, frame) in sorted.enumerated() {
            let appChanged = i > 0 && frame.metadata.bundleId != sorted[i - 1].metadata.bundleId
            if appChanged { priority.insert(i) }
            let changed = frame.metadata.duplicateOf == nil
            let active = (frame.metadata.idleSeconds ?? .infinity) < options.activeInputSeconds
            if i == 0 || appChanged || changed || active || priority.contains(i) {
                candidates.append(i)
            }
        }
        // 末帧总在候选中。
        if !candidates.contains(sorted.count - 1) { candidates.append(sorted.count - 1) }

        guard candidates.count > options.maxFrames else {
            return candidates.sorted().map { sorted[$0] }
        }

        let prioritized = candidates.filter(priority.contains)
        var chosen: [Int]
        if prioritized.count >= options.maxFrames {
            chosen = uniform(prioritized, count: options.maxFrames)
        } else {
            let rest = candidates.filter { !priority.contains($0) }
            chosen = prioritized + uniform(rest, count: options.maxFrames - prioritized.count)
        }
        return chosen.sorted().map { sorted[$0] }
    }

    static func uniform(_ items: [Int], count: Int) -> [Int] {
        guard count > 0, !items.isEmpty else { return [] }
        guard items.count > count else { return items }
        if count == 1 { return [items[items.count / 2]] }
        let step = Double(items.count - 1) / Double(count - 1)
        var picked: [Int] = []
        for k in 0..<count {
            let idx = items[Int((Double(k) * step).rounded())]
            if picked.last != idx { picked.append(idx) }
        }
        return picked
    }
}

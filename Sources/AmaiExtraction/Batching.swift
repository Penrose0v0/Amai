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

/// 空闲判定：以键鼠输入为主。键鼠长时间无输入，并且**焦点屏**画面基本不变，才算离开。
///
/// - 焦点屏画面在变（看视频、听会）时不判为离开；
/// - 副屏画面变化（例如副屏一直在播视频）不参与判定，不能据此认为用户还在。
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

        // 每块屏幕的第一帧没有可比较的上一帧，不计入。
        let focus = frames.filter(\.metadata.isOnFocusDisplay)
        let comparable = focus.filter { $0.metadata.changeDistance != nil || $0.metadata.duplicateOf != nil }
        let pool = comparable.isEmpty ? Array(focus.sorted { $0.wallTime < $1.wallTime }.dropFirst()) : comparable
        guard !pool.isEmpty else { return true }
        let still = pool.filter { $0.metadata.duplicateOf != nil }.count
        return Double(still) / Double(pool.count) >= staticFraction
    }

    /// 窗口内非焦点屏画面变化的比例（0...1），无副屏时为 nil。
    /// 作为独立信息记录（例如"副屏仍在播放"），不影响空闲判定。
    public static func secondaryChangeFraction(_ batch: ExtractionBatch) -> Double? {
        let secondary = batch.frames.filter { !$0.metadata.isOnFocusDisplay && $0.metadata.changeDistance != nil }
        guard !secondary.isEmpty else { return nil }
        let changed = secondary.filter { $0.metadata.duplicateOf == nil }.count
        return Double(changed) / Double(secondary.count)
    }
}

/// 帧筛选：dHash 去重 + 应用切换优先 + 时间均匀采样。
/// 画面相似但有键鼠输入的帧不会因"重复"被丢弃。
///
/// 多显示器时，先在各屏之间分配帧预算（总数仍不超过 `maxFrames`），再在每块屏幕内按上述规则挑帧。
/// 分配依据焦点时长、焦点屏上的键鼠活动和画面变化，其中画面变化权重最低：
/// 副屏持续播放视频时每帧都在变，只按变化分配会让它占掉大部分预算。
public enum FrameSelector {
    public struct Options: Sendable, Equatable {
        public var maxFrames = 15
        /// 距上次输入小于此秒数视为"有键鼠活动"。
        public var activeInputSeconds: Double = 15
        /// 跨屏分配权重：焦点时长、焦点屏键鼠活动、画面变化。
        public var focusWeight = 0.5
        public var inputWeight = 0.3
        public var changeWeight = 0.2

        public init() {}
    }

    public static func select(_ frames: [PerceptionEvent], options: Options = .init()) -> [PerceptionEvent] {
        let byDisplay = Dictionary(grouping: frames) { $0.metadata.displayId ?? 0 }
        guard byDisplay.count > 1 else { return selectSingle(frames, maxFrames: options.maxFrames, options: options) }

        let displays = byDisplay.keys.sorted()
        let capacities = displays.map { selectSingle(byDisplay[$0]!, maxFrames: .max, options: options).count }
        let weights = displayWeights(displays.map { byDisplay[$0]! }, options: options)
        let quotas = allocate(options.maxFrames, weights: weights, capacities: capacities)

        var chosen: [PerceptionEvent] = []
        for (i, display) in displays.enumerated() where quotas[i] > 0 {
            chosen += selectSingle(byDisplay[display]!, maxFrames: quotas[i], options: options)
        }
        return chosen.sorted { ($0.wallTime, $0.metadata.displayId ?? 0) < ($1.wallTime, $1.metadata.displayId ?? 0) }
    }

    /// 各显示器的权重（和为 1）：焦点时长占比、焦点屏键鼠活动占比、画面变化占比的加权和。
    static func displayWeights(_ groups: [[PerceptionEvent]], options: Options) -> [Double] {
        func share(_ counts: [Int]) -> [Double]? {
            let total = counts.reduce(0, +)
            return total > 0 ? counts.map { Double($0) / Double(total) } : nil
        }
        let focus = share(groups.map { $0.filter(\.metadata.isOnFocusDisplay).count })
        let input = share(groups.map { group in
            group.filter { $0.metadata.isOnFocusDisplay && isActive($0, options: options) }.count
        })
        let change = share(groups.map { group in
            group.filter { $0.metadata.changeDistance != nil && $0.metadata.duplicateOf == nil }.count
        })
        let parts = [(focus, options.focusWeight), (input, options.inputWeight), (change, options.changeWeight)]
        let present = parts.compactMap { shares, weight in shares.map { ($0, weight) } }
        let totalWeight = present.map(\.1).reduce(0, +)
        guard totalWeight > 0 else { return groups.map { _ in 1 / Double(groups.count) } }
        return groups.indices.map { i in
            present.map { $0.0[i] * $0.1 }.reduce(0, +) / totalWeight
        }
    }

    /// 按权重分配预算：每块屏幕先保底 1 帧（让模型知道每块屏幕上有什么），
    /// 余下按最大余数法分配；某屏候选帧不够时，余额转给其他屏幕。
    static func allocate(_ budget: Int, weights: [Double], capacities: [Int]) -> [Int] {
        var quotas = capacities.map { min($0, 1) }
        if quotas.reduce(0, +) > budget {
            // 屏幕比预算还多：只给权重最高的几块。
            let ranked = weights.indices.sorted { weights[$0] > weights[$1] }
            quotas = Array(repeating: 0, count: weights.count)
            for i in ranked.prefix(budget) where capacities[i] > 0 { quotas[i] = 1 }
            return quotas
        }
        var remaining = budget - quotas.reduce(0, +)
        while remaining > 0 {
            let open = weights.indices.filter { quotas[$0] < capacities[$0] }
            guard !open.isEmpty else { break }
            let total = open.map { weights[$0] }.reduce(0, +)
            let ideal = open.map { i in total > 0 ? weights[i] / total * Double(remaining) : Double(remaining) / Double(open.count) }
            var given = 0
            var fractions: [(Int, Double)] = []
            for (k, i) in open.enumerated() {
                let add = min(Int(ideal[k]), capacities[i] - quotas[i])
                quotas[i] += add
                given += add
                fractions.append((i, ideal[k] - Double(Int(ideal[k]))))
            }
            remaining -= given
            for (i, _) in fractions.sorted(by: { $0.1 > $1.1 }) where remaining > 0 && quotas[i] < capacities[i] {
                quotas[i] += 1
                remaining -= 1
                given += 1
            }
            if given == 0 { break }
        }
        return quotas
    }

    /// 键鼠输入归属焦点屏：副屏上的帧不因为"刚有输入"而被优先保留。
    private static func isActive(_ frame: PerceptionEvent, options: Options) -> Bool {
        frame.metadata.isOnFocusDisplay && (frame.metadata.idleSeconds ?? .infinity) < options.activeInputSeconds
    }

    /// 单块屏幕内的挑帧。
    static func selectSingle(_ frames: [PerceptionEvent], maxFrames: Int, options: Options) -> [PerceptionEvent] {
        guard !frames.isEmpty, maxFrames > 0 else { return [] }
        let sorted = frames.sorted { $0.wallTime < $1.wallTime }

        var priority = Set<Int>([0, sorted.count - 1])
        var candidates: [Int] = []
        for (i, frame) in sorted.enumerated() {
            let appChanged = i > 0 && frame.metadata.bundleId != sorted[i - 1].metadata.bundleId
            if appChanged { priority.insert(i) }
            let changed = frame.metadata.duplicateOf == nil
            let active = isActive(frame, options: options)
            if i == 0 || appChanged || changed || active || priority.contains(i) {
                candidates.append(i)
            }
        }
        // 末帧总在候选中。
        if !candidates.contains(sorted.count - 1) { candidates.append(sorted.count - 1) }

        guard candidates.count > maxFrames else {
            return candidates.sorted().map { sorted[$0] }
        }

        let prioritized = candidates.filter(priority.contains)
        var chosen: [Int]
        if prioritized.count >= maxFrames {
            chosen = uniform(prioritized, count: maxFrames)
        } else {
            let rest = candidates.filter { !priority.contains($0) }
            chosen = prioritized + uniform(rest, count: maxFrames - prioritized.count)
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

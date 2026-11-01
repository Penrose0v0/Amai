import AmaiCore
import Foundation
import os

/// 一次 tick 的结果，供测试与状态显示使用。
public enum CaptureTickOutcome: Equatable, Sendable {
    /// 每块成功截到的显示器一个事件，按显示器编号排序。
    case captured([UUID])
    case skipped(SkipReason)
    case blocked(BlockReason)
    case backingOff(until: Date)
    case failed(ScreenCaptureError)
}

public enum BlockReason: String, Sendable, Equatable {
    case systemState
    case powerProfile
}

public struct ScreenCaptureStats: Sendable, Equatable {
    /// 已捕获的帧数（多显示器时每块屏幕各算一帧）。
    public var captured = 0
    /// 已捕获帧中被 dHash 判定与同一显示器上一帧相同的数量（仍编码进视频，仅作提示）。
    public var duplicates = 0
    /// 最近一次成功采集到的显示器数量。
    public var displays = 0
    public var skipped = 0
    public var failures = 0
    public var consecutiveFailures = 0
    public var lastCaptureAt: Date?
    public var lastError: ScreenCaptureError?
    public var permissionDenied = false

    public init() {}
}

/// 定时截图采集器（ADR-0002：Dayflow 风格）。
///
/// 每个 tick：系统状态 → 电源档位 → 退避 → 隐私策略 → 截取所有显示器 → 各屏 dHash → 各自追加进视频分段 → 索引。
/// 所有帧都编码（相邻相似帧由编码器压缩）；dHash 只作为元数据提示抽取层。
/// 去重按显示器独立进行：一块屏幕在播放视频不会让另一块静止屏幕的帧被当作"有变化"。
/// 省电档只拉长间隔，仍然采集所有显示器。
/// 所有系统 I/O 经协议注入，`performTick()` 可在测试中直接驱动。
public actor ScreenCapturer {
    public struct Dependencies: Sendable {
        public var source: any ScreenFrameSource
        public var idle: any IdleTimeSource
        public var secureInput: any SecureInputDetector
        public var frontmost: any FrontmostAppSource
        public var policy: any PrivacyPolicy
        public var blocker: any CaptureBlocker
        public var power: any PowerProfileSource
        public var spool: RawSpool
        public var frames: FrameStore
        public var clock: any AmaiClock

        public init(
            source: any ScreenFrameSource,
            idle: any IdleTimeSource,
            secureInput: any SecureInputDetector,
            frontmost: any FrontmostAppSource,
            policy: any PrivacyPolicy,
            blocker: any CaptureBlocker,
            power: any PowerProfileSource,
            spool: RawSpool,
            frames: FrameStore,
            clock: any AmaiClock = SystemClock()
        ) {
            self.source = source
            self.idle = idle
            self.secureInput = secureInput
            self.frontmost = frontmost
            self.policy = policy
            self.blocker = blocker
            self.power = power
            self.spool = spool
            self.frames = frames
            self.clock = clock
        }
    }

    /// 截图失败后的退避序列（秒），参考 Dayflow。
    public static let failureBackoff: [TimeInterval] = [60, 120, 300, 600]

    private var deps: Dependencies
    private var config: ScreenCaptureConfiguration
    private let log = AmaiLog.logger("perception.screen")

    private var loop: Task<Void, Never>?
    private var userPaused = false
    /// 每块显示器上一帧的哈希与事件 id，用于独立去重。
    private var lastFrames: [UInt32: (hash: UInt64, eventId: UUID)] = [:]
    private var backoffUntil: Date?

    public private(set) var stats = ScreenCaptureStats()
    public var isRunning: Bool { loop != nil }
    public var isUserPaused: Bool { userPaused }

    public init(configuration: ScreenCaptureConfiguration, dependencies: Dependencies) {
        self.config = configuration
        self.deps = dependencies
    }

    // MARK: - Control

    public func start() {
        guard loop == nil else { return }
        log.info("screen capturer starting, interval=\(self.config.interval)s height=\(self.config.targetHeight)")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.performTick()
                let interval = await self.effectiveInterval()
                guard interval.isFinite else {
                    try? await Task.sleep(for: .seconds(self.config.interval))
                    continue
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() async {
        loop?.cancel()
        loop = nil
        lastFrames.removeAll()
        await deps.frames.finishSegment()
        log.info("screen capturer stopped")
    }

    public func setUserPaused(_ paused: Bool) async {
        userPaused = paused
        if paused {
            lastFrames.removeAll()
            await deps.frames.finishSegment()
        }
    }

    /// 结束所有显示器的视频分段（删除时间段前调用，让分段可被整段删除）。
    public func closeSegment() async {
        lastFrames.removeAll()
        await deps.frames.finishSegment()
    }

    public func updateConfiguration(_ configuration: ScreenCaptureConfiguration) throws {
        try configuration.validate()
        config = configuration
    }

    public func updatePolicy(_ policy: any PrivacyPolicy) {
        deps.policy = policy
    }

    /// 当前档位下的实际间隔。`paused` 档返回无穷大。
    public func effectiveInterval() -> TimeInterval {
        config.interval * deps.power.currentProfile.intervalMultiplier
    }

    // MARK: - Tick

    @discardableResult
    public func performTick() async -> CaptureTickOutcome {
        if deps.blocker.isCaptureBlocked {
            // 睡眠 / 锁屏期间关掉分段，文件立即可读，也不让写入器跨越睡眠。
            await deps.frames.finishSegment()
            lastFrames.removeAll()
            return .blocked(.systemState)
        }
        let profile = deps.power.currentProfile
        guard profile.capturesScreen else {
            await deps.frames.finishSegment()
            return .blocked(.powerProfile)
        }
        let now = deps.clock.now()
        if let until = backoffUntil, now < until {
            return .backingOff(until: until)
        }

        let frontmost = await deps.frontmost.frontmostApp()
        let context = CaptureContext(
            frontmostBundleId: frontmost?.bundleId,
            frontmostAppName: frontmost?.name,
            secureInputActive: deps.secureInput.isSecureInputActive(),
            userPaused: userPaused
        )
        let idle = deps.idle.secondsSinceLastInput()

        if case .skip(let reason) = deps.policy.decision(for: context) {
            // 跳过时只保留占位：不含应用名与窗口信息，避免泄露被排除应用的存在时段细节。
            let event = PerceptionEvent(
                wallTime: now,
                monoTime: deps.clock.monotonicNanoseconds(),
                source: .screen,
                kind: .screenFrame,
                payloadRef: nil,
                metadata: PerceptionMetadata(idleSeconds: idle, skipReason: reason.rawValue),
                sensitivity: .skipped
            )
            try? await deps.spool.append(event, payload: nil)
            stats.skipped += 1
            lastFrames.removeAll()
            return .skipped(reason)
        }

        let capture: ScreenCapture
        do {
            capture = try await deps.source.captureAll(
                excludingBundleIds: deps.policy.excludedBundleIds,
                targetHeight: config.targetHeight,
                frontmostPid: frontmost?.pid
            )
        } catch let error as ScreenCaptureError {
            return recordFailure(error, at: now)
        } catch {
            return recordFailure(.captureFailed(String(describing: type(of: error))), at: now)
        }

        // 显示器断开（或本次没截到）：收尾它的分段，丢掉它的去重状态。重新接上时从新分段开始。
        let present = Set(capture.frames.map(\.displayId))
        for gone in await deps.frames.activeDisplayIds.subtracting(present) {
            await deps.frames.finishSegment(displayId: gone)
        }
        lastFrames = lastFrames.filter { present.contains($0.key) }

        // 只有一块屏幕时不记焦点屏，与单屏时代的数据保持一致。
        let focus = present.count > 1 ? capture.focusDisplayId : nil
        let monoTime = deps.clock.monotonicNanoseconds()
        var ids: [UUID] = []
        for frame in capture.frames {
            let hash = ImageHashing.dHash(frame.image)
            var metadata = PerceptionMetadata(
                app: frontmost?.name,
                bundleId: frontmost?.bundleId,
                displayId: frame.displayId,
                focusDisplayId: focus,
                idleSeconds: idle,
                imageHash: String(hash, radix: 16)
            )
            if let last = lastFrames[frame.displayId] {
                metadata.changeDistance = ImageHashing.distance(last.hash, hash)
                if ImageHashing.isSameScreen(last.hash, hash) {
                    metadata.duplicateOf = last.eventId
                }
            }

            let ref: FrameStore.FrameRef
            do {
                ref = try await deps.frames.append(frame.image, displayId: frame.displayId, at: now)
            } catch {
                // 一块屏幕写入失败不影响其他屏幕；全部失败时按失败退避。
                log.error("frame store append failed: \(String(describing: error), privacy: .public)")
                lastFrames[frame.displayId] = nil
                continue
            }
            metadata.frameIndex = ref.frameIndex

            let event = PerceptionEvent(
                wallTime: now,
                monoTime: monoTime,
                source: .screen,
                kind: .screenFrame,
                payloadRef: ref.segment,
                metadata: metadata
            )
            do {
                try await deps.spool.append(event, payload: nil)
            } catch {
                log.error("spool append failed: \(String(describing: error), privacy: .public)")
                return recordFailure(.captureFailed("spool"), at: now)
            }

            lastFrames[frame.displayId] = (hash, event.id)
            if metadata.duplicateOf != nil { stats.duplicates += 1 }
            stats.captured += 1
            ids.append(event.id)
        }
        guard !ids.isEmpty else {
            return recordFailure(.captureFailed("frame store"), at: now)
        }

        stats.displays = ids.count
        stats.consecutiveFailures = 0
        stats.lastCaptureAt = now
        stats.lastError = nil
        stats.permissionDenied = false
        backoffUntil = nil
        return .captured(ids)
    }

    private func recordFailure(_ error: ScreenCaptureError, at now: Date) -> CaptureTickOutcome {
        stats.failures += 1
        stats.consecutiveFailures += 1
        stats.lastError = error
        if error == .permissionDenied {
            stats.permissionDenied = true
        }
        let index = min(stats.consecutiveFailures - 1, Self.failureBackoff.count - 1)
        let delay = Self.failureBackoff[index]
        backoffUntil = now.addingTimeInterval(delay)
        lastFrames.removeAll()
        log.error("capture failed (\(self.stats.consecutiveFailures) in a row): \(String(describing: error), privacy: .public); backing off \(delay)s")
        return .failed(error)
    }
}

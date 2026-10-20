import AmaiCore
import Foundation
import os

/// 一次 tick 的结果，供测试与状态显示使用。
public enum CaptureTickOutcome: Equatable, Sendable {
    case captured(UUID)
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
    public var captured = 0
    /// 已捕获帧中被 dHash 判定与上一帧相同的数量（仍编码进视频，仅作提示）。
    public var duplicates = 0
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
/// 每个 tick：系统状态 → 电源档位 → 退避 → 隐私策略 → 截图 → dHash → 追加进视频分段 → 索引。
/// 所有帧都编码（相邻相似帧由编码器压缩）；dHash 只作为元数据提示抽取层。
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
    private var lastHash: UInt64?
    private var lastFrameEventId: UUID?
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
        lastHash = nil
        lastFrameEventId = nil
        await deps.frames.finishSegment()
        log.info("screen capturer stopped")
    }

    public func setUserPaused(_ paused: Bool) async {
        userPaused = paused
        if paused {
            lastHash = nil
            await deps.frames.finishSegment()
        }
    }

    /// 结束当前视频分段（删除时间段前调用，让分段可被整段删除）。
    public func closeSegment() async {
        lastHash = nil
        lastFrameEventId = nil
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
            lastHash = nil
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
            lastHash = nil
            return .skipped(reason)
        }

        let frame: CapturedFrame
        do {
            frame = try await deps.source.captureFrame(
                excludingBundleIds: deps.policy.excludedBundleIds,
                targetHeight: config.targetHeight
            )
        } catch let error as ScreenCaptureError {
            return recordFailure(error, at: now)
        } catch {
            return recordFailure(.captureFailed(String(describing: type(of: error))), at: now)
        }

        let hash = ImageHashing.dHash(frame.image)
        var metadata = PerceptionMetadata(
            app: frontmost?.name,
            bundleId: frontmost?.bundleId,
            displayId: frame.displayId,
            idleSeconds: idle,
            imageHash: String(hash, radix: 16)
        )
        if let lastHash, let lastId = lastFrameEventId, ImageHashing.isSameScreen(lastHash, hash) {
            metadata.duplicateOf = lastId
            stats.duplicates += 1
        }

        let ref: FrameStore.FrameRef
        do {
            ref = try await deps.frames.append(frame.image, at: now)
        } catch {
            log.error("frame store append failed: \(String(describing: error), privacy: .public)")
            return recordFailure(.captureFailed("frame store"), at: now)
        }
        metadata.frameIndex = ref.frameIndex

        let event = PerceptionEvent(
            wallTime: now,
            monoTime: deps.clock.monotonicNanoseconds(),
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

        lastHash = hash
        lastFrameEventId = event.id
        stats.captured += 1
        stats.consecutiveFailures = 0
        stats.lastCaptureAt = now
        stats.lastError = nil
        stats.permissionDenied = false
        backoffUntil = nil
        return .captured(event.id)
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
        lastHash = nil
        log.error("capture failed (\(self.stats.consecutiveFailures) in a row): \(String(describing: error), privacy: .public); backing off \(delay)s")
        return .failed(error)
    }
}

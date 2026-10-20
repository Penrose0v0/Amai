import AmaiCore
import Foundation
import os

public enum PerceptionState: String, Sendable, Equatable {
    case stopped
    case running
    case paused
    case permissionMissing
    case error
}

/// 供 App Shell 显示的快照。不含任何内容字段。
public struct PerceptionStatus: Sendable, Equatable {
    public var state: PerceptionState
    public var screenRecordingGranted: Bool
    public var powerProfile: PowerProfile
    public var systemBlocked: Bool
    public var screen: ScreenCaptureStats
    public var focusChanges: Int
    public var spoolBytes: Int64
    public var effectiveInterval: TimeInterval

    public init(
        state: PerceptionState,
        screenRecordingGranted: Bool,
        powerProfile: PowerProfile,
        systemBlocked: Bool,
        screen: ScreenCaptureStats,
        focusChanges: Int,
        spoolBytes: Int64,
        effectiveInterval: TimeInterval
    ) {
        self.state = state
        self.screenRecordingGranted = screenRecordingGranted
        self.powerProfile = powerProfile
        self.systemBlocked = systemBlocked
        self.screen = screen
        self.focusChanges = focusChanges
        self.spoolBytes = spoolBytes
        self.effectiveInterval = effectiveInterval
    }
}

/// 感知层的对外入口：装配各采集器，统一启停与状态。
/// App Shell 只与它交互，不直接触碰采集器内部。
public actor PerceptionCoordinator {
    public nonisolated let spool: RawSpool
    private let capturer: ScreenCapturer
    private let interaction: InteractionMonitor
    private let power: PowerMonitor
    private let systemState: SystemStateMonitor
    private var configuration: PerceptionConfiguration
    private let log = AmaiLog.logger("perception")

    private var started = false
    private var userPaused = false
    private var purgeTask: Task<Void, Never>?

    public init(paths: AmaiPaths, configuration: PerceptionConfiguration) throws {
        try configuration.validate()
        try paths.ensureDirectories()
        self.configuration = configuration

        let spool = try RawSpool(root: paths.raw, limits: configuration.spool)
        self.spool = spool
        var frameConfig = FrameStore.Configuration.default
        frameConfig.quality = configuration.screen.encodeQuality
        let frames = FrameStore(root: paths.raw, configuration: frameConfig) { bytes in
            try? await spool.noteExternalBytes(bytes)
        }
        self.power = PowerMonitor()
        self.systemState = SystemStateMonitor()
        self.interaction = InteractionMonitor(
            spool: spool,
            excludedBundleIds: configuration.exclusions.policy.excludedBundleIds
        )
        self.capturer = ScreenCapturer(
            configuration: configuration.screen,
            dependencies: ScreenCapturer.Dependencies(
                source: ScreenCaptureKitSource(),
                idle: SystemIdleTimeSource(),
                secureInput: SystemSecureInputDetector(),
                frontmost: SystemFrontmostAppSource(),
                policy: configuration.exclusions.policy,
                blocker: systemState,
                power: power,
                spool: spool,
                frames: frames
            )
        )
    }

    /// 抽取层据此决定是否推迟重计算（电池 / 过热时）。
    public nonisolated var currentPowerProfile: PowerProfile { power.currentProfile }

    // MARK: - Control

    public func start() async {
        guard !started else { return }
        started = true
        userPaused = false
        power.start()
        await systemState.start()
        await interaction.start()
        await capturer.start()
        purgeTask = Task { [spool] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                try? await spool.purge()
            }
        }
        log.info("perception started")
    }

    public func stop() async {
        guard started else { return }
        started = false
        purgeTask?.cancel()
        purgeTask = nil
        await capturer.stop()
        await interaction.stop()
        await systemState.stop()
        power.stop()
        log.info("perception stopped")
    }

    public func pause() async {
        userPaused = true
        await capturer.setUserPaused(true)
        log.info("perception paused by user")
    }

    public func resume() async {
        userPaused = false
        await capturer.setUserPaused(false)
        log.info("perception resumed by user")
    }

    public func apply(_ configuration: PerceptionConfiguration) async throws {
        try configuration.validate()
        self.configuration = configuration
        try await capturer.updateConfiguration(configuration.screen)
        await capturer.updatePolicy(configuration.exclusions.policy)
        interaction.updateExcludedBundleIds(configuration.exclusions.policy.excludedBundleIds)
        try await spool.updateLimits(configuration.spool)
    }

    // MARK: - Status

    public func status() async -> PerceptionStatus {
        let screen = await capturer.stats
        let granted = ScreenRecordingPermission.isGranted()
        let state: PerceptionState
        if !started {
            state = .stopped
        } else if screen.permissionDenied || !granted {
            state = .permissionMissing
        } else if userPaused {
            state = .paused
        } else if screen.consecutiveFailures >= 3 {
            state = .error
        } else {
            state = .running
        }
        return PerceptionStatus(
            state: state,
            screenRecordingGranted: granted,
            powerProfile: power.currentProfile,
            systemBlocked: systemState.isCaptureBlocked,
            screen: screen,
            focusChanges: interaction.focusChangeCount,
            spoolBytes: await spool.totalBytes,
            effectiveInterval: await capturer.effectiveInterval()
        )
    }
}

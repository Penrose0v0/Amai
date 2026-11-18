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
    /// 交互式屏幕读取（Agent、快速操作）。与后台采集共用截图源、OCR、辅助功能读取与隐私策略。
    public nonisolated let live: LiveContextReader
    private let targetApp: TargetAppTracker
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
        // Amai 自己的窗口不进入任何截图：聊天面板浮在别的应用上面，录进去既是噪声也会把对话内容写进记忆。
        let ownBundleIds: Set<String> = Bundle.main.bundleIdentifier.map { [$0] } ?? []
        let targetApp = TargetAppTracker()
        self.targetApp = targetApp
        let live = LiveContextReader(
            dependencies: LiveContextReader.Dependencies(
                screens: ScreenCaptureKitSource(),
                windows: ScreenCaptureKitSource(),
                target: targetApp,
                secureInput: SystemSecureInputDetector(),
                policy: configuration.exclusions.policy,
                ocr: VisionTextRecognizer(),
                focus: AccessibilityReader(),
                copier: SystemSelectionCopier(),
                alwaysExcludedBundleIds: ownBundleIds
            ),
            targetHeight: configuration.screen.targetHeight
        )
        self.live = live
        var dependencies = ScreenCapturer.Dependencies(
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
        dependencies.observer = live
        dependencies.alwaysExcludedBundleIds = ownBundleIds
        self.capturer = ScreenCapturer(configuration: configuration.screen, dependencies: dependencies)
    }

    /// 抽取层据此决定是否推迟重计算（电池 / 过热时）。
    public nonisolated var currentPowerProfile: PowerProfile { power.currentProfile }

    // MARK: - Control

    /// 开始跟踪"用户正在用的应用"。与采集是否开启无关：交互式读取在采集暂停时也可用。App 启动时调用一次。
    public func startInteractiveTracking() async {
        let live = self.live
        await targetApp.start { app in
            Task { await live.appDidActivate(app) }
        }
    }

    /// 恢复上次异常退出留下的视频分段。App 启动时、开始采集之前调用。
    @discardableResult
    public func recoverInterruptedSegments() async -> FrameStore.RecoveryReport {
        guard !started else { return .init() }
        return await FrameStore.recoverInterruptedSegments(in: spool.root)
    }

    public func start() async {
        guard !started else { return }
        started = true
        userPaused = false
        power.start()
        await systemState.start()
        await interaction.start()
        await capturer.start()
        await live.setBackgroundActive(true)
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
        await live.setBackgroundActive(false)
        await interaction.stop()
        await systemState.stop()
        power.stop()
        log.info("perception stopped")
    }

    public func pause() async {
        userPaused = true
        await capturer.setUserPaused(true)
        await live.setBackgroundActive(false)
        log.info("perception paused by user")
    }

    public func resume() async {
        userPaused = false
        await capturer.setUserPaused(false)
        await live.setBackgroundActive(started)
        log.info("perception resumed by user")
    }

    public func apply(_ configuration: PerceptionConfiguration) async throws {
        try configuration.validate()
        self.configuration = configuration
        try await capturer.updateConfiguration(configuration.screen)
        await capturer.updatePolicy(configuration.exclusions.policy)
        await live.updatePolicy(configuration.exclusions.policy)
        await live.updateTargetHeight(configuration.screen.targetHeight)
        interaction.updateExcludedBundleIds(configuration.exclusions.policy.excludedBundleIds)
        try await spool.updateLimits(configuration.spool)
    }

    /// 删除时间段内的原始数据。先结束写入中的视频分段，确保它也能被删除。
    @discardableResult
    public func erase(from start: Date, to end: Date) async throws -> Int {
        await capturer.closeSegment()
        // 内存里的最近画面可能属于被删除的时间段，一并丢掉。
        await live.forget()
        return try await spool.erase(from: start, to: end)
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

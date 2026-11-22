import AmaiCore
import AmaiPerception
import CoreGraphics
import Foundation

/// 按活动脚本模拟的设备：时钟、屏幕、前台应用、空闲时间、安全输入、锁屏、电源。
/// 以协议注入真实的 `ScreenCapturer`，被测的是正式采集代码（策略、去重、编码、写入原始缓冲）。
final class SimulatedDevice: AmaiClock, ScreenFrameSource, IdleTimeSource, SecureInputDetector,
    FrontmostAppSource, CaptureBlocker, PowerProfileSource, @unchecked Sendable
{
    let script: ActivityScript
    private let lock = NSLock()
    private var date: Date
    private var mono: UInt64 = 1_000
    private var tick = 0
    private let clockFormatter: DateFormatter

    init(script: ActivityScript) {
        self.script = script
        self.date = script.start
        clockFormatter = DateFormatter()
        clockFormatter.dateFormat = "HH:mm"
        clockFormatter.timeZone = script.tz
    }

    func set(_ date: Date, tick: Int) {
        lock.withLock {
            self.date = date
            self.tick = tick
        }
    }

    func now() -> Date { lock.withLock { date } }

    func monotonicNanoseconds() -> UInt64 {
        lock.withLock {
            mono += 1
            return mono
        }
    }

    private var current: ActivityScript.Activity? { script.state(at: now())?.activity }

    // ScreenFrameSource：右上角时钟每分钟变化、光标隔一帧闪烁（去重应忽略的噪声）。
    func captureAll(excludingBundleIds: Set<String>, targetHeight: Int, frontmostPid: pid_t?) async throws -> ScreenCapture {
        let (now, tick) = lock.withLock { (date, self.tick) }
        guard let state = script.state(at: now) else { throw ScreenCaptureError.noDisplay }
        let image = SyntheticScreen.render(
            state.spec, height: targetHeight, clock: clockFormatter.string(from: now), cursor: tick % 2 == 1
        )
        return ScreenCapture(frames: [CapturedFrame(image: image, displayId: 1)], focusDisplayId: 1)
    }

    func secondsSinceLastInput() -> TimeInterval { current?.idle == true ? 600 : 3 }
    func isSecureInputActive() -> Bool { current?.secureInput == true }
    func frontmostApp() async -> FrontmostApp? {
        current.map { FrontmostApp(name: $0.app, bundleId: $0.bundleId, pid: 100) }
    }
    var isCaptureBlocked: Bool { current?.locked == true }
    var currentProfile: PowerProfile { .performance }
}

/// 一次模拟采集的逐 tick 记录。
public struct CaptureTrace: Sendable {
    public struct Tick: Sendable {
        public var time: Date
        public var activity: String
        public var version: Int
        public var expected: ActivityScript.Expected
        /// "captured" / "skipped:<原因>" / "blocked" / "failed" / "backingOff"
        public var outcome: String
        public var eventId: UUID?
        public var markedDuplicate: Bool
    }

    public var ticks: [Tick]
    public var spoolRoot: URL
    public var capturedFrames: Int
    public var duplicatesFlagged: Int
    public var tickMs: [Double]
}

public enum SimulatedCapture {
    /// 按脚本逐 tick 驱动正式的 `ScreenCapturer`，原始缓冲写到 `root`（供端到端评测继续使用）。
    public static func run(_ script: ActivityScript, root: URL, policy: ExclusionListPolicy = ExclusionListPolicy()) async throws -> CaptureTrace {
        let device = SimulatedDevice(script: script)
        let spool = try RawSpool(root: root, limits: .default, clock: device, timeZone: script.tz)
        let frames = FrameStore(root: root, clock: device, timeZone: script.tz) { bytes in
            try? await spool.noteExternalBytes(bytes)
        }
        var configuration = ScreenCaptureConfiguration.default
        configuration.interval = script.captureInterval
        configuration.targetHeight = SyntheticScreen.defaultHeight
        let capturer = ScreenCapturer(
            configuration: configuration,
            dependencies: ScreenCapturer.Dependencies(
                source: device, idle: device, secureInput: device, frontmost: device, policy: policy,
                blocker: device, power: device, spool: spool, frames: frames, clock: device
            )
        )

        var ticks: [CaptureTrace.Tick] = []
        var tickMs: [Double] = []
        var t = script.start
        var index = 0
        var paused = false
        while t < script.end {
            device.set(t, tick: index)
            let state = script.state(at: t)!
            // 暂停由用户在界面上操作（setUserPaused），不是从系统读取的状态。
            if (state.activity.paused == true) != paused {
                paused.toggle()
                await capturer.setUserPaused(paused)
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let outcome = await capturer.performTick()
            tickMs.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            var tick = CaptureTrace.Tick(
                time: t, activity: state.activity.id, version: state.version,
                expected: script.expected(state.activity, excludedBundleIds: policy.excludedBundleIds),
                outcome: "", eventId: nil, markedDuplicate: false
            )
            switch outcome {
            case .captured(let ids):
                tick.outcome = "captured"
                tick.eventId = ids.first
            case .skipped(let reason): tick.outcome = "skipped:\(reason.rawValue)"
            case .blocked: tick.outcome = "blocked"
            case .backingOff: tick.outcome = "backingOff"
            case .failed: tick.outcome = "failed"
            }
            ticks.append(tick)
            index += 1
            t = script.start.addingTimeInterval(Double(index) * script.captureInterval)
        }
        await capturer.stop()
        await frames.finishSegment()

        // 采集器写进原始缓冲的去重标记。
        // 脚本只覆盖一天（脚本时区）。
        var duplicates: Set<UUID> = []
        for e in try await spool.events(on: script.start) where e.metadata.duplicateOf != nil { duplicates.insert(e.id) }
        for i in ticks.indices { ticks[i].markedDuplicate = ticks[i].eventId.map(duplicates.contains) ?? false }
        let stats = await capturer.stats
        return CaptureTrace(ticks: ticks, spoolRoot: root, capturedFrames: stats.captured, duplicatesFlagged: stats.duplicates, tickMs: tickMs)
    }
}

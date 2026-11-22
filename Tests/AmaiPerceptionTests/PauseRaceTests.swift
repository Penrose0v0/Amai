import AmaiCore
import AppKit
import Foundation
import Testing
@testable import AmaiPerception

/// 截图调用在进入后挂起，直到测试放行。ScreenCaptureKit 的一次截图在真机上约几十到几百毫秒。
final class GatedScreenSource: ScreenFrameSource, @unchecked Sendable {
    let inner: FakeScreenSource
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var open = false
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation

    init(inner: FakeScreenSource) {
        self.inner = inner
        (entered, enteredContinuation) = AsyncStream.makeStream()
    }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            open = true
            defer { waiting = nil }
            return waiting
        }
        c?.resume()
    }

    func captureAll(excludingBundleIds: Set<String>, targetHeight: Int, frontmostPid: pid_t?) async throws -> ScreenCapture {
        enteredContinuation.yield()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if open { return true }
                waiting = c
                return false
            }
            if now { c.resume() }
        }
        return try await inner.captureAll(excludingBundleIds: excludingBundleIds, targetHeight: targetHeight, frontmostPid: frontmostPid)
    }
}

/// 回归：控制操作与正在进行的截图并发。`ScreenCapturer` 是 actor：一次 tick 在 `await captureAll` 期间挂起时，
/// 暂停、停止、收尾分段（删除数据前）、更换隐私规则都可以插进来执行；tick 恢复后曾不再检查，
/// 照常写下这一帧并打开新分段（暂停期间一直开着）。
@Suite("Control operations during an in-flight capture")
struct PauseRaceTests {
    enum Control: String, CaseIterable, Sendable { case pause, stop, closeSegment, updatePolicy }

    @Test("a control operation during an in-flight capture discards it and leaves no open segment", arguments: Control.allCases)
    func controlDuringCapture(_ control: Control) async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let utc = TimeZone(identifier: "UTC")!
        let clock = FakeClock()
        let spool = try RawSpool(root: root, limits: .default, clock: clock, timeZone: utc)
        let frames = FrameStore(root: root, clock: clock, timeZone: utc) { bytes in try? await spool.noteExternalBytes(bytes) }
        let source = GatedScreenSource(inner: FakeScreenSource(image: SyntheticImage.make(seed: 0)))
        let capturer = ScreenCapturer(
            configuration: .default,
            dependencies: ScreenCapturer.Dependencies(
                source: source, idle: FakeIdle(), secureInput: FakeSecureInput(), frontmost: FakeFrontmost(),
                policy: ExclusionListPolicy(), blocker: FakeBlocker(), power: FakePower(), spool: spool, frames: frames, clock: clock
            )
        )

        let tick = Task { await capturer.performTick() }
        var entered = source.entered.makeAsyncIterator()
        _ = await entered.next()
        switch control {
        case .pause: await capturer.setUserPaused(true) // 用户在截图进行中点了"暂停记录"
        case .stop: await capturer.stop()
        case .closeSegment: await capturer.closeSegment() // 删除时间段之前
        case .updatePolicy: await capturer.updatePolicy(ExclusionListPolicy(excludedBundleIds: ["com.apple.dt.Xcode"]))
        }
        source.release()
        let result = await tick.value
        #expect(result == (control == .pause ? .skipped(.userPaused) : .blocked(.interrupted)))

        let stored = try await spool.events(on: clock.now()).filter { $0.kind == .screenFrame && $0.sensitivity == .normal }
        let open = await frames.activeSegmentPaths
        #expect(stored.isEmpty, "\(stored.count) frame(s) written after \(control); tick result \(result)")
        #expect(open.isEmpty, "a new segment was opened after \(control): \(open)")

        // 下一次 tick 照常工作（暂停时照常跳过）。
        if control == .pause { await capturer.setUserPaused(false) }
        if control != .updatePolicy {
            guard case .captured = await capturer.performTick() else { Issue.record("next tick should capture"); return }
        }

        await capturer.stop()
    }
}

/// 回归：`PerceptionCoordinator.pause()` 曾只停截图，焦点切换（应用名、bundle id、时间）仍持续写入 raw。
/// 这里经真实的 NSWorkspace 激活通知驱动 InteractionMonitor（与 App 中的路径相同），不依赖屏幕录制权限。
@Suite("Interaction monitor pause", .serialized)
struct InteractionPauseTests {
    @MainActor
    @Test("no focus change is recorded while paused; recording resumes afterwards")
    func pausedMonitorRecordsNothing() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock()
        let spool = try RawSpool(root: root, limits: .default, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
        let monitor = InteractionMonitor(spool: spool, excludedBundleIds: [], clock: clock)
        monitor.start()
        defer { monitor.stop() }

        func activate() {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
            )
        }
        func focusEvents() async throws -> [PerceptionEvent] {
            try await spool.events(on: clock.now()).filter { $0.kind == .focusChange }
        }

        monitor.setPaused(true)
        activate()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await focusEvents().isEmpty)
        #expect(monitor.focusChangeCount == 0)

        monitor.setPaused(false)
        activate()
        let deadline = Date().addingTimeInterval(3)
        while try await focusEvents().isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await focusEvents().count == 1)
    }
}

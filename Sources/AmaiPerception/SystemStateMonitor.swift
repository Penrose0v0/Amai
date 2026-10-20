import AmaiCore
import AppKit
import Foundation
import os

/// 采集器在每个 tick 前询问"系统此刻是否允许截图"。
public protocol CaptureBlocker: Sendable {
    var isCaptureBlocked: Bool { get }
}

/// 睡眠、锁屏、屏保期间不截图（参考 Dayflow）。恢复时延迟几秒，
/// 避免截到解锁动画或空桌面。
///
/// 通知观察者属于主线程对象，因此类本身是 `@MainActor`；
/// 状态标志放在锁里，`isCaptureBlocked` 可从任意 actor 同步读取。
@MainActor
public final class SystemStateMonitor: CaptureBlocker {
    private struct Flags: Sendable {
        var asleep = false
        var locked = false
        var screensaver = false
        var resumeDeadline: Date?

        var blocked: Bool { asleep || locked || screensaver }
    }

    private nonisolated let flags = OSAllocatedUnfairLock(initialState: Flags())
    private nonisolated let resumeDelay: TimeInterval
    private nonisolated let log = AmaiLog.logger("perception.system")
    private var observers: [NSObjectProtocol] = []

    public nonisolated init(resumeDelay: TimeInterval = 5) {
        self.resumeDelay = resumeDelay
    }

    public nonisolated var isCaptureBlocked: Bool {
        flags.withLock { f in
            if f.blocked { return true }
            if let deadline = f.resumeDeadline, Date() < deadline { return true }
            return false
        }
    }

    public func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update { $0.asleep = true } })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update { $0.asleep = false } })

        let pairs: [(String, @Sendable (inout Flags) -> Void)] = [
            ("com.apple.screenIsLocked", { $0.locked = true }),
            ("com.apple.screenIsUnlocked", { $0.locked = false }),
            ("com.apple.screensaver.didstart", { $0.screensaver = true }),
            ("com.apple.screensaver.didstop", { $0.screensaver = false }),
        ]
        for (name, mutate) in pairs {
            observers.append(distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in self?.update(mutate) })
        }
        log.info("system state monitor started")
    }

    public func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers = []
    }

    private nonisolated func update(_ mutate: @Sendable (inout Flags) -> Void) {
        let delay = resumeDelay
        let (wasBlocked, nowBlocked) = flags.withLock { f -> (Bool, Bool) in
            let before = f.blocked
            mutate(&f)
            let after = f.blocked
            if before && !after {
                f.resumeDeadline = Date().addingTimeInterval(delay)
            }
            return (before, after)
        }
        if wasBlocked != nowBlocked {
            log.info("capture \(nowBlocked ? "blocked" : "resuming", privacy: .public) by system state")
        }
    }
}

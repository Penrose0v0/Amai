import AmaiCore
import AppKit
import Foundation
import os

/// 键鼠交互的最小实现：只记录应用焦点切换。
/// 不记录按键内容；活动强度统计（需输入监控权限）留待后续。
/// 切换到被排除应用时只写占位，与截图路径的处理保持一致。
@MainActor
public final class InteractionMonitor {
    private nonisolated let counter = OSAllocatedUnfairLock(initialState: 0)
    private nonisolated let excluded: OSAllocatedUnfairLock<Set<String>>
    private nonisolated let spool: RawSpool
    private nonisolated let clock: any AmaiClock
    private nonisolated let log = AmaiLog.logger("perception.interaction")
    private var observer: NSObjectProtocol?

    public nonisolated init(spool: RawSpool, excludedBundleIds: Set<String>, clock: any AmaiClock = SystemClock()) {
        self.spool = spool
        self.excluded = OSAllocatedUnfairLock(initialState: excludedBundleIds)
        self.clock = clock
    }

    public nonisolated var focusChangeCount: Int { counter.withLock { $0 } }

    public nonisolated func updateExcludedBundleIds(_ ids: Set<String>) {
        excluded.withLock { $0 = ids }
    }

    public func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // 观察者在主队列上回调；只取出两个字符串，不让 NSRunningApplication 跨线程。
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.record(name: app?.localizedName, bundleId: app?.bundleIdentifier)
        }
        log.info("interaction monitor started")
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    /// 构造并写入一条焦点切换事件。被排除的应用只留占位。
    nonisolated func makeEvent(name: String?, bundleId: String?) -> PerceptionEvent {
        let isExcluded = bundleId.map { id in excluded.withLock { $0.contains(id) } } ?? false
        let metadata = isExcluded
            ? PerceptionMetadata(skipReason: SkipReason.excludedApp.rawValue)
            : PerceptionMetadata(app: name, bundleId: bundleId)
        return PerceptionEvent(
            wallTime: clock.now(),
            monoTime: clock.monotonicNanoseconds(),
            source: .interaction,
            kind: .focusChange,
            payloadRef: nil,
            metadata: metadata,
            sensitivity: isExcluded ? .skipped : .normal
        )
    }

    private nonisolated func record(name: String?, bundleId: String?) {
        let event = makeEvent(name: name, bundleId: bundleId)
        counter.withLock { $0 += 1 }
        let spool = self.spool
        let log = self.log
        Task {
            do {
                try await spool.append(event, payload: nil)
            } catch {
                log.error("focus event append failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

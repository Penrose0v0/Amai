import Dispatch
import os

/// 在专用串行队列上执行阻塞的辅助功能调用，超过时限就先返回 `fallback`，迟到的结果丢弃。
///
/// 每条 AX 消息已有超时，但一个回答很慢、却一直在回答的应用仍能把一次读取拖长；这是兜底的总时限。
/// 用自己的串行队列而不是 Swift 并发的协作线程：阻塞调用不占用那几个线程，多次读取也不会并发打到同一个应用。
enum BlockingCall {
    private static let queue = DispatchQueue(label: "com.amai.accessibility", qos: .userInitiated)

    static func value<T: Sendable>(
        within limit: Duration, fallback: T, _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (T) -> Void = { value in
                let first = finished.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            queue.async { finish(work()) }
            let nanoseconds = limit.components.seconds * 1_000_000_000 + limit.components.attoseconds / 1_000_000_000
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(nanoseconds))
            ) { finish(fallback) }
        }
    }
}

import Foundation
import os

/// 推理请求的优先级。交互式（用户正在等待的对话、快速文本操作）优先于后台（抽取、记忆整理）。
public enum InferencePriority: Sendable, Equatable {
    case interactive
    case background
}

/// 本机推理的串行闸门：同一时刻只让一个生成占用 GPU。
///
/// - 等待者按优先级出队：有交互式请求在等时，后台请求不会插到它前面；
/// - 不抢占正在进行的生成（后台单次调用很短，交互式请求最多等一次调用）；
/// - `interactiveRecentlyActive` 供后台任务在开始新的一批工作前检查，用户正在对话时整批推迟。
public final class InferenceGate: Sendable {
    public static let shared = InferenceGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var busy = false
        var interactive: [Waiter] = []
        var background: [Waiter] = []
        var interactiveHolders = 0
        var lastInteractive: Date?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// 等到轮到自己。等待期间被取消时抛出 `CancellationError`，不占用闸门。
    public func acquire(_ priority: InferencePriority) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let granted = state.withLock { s -> Bool in
                    if priority == .interactive { s.lastInteractive = Date() }
                    if !s.busy {
                        s.busy = true
                        if priority == .interactive { s.interactiveHolders += 1 }
                        return true
                    }
                    let waiter = Waiter(id: id, continuation: continuation)
                    if priority == .interactive { s.interactive.append(waiter) } else { s.background.append(waiter) }
                    return false
                }
                if granted { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { s -> Waiter? in
                if let i = s.interactive.firstIndex(where: { $0.id == id }) { return s.interactive.remove(at: i) }
                if let i = s.background.firstIndex(where: { $0.id == id }) { return s.background.remove(at: i) }
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    public func release(_ priority: InferencePriority) {
        let next = state.withLock { s -> Waiter? in
            if priority == .interactive {
                s.interactiveHolders = max(0, s.interactiveHolders - 1)
                s.lastInteractive = Date()
            }
            if !s.interactive.isEmpty {
                s.interactiveHolders += 1
                return s.interactive.removeFirst()
            }
            if !s.background.isEmpty { return s.background.removeFirst() }
            s.busy = false
            return nil
        }
        next?.continuation.resume()
    }

    public func run<T: Sendable>(
        _ priority: InferencePriority, _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(priority)
        defer { release(priority) }
        return try await body()
    }

    /// 是否有交互式请求正在进行、在排队，或刚在 `seconds` 秒内结束。
    public func interactiveRecentlyActive(within seconds: TimeInterval = 30) -> Bool {
        state.withLock { s in
            if s.interactiveHolders > 0 || !s.interactive.isEmpty { return true }
            guard let last = s.lastInteractive else { return false }
            return Date().timeIntervalSince(last) < seconds
        }
    }
}

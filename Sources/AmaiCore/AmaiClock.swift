import Foundation

/// 可注入的时间源，便于测试与回放。命名避开标准库的 `Clock`。
public protocol AmaiClock: Sendable {
    func now() -> Date
    /// 单调时钟，纳秒。
    func monotonicNanoseconds() -> UInt64
}

public struct SystemClock: AmaiClock {
    public init() {}

    public func now() -> Date { Date() }

    public func monotonicNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

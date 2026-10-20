import Foundation

/// 抽取层读取感知数据的接口。由感知层实现、在 App 中装配，
/// 抽取层因此不依赖感知层的内部实现（docs/architecture.md §3.1）。
public protocol PerceptionReading: Sendable {
    /// 返回 `(after, until]` 内的全部事件，按墙钟时间排序。
    func events(after: Date, until: Date) async throws -> [PerceptionEvent]

    /// 读取一帧截图，编码为 JPEG，高度不超过 `maxHeight`。
    func frame(payloadRef: String, frameIndex: Int, maxHeight: Int) async -> FrameAvailability
}

extension PerceptionReading {
    public func frame(for event: PerceptionEvent, maxHeight: Int) async -> FrameAvailability {
        guard let ref = event.payloadRef, let index = event.metadata.frameIndex else { return .expired }
        return await frame(payloadRef: ref, frameIndex: index, maxHeight: maxHeight)
    }

    public func frame(for evidence: Evidence, maxHeight: Int) async -> FrameAvailability {
        guard let ref = evidence.payloadRef, let index = evidence.frameIndex else { return .expired }
        return await frame(payloadRef: ref, frameIndex: index, maxHeight: maxHeight)
    }
}

public enum FrameAvailability: Sendable, Equatable {
    case available(Data)
    /// 所在视频分段仍在写入，稍后可读。
    case pending
    /// 已被保留策略清理，或文件损坏。
    case expired
}

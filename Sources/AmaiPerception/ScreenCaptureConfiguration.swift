import Foundation

/// 定时截图参数（ADR-0002：Dayflow 风格）。实际采集器在 M1 实现。
public struct ScreenCaptureConfiguration: Codable, Sendable, Equatable {
    /// 截图间隔（秒）。
    public var interval: TimeInterval
    /// 缩放后的目标高度（像素），按显示器宽高比等比缩放。
    public var targetHeight: Int
    /// JPEG 质量 0...1。
    public var jpegQuality: Double

    public static let allowedIntervals: [TimeInterval] = [1, 5, 10, 20, 30, 60]
    public static let allowedHeights: [Int] = [720, 1080]

    public static let `default` = ScreenCaptureConfiguration(
        interval: 10,
        targetHeight: 1080,
        jpegQuality: 0.75
    )

    public init(interval: TimeInterval, targetHeight: Int, jpegQuality: Double) {
        self.interval = interval
        self.targetHeight = targetHeight
        self.jpegQuality = jpegQuality
    }

    public enum ValidationError: Error, Equatable {
        case intervalNotAllowed(TimeInterval)
        case heightNotAllowed(Int)
        case qualityOutOfRange(Double)
    }

    /// 配置来自用户可手改的 JSON，加载后必须校验，不能静默接受非法值。
    public func validate() throws {
        guard Self.allowedIntervals.contains(interval) else {
            throw ValidationError.intervalNotAllowed(interval)
        }
        guard Self.allowedHeights.contains(targetHeight) else {
            throw ValidationError.heightNotAllowed(targetHeight)
        }
        guard (0...1).contains(jpegQuality) else {
            throw ValidationError.qualityOutOfRange(jpegQuality)
        }
    }
}

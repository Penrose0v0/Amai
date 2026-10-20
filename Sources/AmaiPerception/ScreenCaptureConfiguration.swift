import Foundation

/// 定时截图参数（ADR-0002：Dayflow 风格）。实际采集器在 M1 实现。
public struct ScreenCaptureConfiguration: Codable, Sendable, Equatable {
    /// 截图间隔（秒）。
    public var interval: TimeInterval
    /// 缩放后的目标高度（像素），按显示器宽高比等比缩放。
    public var targetHeight: Int
    /// 视频分段的编码质量 0...1（Dayflow 默认 0.55）。改动后对下一个分段生效。
    public var encodeQuality: Double

    public static let allowedIntervals: [TimeInterval] = [1, 5, 10, 20, 30, 60]
    public static let allowedHeights: [Int] = [720, 1080]

    public static let `default` = ScreenCaptureConfiguration(
        interval: 10,
        targetHeight: 1080,
        encodeQuality: 0.55
    )

    public init(interval: TimeInterval, targetHeight: Int, encodeQuality: Double) {
        self.interval = interval
        self.targetHeight = targetHeight
        self.encodeQuality = encodeQuality
    }

    private enum CodingKeys: String, CodingKey {
        case interval, targetHeight, encodeQuality
    }

    /// 缺失字段用默认值补齐、未知字段忽略，让旧版配置文件可以平滑升级；
    /// 值是否合法由 `validate()` 单独判断。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        interval = try c.decodeIfPresent(TimeInterval.self, forKey: .interval) ?? d.interval
        targetHeight = try c.decodeIfPresent(Int.self, forKey: .targetHeight) ?? d.targetHeight
        encodeQuality = try c.decodeIfPresent(Double.self, forKey: .encodeQuality) ?? d.encodeQuality
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
        guard (0...1).contains(encodeQuality) else {
            throw ValidationError.qualityOutOfRange(encodeQuality)
        }
    }
}

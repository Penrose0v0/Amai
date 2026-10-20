import AmaiCore
import AmaiPerception
import Foundation

/// `config.json` 的读写。
/// - 文件不存在：写入默认值。
/// - 缺字段 / 多字段：由各配置类型的解码器补默认值、忽略未知键，加载后按当前格式重写文件。
/// - JSON 损坏或值非法：不静默接受，回退默认值并返回简短错误供 UI 提示。
enum ConfigStore {
    struct LoadResult {
        var configuration: PerceptionConfiguration
        var error: String?
    }

    static func load(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            try? save(.default, to: url)
            return LoadResult(configuration: .default, error: nil)
        }
        let config: PerceptionConfiguration
        do {
            config = try JSONDecoder().decode(PerceptionConfiguration.self, from: data)
        } catch {
            return LoadResult(configuration: .default, error: "配置文件不是有效的 JSON，已使用默认值")
        }
        do {
            try config.validate()
        } catch {
            return LoadResult(configuration: .default, error: "配置值非法（\(describe(error))），已使用默认值")
        }
        // 把补齐后的配置写回，让文件始终是当前格式。
        try? save(config, to: url)
        return LoadResult(configuration: config, error: nil)
    }

    static func save(_ configuration: PerceptionConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case ScreenCaptureConfiguration.ValidationError.intervalNotAllowed(let v):
            "截图间隔 \(Int(v)) 秒不在允许范围 \(ScreenCaptureConfiguration.allowedIntervals.map { Int($0) })"
        case ScreenCaptureConfiguration.ValidationError.heightNotAllowed(let v):
            "分辨率高度 \(v) 不在允许范围 \(ScreenCaptureConfiguration.allowedHeights)"
        case ScreenCaptureConfiguration.ValidationError.qualityOutOfRange(let v):
            "编码质量 \(v) 必须在 0 到 1 之间"
        case RawSpoolLimits.ValidationError.maxBytesTooSmall:
            "缓冲容量上限不能低于 64 MB"
        case RawSpoolLimits.ValidationError.maxAgeTooShort:
            "缓冲保留时间不能短于 10 分钟"
        default:
            String(describing: error)
        }
    }
}

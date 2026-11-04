import AmaiCore
import AmaiExtraction
import AmaiMemory
import AmaiPerception
import Foundation

/// `config.json` 的完整内容：感知层字段在顶层（兼容 M1 的文件格式），
/// 抽取层在 `extraction` 下，记忆层在 `memory` 下。
struct AppConfiguration: Codable, Equatable {
    var perception: PerceptionConfiguration
    var extraction: ExtractionConfiguration
    var memory: MemoryConfiguration
    var consolidationModel: ConsolidationModelConfiguration

    static let `default` = AppConfiguration(
        perception: .default, extraction: .default, memory: .default, consolidationModel: .default
    )

    init(
        perception: PerceptionConfiguration,
        extraction: ExtractionConfiguration,
        memory: MemoryConfiguration,
        consolidationModel: ConsolidationModelConfiguration
    ) {
        self.perception = perception
        self.extraction = extraction
        self.memory = memory
        self.consolidationModel = consolidationModel
    }

    private enum CodingKeys: String, CodingKey {
        case screen, exclusions, spool, extraction, memory, consolidationModel
    }

    init(from decoder: any Decoder) throws {
        perception = try PerceptionConfiguration(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        extraction = try c.decodeIfPresent(ExtractionConfiguration.self, forKey: .extraction) ?? .default
        memory = try c.decodeIfPresent(MemoryConfiguration.self, forKey: .memory) ?? .default
        consolidationModel = try c.decodeIfPresent(ConsolidationModelConfiguration.self, forKey: .consolidationModel) ?? .default
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(perception.screen, forKey: .screen)
        try c.encode(perception.exclusions, forKey: .exclusions)
        try c.encode(perception.spool, forKey: .spool)
        try c.encode(extraction, forKey: .extraction)
        try c.encode(memory, forKey: .memory)
        try c.encode(consolidationModel, forKey: .consolidationModel)
    }

    func validate() throws {
        try perception.validate()
        try extraction.validate()
        try memory.validate()
    }
}

/// `config.json` 的读写。
/// - 文件不存在：写入默认值。
/// - 缺字段 / 多字段：各配置类型的解码器补默认值、忽略未知键，加载后按当前格式重写文件。
/// - JSON 损坏或值非法：不静默接受，回退默认值并返回简短错误供 UI 提示。
enum ConfigStore {
    struct LoadResult {
        var configuration: AppConfiguration
        var error: String?
    }

    static func load(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            try? save(.default, to: url)
            return LoadResult(configuration: .default, error: nil)
        }
        let config: AppConfiguration
        do {
            config = try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch {
            return LoadResult(configuration: .default, error: String(localized: "配置文件不是有效的 JSON，已使用默认值"))
        }
        do {
            try config.validate()
        } catch {
            return LoadResult(configuration: .default, error: String(localized: "配置值非法（\(describe(error))），已使用默认值"))
        }
        try? save(config, to: url)
        return LoadResult(configuration: config, error: nil)
    }

    static func save(_ configuration: AppConfiguration, to url: URL) throws {
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
            String(localized: "截图间隔 \(Int(v)) 秒不在允许范围 \(ScreenCaptureConfiguration.allowedIntervals.map { Int($0) })")
        case ScreenCaptureConfiguration.ValidationError.heightNotAllowed(let v):
            String(localized: "分辨率高度 \(v) 不在允许范围 \(ScreenCaptureConfiguration.allowedHeights)")
        case ScreenCaptureConfiguration.ValidationError.qualityOutOfRange(let v):
            String(localized: "编码质量 \(v) 必须在 0 到 1 之间")
        case RawSpoolLimits.ValidationError.maxBytesTooSmall:
            String(localized: "缓冲容量上限不能低于 64 MB")
        case RawSpoolLimits.ValidationError.maxAgeTooShort:
            String(localized: "缓冲保留时间不能短于 10 分钟")
        case ExtractionConfiguration.ValidationError.maxFramesOutOfRange(let v):
            String(localized: "每个窗口的帧数 \(v) 必须在 1 到 40 之间")
        case ExtractionConfiguration.ValidationError.emptyModelTag:
            String(localized: "模型名称不能为空")
        case MemoryConfiguration.ValidationError.emptyRoot:
            String(localized: "记忆目录不能为空")
        case MemoryConfiguration.ValidationError.relativeRoot(let p):
            String(localized: "记忆目录必须是绝对路径或以 ~ 开头：\(p)")
        default:
            String(describing: error)
        }
    }
}

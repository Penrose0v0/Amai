import Foundation

/// 抽取层可配置项，保存在 `config.json` 的 `extraction` 字段。
public struct ExtractionConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var modelTag: String
    public var maxFramesPerBatch: Int

    public static let `default` = ExtractionConfiguration(
        enabled: true,
        modelTag: LocalInferenceBackend.defaultModelTag,
        maxFramesPerBatch: 15
    )

    public init(enabled: Bool, modelTag: String, maxFramesPerBatch: Int) {
        self.enabled = enabled
        self.modelTag = modelTag
        self.maxFramesPerBatch = maxFramesPerBatch
    }

    public enum ValidationError: Error, Equatable {
        case maxFramesOutOfRange(Int)
        case emptyModelTag
    }

    public func validate() throws {
        guard (1...40).contains(maxFramesPerBatch) else { throw ValidationError.maxFramesOutOfRange(maxFramesPerBatch) }
        guard !modelTag.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.emptyModelTag }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, modelTag, maxFramesPerBatch
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        modelTag = try c.decodeIfPresent(String.self, forKey: .modelTag) ?? d.modelTag
        maxFramesPerBatch = try c.decodeIfPresent(Int.self, forKey: .maxFramesPerBatch) ?? d.maxFramesPerBatch
    }
}

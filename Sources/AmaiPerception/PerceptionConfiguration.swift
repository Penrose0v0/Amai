import Foundation

/// 感知层的全部可配置项。由 App 从 `config.json` 加载；缺省值即 MVP 默认行为。
public struct PerceptionConfiguration: Codable, Sendable, Equatable {
    public var screen: ScreenCaptureConfiguration
    public var exclusions: ExclusionConfiguration
    public var spool: RawSpoolLimits

    public static let `default` = PerceptionConfiguration(
        screen: .default,
        exclusions: .default,
        spool: .default
    )

    public init(
        screen: ScreenCaptureConfiguration,
        exclusions: ExclusionConfiguration,
        spool: RawSpoolLimits
    ) {
        self.screen = screen
        self.exclusions = exclusions
        self.spool = spool
    }

    public func validate() throws {
        try screen.validate()
        try spool.validate()
    }

    private enum CodingKeys: String, CodingKey {
        case screen, exclusions, spool
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen = try c.decodeIfPresent(ScreenCaptureConfiguration.self, forKey: .screen) ?? .default
        exclusions = try c.decodeIfPresent(ExclusionConfiguration.self, forKey: .exclusions) ?? .default
        spool = try c.decodeIfPresent(RawSpoolLimits.self, forKey: .spool) ?? .default
    }
}

public struct ExclusionConfiguration: Codable, Sendable, Equatable {
    public var bundleIds: [String]
    public var appNames: [String]

    public static let `default` = ExclusionConfiguration(
        bundleIds: Array(ExclusionListPolicy.defaultExcludedBundleIds).sorted(),
        appNames: []
    )

    public init(bundleIds: [String], appNames: [String]) {
        self.bundleIds = bundleIds
        self.appNames = appNames
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIds, appNames
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleIds = try c.decodeIfPresent([String].self, forKey: .bundleIds) ?? Self.default.bundleIds
        appNames = try c.decodeIfPresent([String].self, forKey: .appNames) ?? []
    }

    public var policy: ExclusionListPolicy {
        ExclusionListPolicy(
            excludedBundleIds: Set(bundleIds),
            excludedAppNames: Set(appNames)
        )
    }
}

/// RawSpool 的容量 / 时间双上限（docs/product.md §7：原始数据默认 24–72 小时自动清理）。
public struct RawSpoolLimits: Codable, Sendable, Equatable {
    public var maxBytes: Int64
    public var maxAge: TimeInterval

    public static let `default` = RawSpoolLimits(
        maxBytes: 2 * 1024 * 1024 * 1024,
        maxAge: 72 * 3600
    )

    public init(maxBytes: Int64, maxAge: TimeInterval) {
        self.maxBytes = maxBytes
        self.maxAge = maxAge
    }

    private enum CodingKeys: String, CodingKey {
        case maxBytes, maxAge
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxBytes = try c.decodeIfPresent(Int64.self, forKey: .maxBytes) ?? Self.default.maxBytes
        maxAge = try c.decodeIfPresent(TimeInterval.self, forKey: .maxAge) ?? Self.default.maxAge
    }

    public enum ValidationError: Error, Equatable {
        case maxBytesTooSmall(Int64)
        case maxAgeTooShort(TimeInterval)
    }

    public func validate() throws {
        // 低于 64 MB 几乎立刻触发清理，视为配置错误。
        guard maxBytes >= 64 * 1024 * 1024 else { throw ValidationError.maxBytesTooSmall(maxBytes) }
        guard maxAge >= 600 else { throw ValidationError.maxAgeTooShort(maxAge) }
    }
}

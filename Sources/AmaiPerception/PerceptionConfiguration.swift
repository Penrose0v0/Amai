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
    /// 配置写下时默认排除列表的版本。默认列表后来新增的条目只补给更早版本的配置，补一次：
    /// 之后用户在设置中移除某个默认条目，不会在下次启动时又被加回来。
    public var defaultsRevision: Int

    /// 各版本新增的默认排除条目。版本 1 是最初的列表（没有 `defaultsRevision` 字段的配置都视为版本 1）。
    static let defaultsAdded: [Int: [String]] = [
        2: ["com.apple.Passwords"],
    ]
    public static let currentDefaultsRevision = 2

    public static let `default` = ExclusionConfiguration(
        bundleIds: Array(ExclusionListPolicy.defaultExcludedBundleIds).sorted(),
        appNames: []
    )

    public init(bundleIds: [String], appNames: [String], defaultsRevision: Int = ExclusionConfiguration.currentDefaultsRevision) {
        self.bundleIds = bundleIds
        self.appNames = appNames
        self.defaultsRevision = defaultsRevision
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIds, appNames, defaultsRevision
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appNames = try c.decodeIfPresent([String].self, forKey: .appNames) ?? []
        guard var ids = try c.decodeIfPresent([String].self, forKey: .bundleIds) else {
            bundleIds = Self.default.bundleIds
            defaultsRevision = Self.currentDefaultsRevision
            return
        }
        let revision = try c.decodeIfPresent(Int.self, forKey: .defaultsRevision) ?? 1
        for r in (revision + 1)...max(revision + 1, Self.currentDefaultsRevision) {
            for id in Self.defaultsAdded[r] ?? [] where !ids.contains(id) { ids.append(id) }
        }
        bundleIds = ids
        defaultsRevision = max(revision, Self.currentDefaultsRevision)
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

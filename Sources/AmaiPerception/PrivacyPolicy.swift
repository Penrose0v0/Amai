import Foundation

/// 采集器在每次采集前询问的统一判定点。实现必须 fail-closed：
/// 无法确认排除规则已生效时返回 `.skip`。
public protocol PrivacyPolicy: Sendable {
    func decision(for context: CaptureContext) -> CaptureDecision
}

public struct CaptureContext: Sendable, Equatable {
    public var frontmostBundleId: String?
    public var frontmostAppName: String?
    /// 系统安全输入模式（密码框）是否激活。
    public var secureInputActive: Bool
    public var userPaused: Bool

    public init(
        frontmostBundleId: String? = nil,
        frontmostAppName: String? = nil,
        secureInputActive: Bool = false,
        userPaused: Bool = false
    ) {
        self.frontmostBundleId = frontmostBundleId
        self.frontmostAppName = frontmostAppName
        self.secureInputActive = secureInputActive
        self.userPaused = userPaused
    }
}

public enum CaptureDecision: Sendable, Equatable {
    case capture
    case skip(SkipReason)
}

public enum SkipReason: String, Sendable, Codable {
    case userPaused
    case secureInput
    case excludedApp
    case policyUnavailable
}

/// 基于排除列表的默认实现。匹配 bundle id 或应用名（不区分大小写）。
public struct ExclusionListPolicy: PrivacyPolicy {
    public var excludedBundleIds: Set<String>
    public var excludedAppNames: Set<String>

    /// 首次运行自动加入的密码管理器（参考 Dayflow 的做法）。
    public static let defaultExcludedBundleIds: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "org.keepassxc.keepassxc",
    ]

    public init(
        excludedBundleIds: Set<String> = ExclusionListPolicy.defaultExcludedBundleIds,
        excludedAppNames: Set<String> = []
    ) {
        self.excludedBundleIds = excludedBundleIds
        self.excludedAppNames = Set(excludedAppNames.map { $0.lowercased() })
    }

    public func decision(for context: CaptureContext) -> CaptureDecision {
        if context.userPaused { return .skip(.userPaused) }
        if context.secureInputActive { return .skip(.secureInput) }
        if let bundleId = context.frontmostBundleId, excludedBundleIds.contains(bundleId) {
            return .skip(.excludedApp)
        }
        if let name = context.frontmostAppName, excludedAppNames.contains(name.lowercased()) {
            return .skip(.excludedApp)
        }
        return .capture
    }
}

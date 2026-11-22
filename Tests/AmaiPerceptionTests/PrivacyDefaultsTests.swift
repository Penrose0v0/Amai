import Foundation
import Testing
@testable import AmaiPerception

/// 默认排除列表与匹配规则。
@Suite("Privacy policy defaults")
struct PrivacyDefaultsTests {
    /// 回归：macOS 15 起系统自带"密码"App（`/System/Applications/Passwords.app`，bundle id `com.apple.Passwords`）。
    /// 默认排除列表曾没有它；密码输入框会触发安全输入而被跳过，但在"密码"App 里查看的密码是普通文字。
    @Test("the system Passwords app is excluded by default")
    func systemPasswordsApp() {
        let decision = ExclusionListPolicy().decision(for: CaptureContext(frontmostBundleId: "com.apple.Passwords", frontmostAppName: "Passwords"))
        #expect(decision == .skip(.excludedApp))
    }

    /// 未修复：`ExclusionListPolicy` 的文档写的是"匹配 bundle id 或应用名（不区分大小写）"，但只有应用名做了小写化。
    /// 用户在配置里手写的 bundle id 大小写与系统报告的不一致时，排除不生效（应用名仍可匹配时除外）。
    @Test("bundle id exclusion is case-insensitive as documented")
    func bundleIdCase() {
        let policy = ExclusionListPolicy(excludedBundleIds: ["com.Example.Vault"])
        let decision = policy.decision(for: CaptureContext(frontmostBundleId: "com.example.vault"))
        withKnownIssue("bundle ids are compared case-sensitively") {
            #expect(decision == .skip(.excludedApp))
        }
    }

    /// 已有用户的 config.json 里存着完整的 bundleIds 列表，只改默认值保护不到他们。
    @Test("existing configurations get the Passwords app once; a later removal by the user sticks")
    func migration() throws {
        let old = Data(#"{"bundleIds":["com.1password.1password","com.example.custom"],"appNames":["Vault"]}"#.utf8)
        let migrated = try JSONDecoder().decode(ExclusionConfiguration.self, from: old)
        #expect(migrated.bundleIds == ["com.1password.1password", "com.example.custom", "com.apple.Passwords"])
        #expect(migrated.appNames == ["Vault"])
        #expect(migrated.defaultsRevision == ExclusionConfiguration.currentDefaultsRevision)

        var edited = migrated
        edited.bundleIds.removeAll { $0 == "com.apple.Passwords" } // 用户在设置中移除
        let reloaded = try JSONDecoder().decode(ExclusionConfiguration.self, from: JSONEncoder().encode(edited))
        #expect(!reloaded.bundleIds.contains("com.apple.Passwords"))

        let fresh = try JSONDecoder().decode(ExclusionConfiguration.self, from: Data("{}".utf8))
        #expect(fresh.bundleIds.contains("com.apple.Passwords"))
    }
}

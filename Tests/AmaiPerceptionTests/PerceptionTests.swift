import Foundation
import Testing
@testable import AmaiPerception

@Suite("ScreenCaptureConfiguration")
struct ScreenCaptureConfigurationTests {
    @Test("default configuration is valid")
    func defaultIsValid() throws {
        try ScreenCaptureConfiguration.default.validate()
    }

    @Test("rejects intervals outside the allowed set")
    func rejectsBadInterval() {
        var config = ScreenCaptureConfiguration.default
        config.interval = 7
        #expect(throws: ScreenCaptureConfiguration.ValidationError.intervalNotAllowed(7)) {
            try config.validate()
        }
    }

    @Test("rejects quality outside 0...1")
    func rejectsBadQuality() {
        var config = ScreenCaptureConfiguration.default
        config.jpegQuality = 1.5
        #expect(throws: ScreenCaptureConfiguration.ValidationError.qualityOutOfRange(1.5)) {
            try config.validate()
        }
    }
}

@Suite("ExclusionListPolicy")
struct ExclusionListPolicyTests {
    @Test("user pause wins over everything")
    func userPause() {
        let policy = ExclusionListPolicy()
        let decision = policy.decision(for: CaptureContext(userPaused: true))
        #expect(decision == .skip(.userPaused))
    }

    @Test("secure input is skipped")
    func secureInput() {
        let policy = ExclusionListPolicy()
        let decision = policy.decision(for: CaptureContext(secureInputActive: true))
        #expect(decision == .skip(.secureInput))
    }

    @Test("password managers are excluded by default")
    func passwordManager() {
        let policy = ExclusionListPolicy()
        let decision = policy.decision(
            for: CaptureContext(frontmostBundleId: "com.1password.1password")
        )
        #expect(decision == .skip(.excludedApp))
    }

    @Test("app name match is case-insensitive")
    func appNameCaseInsensitive() {
        let policy = ExclusionListPolicy(excludedAppNames: ["Signal"])
        let decision = policy.decision(for: CaptureContext(frontmostAppName: "signal"))
        #expect(decision == .skip(.excludedApp))
    }

    @Test("ordinary app is captured")
    func ordinaryApp() {
        let policy = ExclusionListPolicy()
        let decision = policy.decision(
            for: CaptureContext(frontmostBundleId: "com.apple.dt.Xcode", frontmostAppName: "Xcode")
        )
        #expect(decision == .capture)
    }
}

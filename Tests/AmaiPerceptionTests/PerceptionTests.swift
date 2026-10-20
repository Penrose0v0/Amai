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
        config.encodeQuality = 1.5
        #expect(throws: ScreenCaptureConfiguration.ValidationError.qualityOutOfRange(1.5)) {
            try config.validate()
        }
    }
}

@Suite("PerceptionConfiguration decoding")
struct PerceptionConfigurationDecodingTests {
    @Test("missing and unknown keys fall back to defaults")
    func lenientDecoding() throws {
        let json = """
        {"screen": {"interval": 20, "jpegQuality": 0.75}, "spool": {"maxAge": 3600}}
        """
        let config = try JSONDecoder().decode(PerceptionConfiguration.self, from: Data(json.utf8))
        #expect(config.screen.interval == 20)
        #expect(config.screen.encodeQuality == ScreenCaptureConfiguration.default.encodeQuality)
        #expect(config.screen.targetHeight == 1080)
        #expect(config.spool.maxAge == 3600)
        #expect(config.spool.maxBytes == RawSpoolLimits.default.maxBytes)
        #expect(config.exclusions == .default)
        try config.validate()
    }

    @Test("empty object is the default configuration")
    func emptyObject() throws {
        let config = try JSONDecoder().decode(PerceptionConfiguration.self, from: Data("{}".utf8))
        #expect(config == .default)
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(PerceptionConfiguration.default)
        #expect(try JSONDecoder().decode(PerceptionConfiguration.self, from: data) == .default)
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

import AmaiCore
import Foundation
import Testing
@testable import AmaiPerception

@Suite("ScreenCapturer.performTick")
struct ScreenCapturerTests {
    struct Harness {
        let root: URL
        let clock = FakeClock()
        let source: FakeScreenSource
        let idle = FakeIdle()
        let secure = FakeSecureInput()
        let frontmost = FakeFrontmost()
        let blocker = FakeBlocker()
        let power = FakePower()
        let spool: RawSpool
        let frames: FrameStore
        let capturer: ScreenCapturer

        init(policy: ExclusionListPolicy = ExclusionListPolicy()) throws {
            root = try TempDir.make()
            source = FakeScreenSource(image: SyntheticImage.make(seed: 0))
            let spool = try RawSpool(
                root: root, limits: .default, clock: clock, timeZone: TimeZone(identifier: "UTC")!
            )
            self.spool = spool
            frames = FrameStore(root: root, clock: clock, timeZone: TimeZone(identifier: "UTC")!) { bytes in
                try? await spool.noteExternalBytes(bytes)
            }
            capturer = ScreenCapturer(
                configuration: .default,
                dependencies: ScreenCapturer.Dependencies(
                    source: source, idle: idle, secureInput: secure, frontmost: frontmost,
                    policy: policy, blocker: blocker, power: power, spool: spool, frames: frames, clock: clock
                )
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("first tick captures into a segment with metadata")
    func captures() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.idle.seconds = 12

        let outcome = await h.capturer.performTick()
        guard case .captured(let id) = outcome else {
            Issue.record("expected captured, got \(outcome)")
            return
        }
        let events = try await h.spool.events(on: h.clock.now())
        let event = try #require(events.first { $0.id == id })
        #expect(event.payloadRef?.hasSuffix(".mp4") == true)
        #expect(event.metadata.frameIndex == 0)
        #expect(event.metadata.imageHash != nil)
        #expect(event.metadata.bundleId == "com.apple.dt.Xcode")
        #expect(event.metadata.idleSeconds == 12)
        #expect(event.sensitivity == .normal)
        #expect(await h.capturer.stats.captured == 1)
        #expect(h.source.lastExcluded.contains("com.1password.1password"))

        // 停止后分段完成，文件可读，spool 计量更新。
        await h.capturer.stop()
        let url = h.root.appendingPathComponent(try #require(event.payloadRef))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await h.spool.totalBytes > 1000)
    }

    @Test("unchanged screen is still encoded but marked as duplicate")
    func duplicate() async throws {
        let h = try Harness()
        defer { h.cleanup() }

        guard case .captured(let first) = await h.capturer.performTick() else {
            Issue.record("first tick should capture"); return
        }
        h.clock.advance(10)
        guard case .captured(let second) = await h.capturer.performTick() else {
            Issue.record("second tick should capture"); return
        }

        let events = try await h.spool.events(on: h.clock.now())
        let dup = try #require(events.first { $0.id == second })
        #expect(dup.metadata.duplicateOf == first)
        #expect(dup.metadata.frameIndex == 1)
        #expect(dup.payloadRef == events.first { $0.id == first }?.payloadRef)
        #expect(await h.capturer.stats.duplicates == 1)

        h.source.set(image: SyntheticImage.make(seed: 1))
        h.clock.advance(10)
        guard case .captured(let third) = await h.capturer.performTick() else {
            Issue.record("changed screen should capture"); return
        }
        let changed = try #require(try await h.spool.events(on: h.clock.now()).first { $0.id == third })
        #expect(changed.metadata.duplicateOf == nil)
        #expect(await h.capturer.stats.captured == 3)
        await h.capturer.stop()
    }

    @Test("secure input → skipped placeholder with no app metadata")
    func secureInput() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.secure.active = true

        let outcome = await h.capturer.performTick()
        #expect(outcome == .skipped(.secureInput))
        #expect(h.source.calls == 0)

        let event = try #require(try await h.spool.events(on: h.clock.now()).first)
        #expect(event.sensitivity == .skipped)
        #expect(event.payloadRef == nil)
        #expect(event.metadata.skipReason == "secureInput")
        #expect(event.metadata.bundleId == nil)
    }

    @Test("excluded frontmost app → skipped, no capture call")
    func excludedApp() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.frontmost.app = FrontmostApp(name: "1Password", bundleId: "com.1password.1password", pid: 2)

        #expect(await h.capturer.performTick() == .skipped(.excludedApp))
        #expect(h.source.calls == 0)
    }

    @Test("user pause → skipped and finishes the open segment")
    func userPause() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        guard case .captured = await h.capturer.performTick() else {
            Issue.record("should capture"); return
        }
        #expect(await h.frames.activeSegmentPath != nil)
        await h.capturer.setUserPaused(true)
        #expect(await h.frames.activeSegmentPath == nil)
        #expect(await h.capturer.performTick() == .skipped(.userPaused))
        await h.capturer.setUserPaused(false)
        guard case .captured = await h.capturer.performTick() else {
            Issue.record("resume should capture"); return
        }
        await h.capturer.stop()
    }

    @Test("system state and power profile block without writing anything")
    func blocked() async throws {
        let h = try Harness()
        defer { h.cleanup() }

        h.blocker.blocked = true
        #expect(await h.capturer.performTick() == .blocked(.systemState))
        h.blocker.blocked = false

        h.power.profile = .paused
        #expect(await h.capturer.performTick() == .blocked(.powerProfile))
        #expect(await h.capturer.effectiveInterval() == .infinity)

        #expect(try await h.spool.events(on: h.clock.now()).isEmpty)
        #expect(h.source.calls == 0)
    }

    @Test("capture failure backs off, permission denial is flagged, success resets")
    func failureBackoff() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.source.set(error: .permissionDenied)

        #expect(await h.capturer.performTick() == .failed(.permissionDenied))
        let stats = await h.capturer.stats
        #expect(stats.permissionDenied)
        #expect(stats.consecutiveFailures == 1)

        h.clock.advance(10)
        guard case .backingOff = await h.capturer.performTick() else {
            Issue.record("should be backing off"); return
        }
        #expect(h.source.calls == 1)

        h.clock.advance(ScreenCapturer.failureBackoff[0])
        h.source.set(image: SyntheticImage.make(seed: 2))
        guard case .captured = await h.capturer.performTick() else {
            Issue.record("should capture after backoff"); return
        }
        let after = await h.capturer.stats
        #expect(!after.permissionDenied)
        #expect(after.consecutiveFailures == 0)
        #expect(after.failures == 1)
        await h.capturer.stop()
    }

    @Test("saver profile stretches the interval")
    func saverProfile() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.power.profile = .saver
        #expect(await h.capturer.effectiveInterval() == 30)
        guard case .captured = await h.capturer.performTick() else {
            Issue.record("saver should still capture"); return
        }
        await h.capturer.stop()
    }
}

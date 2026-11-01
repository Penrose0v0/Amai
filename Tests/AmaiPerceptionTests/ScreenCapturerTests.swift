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
        guard case .captured(let ids) = outcome, let id = ids.first else {
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

        guard case .captured(let firstIds) = await h.capturer.performTick() else {
            Issue.record("first tick should capture"); return
        }
        h.clock.advance(10)
        guard case .captured(let secondIds) = await h.capturer.performTick() else {
            Issue.record("second tick should capture"); return
        }

        let (first, second) = (firstIds[0], secondIds[0])
        let events = try await h.spool.events(on: h.clock.now())
        let dup = try #require(events.first { $0.id == second })
        #expect(dup.metadata.duplicateOf == first)
        #expect(dup.metadata.frameIndex == 1)
        #expect(dup.payloadRef == events.first { $0.id == first }?.payloadRef)
        #expect(await h.capturer.stats.duplicates == 1)

        h.source.set(image: SyntheticImage.make(seed: 1))
        h.clock.advance(10)
        guard case .captured(let thirdIds) = await h.capturer.performTick() else {
            Issue.record("changed screen should capture"); return
        }
        let changed = try #require(try await h.spool.events(on: h.clock.now()).first { $0.id == thirdIds[0] })
        #expect(changed.metadata.duplicateOf == nil)
        #expect((changed.metadata.changeDistance ?? 0) > 5)
        #expect(dup.metadata.changeDistance == 0)
        // 单屏不记焦点屏。
        #expect(changed.metadata.focusDisplayId == nil)
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
        #expect(await !h.frames.activeSegmentPaths.isEmpty)
        await h.capturer.setUserPaused(true)
        #expect(await h.frames.activeSegmentPaths.isEmpty)
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

    @Test("saver profile stretches the interval but still captures every display")
    func saverProfile() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.power.profile = .saver
        h.source.set(displays: [1: SyntheticImage.make(seed: 0), 5: SyntheticImage.make(seed: 1)], focus: 1)
        #expect(await h.capturer.effectiveInterval() == 30)
        guard case .captured(let ids) = await h.capturer.performTick() else {
            Issue.record("saver should still capture"); return
        }
        #expect(ids.count == 2)
        await h.capturer.stop()
    }

    // MARK: - Multiple displays

    @Test("every display is captured into its own segment with display and focus metadata")
    func multiDisplay() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.source.set(displays: [1: SyntheticImage.make(seed: 0), 5: SyntheticImage.make(seed: 1, size: 96)], focus: 5)

        guard case .captured(let ids) = await h.capturer.performTick() else {
            Issue.record("should capture"); return
        }
        #expect(ids.count == 2)
        #expect(h.source.lastPid == 1)
        let events = try await h.spool.events(on: h.clock.now())
        let byDisplay = Dictionary(uniqueKeysWithValues: events.map { ($0.metadata.displayId!, $0) })
        let a = try #require(byDisplay[1]), b = try #require(byDisplay[5])
        #expect(a.payloadRef != b.payloadRef)
        #expect(a.payloadRef?.hasSuffix("_d1.mp4") == true)
        #expect(b.payloadRef?.hasSuffix("_d5.mp4") == true)
        #expect(a.metadata.frameIndex == 0 && b.metadata.frameIndex == 0)
        #expect(a.metadata.focusDisplayId == 5 && b.metadata.focusDisplayId == 5)
        #expect(!a.metadata.isOnFocusDisplay && b.metadata.isOnFocusDisplay)
        #expect(a.wallTime == b.wallTime)
        #expect(await h.frames.activeSegmentPaths.count == 2)
        #expect(await h.capturer.stats.displays == 2)
        #expect(await h.capturer.stats.captured == 2)

        await h.capturer.stop()
        for event in [a, b] {
            let url = h.root.appendingPathComponent(try #require(event.payloadRef))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("dedup is independent per display: a changing screen does not mask a static one")
    func independentDedup() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let still = SyntheticImage.make(seed: 0)
        h.source.set(displays: [1: still, 5: SyntheticImage.make(seed: 1)], focus: 1)
        _ = await h.capturer.performTick()

        // 显示器 5 在"播放视频"（每帧都变），显示器 1 不动。
        for step in 2...4 {
            h.clock.advance(10)
            h.source.set(displays: [1: still, 5: SyntheticImage.make(seed: step)], focus: 1)
            _ = await h.capturer.performTick()
        }
        let events = try await h.spool.events(on: h.clock.now()).sorted { $0.wallTime < $1.wallTime }
        let one = events.filter { $0.metadata.displayId == 1 }
        let five = events.filter { $0.metadata.displayId == 5 }
        #expect(one.count == 4 && five.count == 4)
        // 显示器 1 的后 3 帧都指向它自己的上一帧。
        for i in 1..<4 {
            #expect(one[i].metadata.duplicateOf == one[i - 1].id)
        }
        #expect(five.dropFirst().allSatisfy { $0.metadata.duplicateOf == nil })
        #expect(five.dropFirst().allSatisfy { ($0.metadata.changeDistance ?? 0) > 5 })
        #expect(one.map(\.metadata.frameIndex) == [0, 1, 2, 3])
        #expect(await h.capturer.stats.duplicates == 3)
        await h.capturer.stop()
    }

    @Test("unplugging a display finishes its segment; replugging starts a fresh one without stale dedup")
    func hotPlug() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let image = SyntheticImage.make(seed: 0)
        h.source.set(displays: [1: image, 5: image], focus: 1)
        _ = await h.capturer.performTick()
        let before = await h.frames.activeSegmentPaths
        let firstSegment5 = try #require(before[5])

        // 拔掉显示器 5。
        h.clock.advance(10)
        h.source.set(displays: [1: image], focus: 1)
        guard case .captured(let ids) = await h.capturer.performTick() else {
            Issue.record("remaining display should capture"); return
        }
        #expect(ids.count == 1)
        #expect(await h.frames.activeDisplayIds == [1])
        #expect(FileManager.default.fileExists(atPath: h.root.appendingPathComponent(firstSegment5).path))
        #expect(await h.capturer.stats.displays == 1)
        // 只剩一块屏幕时不再标注焦点屏。
        let single = try #require(try await h.spool.events(on: h.clock.now()).first { $0.id == ids[0] })
        #expect(single.metadata.focusDisplayId == nil)
        #expect(single.metadata.duplicateOf != nil)

        // 重新接上：新分段，第一帧没有可比较的上一帧。
        h.clock.advance(10)
        h.source.set(displays: [1: image, 5: image], focus: 5)
        _ = await h.capturer.performTick()
        let after = await h.frames.activeSegmentPaths
        #expect(after[5] != nil && after[5] != firstSegment5)
        #expect(after[1] == before[1])
        let replugged = try #require(try await h.spool.events(on: h.clock.now())
            .last { $0.metadata.displayId == 5 })
        #expect(replugged.metadata.duplicateOf == nil)
        #expect(replugged.metadata.changeDistance == nil)
        #expect(replugged.metadata.frameIndex == 0)
        await h.capturer.stop()
    }
}

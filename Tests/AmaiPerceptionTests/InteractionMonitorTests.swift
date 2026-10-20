import AmaiCore
import Foundation
import Testing
@testable import AmaiPerception

@Suite("InteractionMonitor")
struct InteractionMonitorTests {
    @Test("focus change to an ordinary app records its identity")
    func ordinaryApp() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try RawSpool(root: root, limits: .default, clock: FakeClock())
        let monitor = InteractionMonitor(spool: spool, excludedBundleIds: ["com.1password.1password"], clock: FakeClock())

        let event = monitor.makeEvent(name: "Xcode", bundleId: "com.apple.dt.Xcode")
        #expect(event.kind == .focusChange)
        #expect(event.sensitivity == .normal)
        #expect(event.metadata.bundleId == "com.apple.dt.Xcode")
    }

    @Test("focus change to an excluded app keeps only a placeholder")
    func excludedApp() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try RawSpool(root: root, limits: .default, clock: FakeClock())
        let monitor = InteractionMonitor(spool: spool, excludedBundleIds: ["com.1password.1password"], clock: FakeClock())

        let event = monitor.makeEvent(name: "1Password", bundleId: "com.1password.1password")
        #expect(event.sensitivity == .skipped)
        #expect(event.metadata.app == nil)
        #expect(event.metadata.bundleId == nil)
        #expect(event.metadata.skipReason == "excludedApp")

        monitor.updateExcludedBundleIds([])
        #expect(monitor.makeEvent(name: "1Password", bundleId: "com.1password.1password").sensitivity == .normal)
    }
}

import Foundation
import Testing
@testable import AmaiPerception

@Suite("PowerProfile.resolve")
struct PowerProfileTests {
    private func snap(ac: Bool, battery: Int?, lowPower: Bool = false, thermal: ThermalLevel = .nominal) -> PowerSnapshot {
        PowerSnapshot(onACPower: ac, batteryPercent: battery, lowPowerMode: lowPower, thermal: thermal)
    }

    @Test("plugged in → performance")
    func ac() { #expect(PowerProfile.resolve(snap(ac: true, battery: 50)) == .performance) }

    @Test("battery above 40% → balanced")
    func balanced() { #expect(PowerProfile.resolve(snap(ac: false, battery: 80)) == .balanced) }

    @Test("battery 11–40% → saver")
    func saver() { #expect(PowerProfile.resolve(snap(ac: false, battery: 30)) == .saver) }

    @Test("battery ≤10% → paused")
    func paused() { #expect(PowerProfile.resolve(snap(ac: false, battery: 9)) == .paused) }

    @Test("low power mode forces at least saver even on AC")
    func lowPower() { #expect(PowerProfile.resolve(snap(ac: true, battery: 90, lowPower: true)) == .saver) }

    @Test("thermal critical pauses regardless of power")
    func thermalCritical() { #expect(PowerProfile.resolve(snap(ac: true, battery: nil, thermal: .critical)) == .paused) }

    @Test("desktop without battery → performance")
    func desktop() { #expect(PowerProfile.resolve(snap(ac: true, battery: nil)) == .performance) }

    @Test("paused profile has infinite interval and captures nothing")
    func pausedProfile() {
        #expect(!PowerProfile.paused.capturesScreen)
        #expect(PowerProfile.paused.intervalMultiplier == .infinity)
        #expect(PowerProfile.saver.intervalMultiplier == 3)
    }
}

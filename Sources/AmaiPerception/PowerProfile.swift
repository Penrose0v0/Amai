import AmaiCore
import Foundation
import IOKit.ps
import os

/// 采集档位。初始参数参考 Screenpipe 的三档 profile，数值待实测校准。
public enum PowerProfile: String, Codable, Sendable, CaseIterable {
    case performance
    case balanced
    case saver
    case paused

    /// 乘在用户配置的截图间隔上。
    public var intervalMultiplier: Double {
        switch self {
        case .performance: 1
        case .balanced: 1
        case .saver: 3
        case .paused: .infinity
        }
    }

    public var capturesScreen: Bool { self != .paused }
}

public enum ThermalLevel: Int, Sendable, Comparable {
    case nominal, fair, serious, critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PowerSnapshot: Sendable, Equatable {
    public var onACPower: Bool
    /// 无电池的机器为 nil。
    public var batteryPercent: Int?
    public var lowPowerMode: Bool
    public var thermal: ThermalLevel

    public init(onACPower: Bool, batteryPercent: Int?, lowPowerMode: Bool, thermal: ThermalLevel) {
        self.onACPower = onACPower
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
    }
}

extension PowerProfile {
    /// 确定性规则，便于测试与解释：
    /// 热状态 critical → paused；serious → saver；
    /// 电池 ≤10% → paused；≤40% → saver；>40% → balanced；接电 → performance；
    /// 系统低电量模式至少 saver。
    public static func resolve(_ s: PowerSnapshot) -> PowerProfile {
        if s.thermal == .critical { return .paused }
        var profile: PowerProfile
        if s.onACPower {
            profile = .performance
        } else if let percent = s.batteryPercent {
            if percent <= 10 { return .paused }
            profile = percent <= 40 ? .saver : .balanced
        } else {
            profile = .balanced
        }
        if s.thermal == .serious { profile = max(profile, .saver) }
        if s.lowPowerMode { profile = max(profile, .saver) }
        return profile
    }

    /// 档位之间"更省"的一方。
    fileprivate static func max(_ a: PowerProfile, _ b: PowerProfile) -> PowerProfile {
        a.rank >= b.rank ? a : b
    }

    private var rank: Int {
        switch self {
        case .performance: 0
        case .balanced: 1
        case .saver: 2
        case .paused: 3
        }
    }
}

/// 采集器读取当前档位的接口。
public protocol PowerProfileSource: Sendable {
    var currentProfile: PowerProfile { get }
}

/// 轮询 IOKit 与 ProcessInfo，默认每 30 秒刷新一次。
public final class PowerMonitor: PowerProfileSource, Sendable {
    private struct State {
        var snapshot: PowerSnapshot
        var profile: PowerProfile
        var task: Task<Void, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let interval: TimeInterval
    private let log = AmaiLog.logger("perception.power")

    public init(pollInterval: TimeInterval = 30) {
        self.interval = pollInterval
        let snapshot = Self.readSnapshot()
        self.state = OSAllocatedUnfairLock(initialState: State(
            snapshot: snapshot, profile: PowerProfile.resolve(snapshot), task: nil
        ))
    }

    public var currentProfile: PowerProfile { state.withLock { $0.profile } }
    public var currentSnapshot: PowerSnapshot { state.withLock { $0.snapshot } }

    public func start() {
        state.withLock { s in
            guard s.task == nil else { return }
            s.task = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .seconds(self?.interval ?? 30))
                }
            }
        }
    }

    public func stop() {
        state.withLock { s in
            s.task?.cancel()
            s.task = nil
        }
    }

    public func refresh() {
        let snapshot = Self.readSnapshot()
        let profile = PowerProfile.resolve(snapshot)
        let changed = state.withLock { s -> Bool in
            let changed = s.profile != profile
            s.snapshot = snapshot
            s.profile = profile
            return changed
        }
        if changed {
            log.info("power profile → \(profile.rawValue, privacy: .public) (ac=\(snapshot.onACPower) battery=\(snapshot.batteryPercent ?? -1) thermal=\(snapshot.thermal.rawValue))")
        }
    }

    private static func readSnapshot() -> PowerSnapshot {
        var onAC = true
        var percent: Int?

        if let infoRef = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(infoRef)?.takeRetainedValue() as? [CFTypeRef] {
            if let providing = IOPSGetProvidingPowerSourceType(infoRef)?.takeUnretainedValue() as String? {
                onAC = providing == kIOPSACPowerValue
            }
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(infoRef, source)?.takeUnretainedValue() as? [String: Any]
                else { continue }
                if let current = desc[kIOPSCurrentCapacityKey] as? Int,
                   let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = Int((Double(current) / Double(max) * 100).rounded())
                }
                if let state = desc[kIOPSPowerSourceStateKey] as? String {
                    onAC = state == kIOPSACPowerValue
                }
            }
        }

        let thermal: ThermalLevel = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .fair
        }

        return PowerSnapshot(
            onACPower: onAC,
            batteryPercent: percent,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: thermal
        )
    }
}

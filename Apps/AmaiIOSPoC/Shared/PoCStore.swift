import Foundation
import notify
import UIKit

/// PoC 的共享存储：主 App 与广播扩展通过 App Group 容器交换数据。
///
/// - `frames/`：抽样保存的截图（JPEG），有数量与时间上限，可在 App 里一键清除；
/// - `events-<进程>.jsonl`：测量日志。只含计数、耗时与状态，不含任何屏幕内容。
///   每个进程写自己的文件，避免两个进程同时追加同一个文件。
enum PoCStore {
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "AmaiAppGroup") as? String ?? ""

    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("poc", isDirectory: true)
    }

    static var framesDirectory: URL? { root?.appendingPathComponent("frames", isDirectory: true) }

    static func eventsFile(process: String) -> URL? {
        root?.appendingPathComponent("events-\(process).jsonl")
    }

    static let processes = ["broadcast", "app"]

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// 保存一帧的最小间隔（秒）。与 macOS 的截图间隔同义。
    static var captureInterval: TimeInterval {
        get {
            let v = defaults?.double(forKey: "captureInterval") ?? 0
            return v > 0 ? v : 5
        }
        set { defaults?.set(newValue, forKey: "captureInterval") }
    }

    static let allowedIntervals: [TimeInterval] = [1, 5, 10, 30]
    static let maxFrames = 300
    static let maxFrameAge: TimeInterval = 24 * 3600

    static func ensureDirectories() {
        guard let framesDirectory else { return }
        try? FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
    }

    static func eraseAll() {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
        ensureDirectories()
    }

    /// 截图文件，从旧到新（文件名以毫秒时间戳开头）。
    static func frameFiles() -> [URL] {
        guard let framesDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: framesDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// 一条测量记录。`values` 只放数字，`note` 只放状态码、错误码或应用标识，不放屏幕内容。
struct PoCEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Unix 时间（秒）。
    var t: Double
    var process: String
    var kind: String
    var values: [String: Double] = [:]
    var note: String?

    var date: Date { Date(timeIntervalSince1970: t) }
}

final class EventLog: @unchecked Sendable {
    private let process: String
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    init(process: String) {
        self.process = process
        encoder.outputFormatting = [.sortedKeys]
        PoCStore.ensureDirectories()
    }

    func write(_ kind: String, _ values: [String: Double] = [:], note: String? = nil) {
        let event = PoCEvent(t: Date().timeIntervalSince1970, process: process, kind: kind, values: values, note: note)
        guard let url = PoCStore.eventsFile(process: process), var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 所有进程的记录，按时间排序。
    static func readAll() -> [PoCEvent] {
        let decoder = JSONDecoder()
        var events: [PoCEvent] = []
        for process in PoCStore.processes {
            guard let url = PoCStore.eventsFile(process: process), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let event = try? decoder.decode(PoCEvent.self, from: Data(line.utf8)) { events.append(event) }
            }
        }
        return events.sorted { $0.t < $1.t }
    }
}

/// 进程与设备的资源读数，写进测量日志用来评估内存与功耗。
enum DeviceStats {
    /// 本进程的物理内存占用（MB）。广播扩展的上限约 50 MB，超过会被系统终止。
    static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// 距离内存上限还剩多少（MB）。
    static var availableMB: Double { Double(os_proc_available_memory()) / 1_048_576 }

    static func snapshot() -> [String: Double] {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        return [
            "footprintMB": (footprintMB * 10).rounded() / 10,
            "availableMB": (availableMB * 10).rounded() / 10,
            // 0 正常，1 较热，2 很热，3 过热。
            "thermal": Double(ProcessInfo.processInfo.thermalState.rawValue),
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0,
            // 0…1；读不到时为 -1。
            "battery": Double(device.batteryLevel),
            // 0 未知，1 用电池，2 充电中，3 已充满。
            "batteryState": Double(device.batteryState.rawValue),
        ]
    }
}

/// 记录锁屏与解锁，用来对照帧的中断。
/// 这是系统的 Darwin 通知而不是公开 API，只用于 PoC 诊断，正式实现不能依赖它。
final class LockStateObserver: @unchecked Sendable {
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    init(log: EventLog) {
        notify_register_dispatch("com.apple.springboard.lockstate", &token, .global(qos: .utility)) { token in
            var state: UInt64 = 0
            notify_get_state(token, &state)
            log.write(state == 1 ? "deviceLocked" : "deviceUnlocked")
        }
    }

    deinit {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }
}

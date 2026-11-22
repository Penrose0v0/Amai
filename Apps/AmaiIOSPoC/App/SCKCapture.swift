// iOS 27 的 ScreenCaptureKit 路径。API 已对照 iOS 27.2 SDK 的头文件核对并编译通过；
// 运行时行为（后台、锁屏、中断）是 PoC 要测的内容，见 docs/references/ios-screen-capture.md。
//
// 模拟器的 SDK 里没有 ScreenCaptureKit，所以整个文件只在真机上编译。
#if canImport(ScreenCaptureKit)
import Foundation
import ScreenCaptureKit

@available(iOS 27.0, *)
@Observable
final class SCKCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private(set) var isRunning = false
    private(set) var lastError: String?

    private let log: EventLog
    private let sink: FrameSink
    private let queue = DispatchQueue(label: "amai.poc.sck", qos: .utility)
    private let statuses = StatusCounters()
    private var stream: SCStream?
    private var ticker: StatsTicker?
    private var lockObserver: LockStateObserver?

    init(log: EventLog) {
        self.log = log
        self.sink = FrameSink(log: log)
    }

    /// 弹出系统的内容选择器。iOS 上没有 SCShareableContent，内容只能由用户在选择器里选定。
    func start() {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else {
            finish(note: "pickerUnavailable")
            return
        }
        picker.add(self)
        picker.isActive = true
        picker.present()
        log.write("sckPickerPresented")
    }

    func stop() {
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
            finish(note: "userStopped")
        }
    }

    // MARK: SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard self.stream == nil else { return }
        // iOS 上没有 minimumFrameInterval / queueDepth / pixelFormat，帧率由系统决定，抽样由 FrameSink 负责。
        // 宽高保持默认，实际尺寸会出现在读数里。
        let stream = SCStream(filter: filter, configuration: SCStreamConfiguration(), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            finish(note: "addOutput:\((error as NSError).code)")
            return
        }
        self.stream = stream
        Task {
            do {
                try await stream.startCapture()
                isRunning = true
                ticker = StatsTicker(log: log, sink: sink) { [statuses] in statuses.snapshot() }
                lockObserver = LockStateObserver(log: log)
                log.write("sckStarted", sink.statsSnapshot())
            } catch {
                finish(note: "start:\((error as NSError).code)")
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        log.write("sckPickerCancelled")
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        finish(note: "picker:\((error as NSError).code)")
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let status = (info?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        // 状态变化（画面静止、黑屏、被系统暂停）写进日志：这是锁屏与后台测试最直接的证据。
        if let changed = statuses.record(status) {
            log.write("sckFrameStatus", note: changed)
        }
        // 只有 complete / started 带有新画面。
        guard status == nil || status == .complete || status == .started,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let orientation = (info?[.videoOrientation] as? NSNumber)?.uint32Value
        sink.consume(pixelBuffer, orientation: orientation)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // 缺少后台模式（-3824）、被系统停止（-3821）、用户从系统界面停止（-3817）都会走到这里。
        let error = error as NSError
        finish(note: "\(error.domain):\(error.code)")
    }

    private func finish(note: String) {
        ticker?.stop()
        ticker = nil
        lockObserver = nil
        stream = nil
        isRunning = false
        lastError = note == "userStopped" ? nil : note
        log.write("sckStopped", sink.statsSnapshot().merging(statuses.snapshot()) { _, new in new }, note: note)
    }
}

/// 各种帧状态出现的次数。
@available(iOS 27.0, *)
private final class StatusCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var last: String?

    /// 记一次；状态与上一帧不同时返回新状态的名称。
    func record(_ status: SCFrameStatus?) -> String? {
        let name = switch status {
        case .complete: "complete"
        case .idle: "idle"
        case .blank: "blank"
        case .suspended: "suspended"
        case .started: "started"
        case .stopped: "stopped"
        case nil: "none"
        @unknown default: "unknown"
        }
        lock.lock()
        defer { lock.unlock() }
        counts[name, default: 0] += 1
        guard name != last else { return nil }
        last = name
        return name
    }

    func snapshot() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: counts.map { ("status_" + $0.key, Double($0.value)) })
    }
}
#endif

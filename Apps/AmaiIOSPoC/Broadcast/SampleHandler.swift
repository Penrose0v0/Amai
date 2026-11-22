import Foundation
import ReplayKit

/// ReplayKit 广播上传扩展：用户在系统的广播选择器里开始后，系统把整个屏幕的画面（跨 App）逐帧送到这里。
/// 这是 iOS 18–26 上唯一能在自己的 App 之外看到屏幕的公开途径。
///
/// PoC 只做测量：抽样保存截图，记录帧数、间隔、内存与电量。不上传任何数据，音频只计数、不保存。
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let log = EventLog(process: "broadcast")
    private lazy var sink = FrameSink(log: log)
    private var ticker: StatsTicker?
    private var lockObserver: LockStateObserver?
    private let counters = Counters()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        log.write("broadcastStarted", sink.statsSnapshot())
        ticker = StatsTicker(log: log, sink: sink) { [counters] in counters.snapshot() }
        lockObserver = LockStateObserver(log: log)
    }

    override func broadcastPaused() {
        log.write("broadcastPaused")
    }

    override func broadcastResumed() {
        log.write("broadcastResumed")
    }

    override func broadcastFinished() {
        // 用户从控制中心 / 状态栏停止，或被系统结束（例如来电、另一个录制开始）。
        log.write("broadcastFinished", sink.statsSnapshot().merging(counters.snapshot()) { _, new in new })
        ticker?.stop()
        lockObserver = nil
    }

    override func broadcastAnnotated(withApplicationInfo applicationInfo: [AnyHashable: Any]) {
        // 系统是否告诉扩展"现在前台是哪个 App"，决定了 iOS 上能不能拿到应用元数据、能不能按应用排除。
        let bundleId = applicationInfo[RPApplicationInfoBundleIdentifierKey] as? String
        log.write("applicationInfo", ["keys": Double(applicationInfo.count)], note: bundleId)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint32Value
            sink.consume(pixelBuffer, orientation: orientation)
        case .audioApp:
            counters.add(\.audioApp)
        case .audioMic:
            counters.add(\.audioMic)
        @unknown default:
            break
        }
    }
}

private final class Counters: @unchecked Sendable {
    struct Values {
        var audioApp = 0
        var audioMic = 0
    }

    private let lock = NSLock()
    private var values = Values()

    func add(_ key: WritableKeyPath<Values, Int>) {
        lock.lock()
        values[keyPath: key] += 1
        lock.unlock()
    }

    func snapshot() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return ["audioApp": Double(values.audioApp), "audioMic": Double(values.audioMic)]
    }
}

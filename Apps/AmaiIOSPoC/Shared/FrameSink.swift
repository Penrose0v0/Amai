import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 接收屏幕帧：计数、按间隔抽样、缩小、去重、落盘。ReplayKit 与 ScreenCaptureKit 两条路径共用，
/// 这样两者的测量结果可以直接比较。
///
/// 做法与 macOS 的 ScreenCapturer 一致（固定间隔、dHash 去重），但这里是 PoC，不依赖主工程的模块。
final class FrameSink: @unchecked Sendable {
    /// 保存的截图长边上限（像素）。
    static let maxSide: CGFloat = 1280
    static let jpegQuality = 0.6
    /// 两帧之间超过这么久没有新帧，记一条 frameGap（用来观察静止画面、锁屏、切到后台时系统是否停止送帧）。
    static let gapThreshold: TimeInterval = 3
    /// dHash 距离不超过它视为同一画面，与 macOS 的 ImageHashing.sameScreenThreshold 相同。
    static let sameScreenThreshold = 5

    private let log: EventLog
    private let lock = NSLock()
    // 广播扩展内存上限约 50 MB：不缓存中间结果，每次只处理一帧。
    private let context = CIContext(options: [.cacheIntermediates: false])

    private var interval = PoCStore.captureInterval
    private var received = 0
    private var kept = 0
    private var duplicates = 0
    private var failures = 0
    private var lastReceivedAt: Date?
    private var lastSampledAt: Date?
    private var lastHash: UInt64?
    private var lastSize = CGSize.zero
    private var lastOrientation: UInt32 = 0
    private var bytesWritten: Int64 = 0

    init(log: EventLog) {
        self.log = log
        PoCStore.ensureDirectories()
    }

    /// 由采集回调调用。`orientation` 是 CGImagePropertyOrientation 的原始值（ReplayKit 随帧给出）。
    func consume(_ pixelBuffer: CVPixelBuffer, orientation: UInt32?) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        received += 1
        if let last = lastReceivedAt, now.timeIntervalSince(last) > Self.gapThreshold {
            log.write("frameGap", ["seconds": (now.timeIntervalSince(last) * 10).rounded() / 10])
        }
        lastReceivedAt = now
        if let orientation { lastOrientation = orientation }

        if let last = lastSampledAt, now.timeIntervalSince(last) < interval { return }
        lastSampledAt = now

        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        lastSize = CGSize(width: width, height: height)
        let scale = min(1, Self.maxSide / max(width, height))
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            failures += 1
            return
        }

        let hash = Self.dHash(cgImage)
        if let lastHash, (hash ^ lastHash).nonzeroBitCount <= Self.sameScreenThreshold {
            duplicates += 1
            return
        }
        lastHash = hash

        guard let directory = PoCStore.framesDirectory, let jpeg = Self.jpeg(cgImage) else {
            failures += 1
            return
        }
        let name = String(format: "%013lld_%016llx.jpg", Int64(now.timeIntervalSince1970 * 1000), hash)
        do {
            try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
            kept += 1
            bytesWritten += Int64(jpeg.count)
            if kept % 20 == 0 { prune() }
        } catch {
            failures += 1
        }
    }

    /// 当前计数与资源读数，由调用方定时写进日志。也在这里重新读取间隔设置。
    func statsSnapshot() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        interval = PoCStore.captureInterval
        var values = DeviceStats.snapshot()
        values["received"] = Double(received)
        values["kept"] = Double(kept)
        values["duplicates"] = Double(duplicates)
        values["failures"] = Double(failures)
        values["interval"] = interval
        values["width"] = Double(lastSize.width)
        values["height"] = Double(lastSize.height)
        values["orientation"] = Double(lastOrientation)
        values["writtenKB"] = Double(bytesWritten / 1024)
        return values
    }

    /// 保持截图数量与保存时间在上限之内：原始数据不默认永久保存。
    private func prune() {
        let files = PoCStore.frameFiles()
        let cutoff = Int64((Date().timeIntervalSince1970 - PoCStore.maxFrameAge) * 1000)
        let overflow = max(0, files.count - PoCStore.maxFrames)
        for (index, file) in files.enumerated() {
            let stamp = Int64(file.lastPathComponent.prefix(13)) ?? 0
            if index < overflow || stamp < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// 9×8 灰度差分哈希。
    static func dHash(_ image: CGImage) -> UInt64 {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var hash: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                hash <<= 1
                if pixels[y * width + x] > pixels[y * width + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// 定时把计数与资源读数写进日志。即使没有新帧也会写，
/// 这样锁屏或静止画面期间"进程是否还活着"能从日志里看出来。
final class StatsTicker: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(every seconds: TimeInterval = 30, log: EventLog, sink: FrameSink, extra: @escaping @Sendable () -> [String: Double] = { [:] }) {
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .seconds(2))
        timer.setEventHandler {
            log.write("stats", sink.statsSnapshot().merging(extra()) { _, new in new })
        }
        timer.resume()
    }

    func stop() { timer.cancel() }
}

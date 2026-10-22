import AmaiCore
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import os

/// 截图帧的视频分段存储（参考 Dayflow 的 FrameStore）。
///
/// 每帧追加进一个 HEVC/MP4 分段：第 N 帧放在视频第 N 秒（1 fps 名义时基，
/// 真实时间在事件索引里）。分段在达到 `maxFrames`、`maxDuration` 或帧尺寸变化时轮换。
/// 写入中的分段以 `.part` 结尾，完成后改名为 `.mp4`，清理与读取都只看 `.mp4`。
/// 相比逐帧 JPEG，相邻相似帧由编码器压缩，磁盘增长约为 1/3。
public actor FrameStore {
    public struct Configuration: Sendable, Equatable {
        public var maxFrames: Int
        public var maxDuration: TimeInterval
        /// 0...1。Dayflow 的注释：0.55 是"小号 UI 文字仍可读"的最低值。
        public var quality: Double
        public var keyFrameInterval: Int
        /// 编码器不支持质量模式时的回退码率。
        public var fallbackBitRate: Int
        /// 分片间隔（媒体时间；第 N 帧在第 N 秒，因此单位是帧）。分片只能从关键帧开始，
        /// 所以与 `keyFrameInterval` 对齐：崩溃时最多丢失最近 30 帧（约 5 分钟）的画面。
        public var fragmentInterval: Double = 30

        public static let `default` = Configuration(
            maxFrames: 600, maxDuration: 600, quality: 0.55, keyFrameInterval: 30, fallbackBitRate: 2_000_000
        )

        public init(maxFrames: Int, maxDuration: TimeInterval, quality: Double, keyFrameInterval: Int, fallbackBitRate: Int) {
            self.maxFrames = maxFrames
            self.maxDuration = maxDuration
            self.quality = quality
            self.keyFrameInterval = keyFrameInterval
            self.fallbackBitRate = fallbackBitRate
        }
    }

    /// 一帧写入后的定位信息，写进 `PerceptionEvent.payloadRef` 与 `metadata.frameIndex`。
    public struct FrameRef: Sendable, Equatable {
        /// 相对 spool 根目录的分段路径（最终的 `.mp4` 名）。
        public let segment: String
        public let frameIndex: Int
    }

    public enum StoreError: Error, Equatable {
        case pixelBufferUnavailable
        case writerFailed(String)
        case appendFailed
    }

    private struct Segment {
        let partURL: URL
        let finalURL: URL
        let relativeFinalPath: String
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let width: Int
        let height: Int
        let startedAt: Date
        var frameCount = 0
    }

    private let root: URL
    private let config: Configuration
    private let clock: any AmaiClock
    private let timeZone: TimeZone
    private let log = AmaiLog.logger("perception.frames")
    private var segment: Segment?
    /// 分段完成后回调已写入的字节数，供 spool 计量。
    private let onSegmentFinished: @Sendable (Int64) async -> Void

    public init(
        root: URL,
        configuration: Configuration = .default,
        clock: any AmaiClock = SystemClock(),
        timeZone: TimeZone = .current,
        onSegmentFinished: @escaping @Sendable (Int64) async -> Void = { _ in }
    ) {
        self.root = root
        self.config = configuration
        self.clock = clock
        self.timeZone = timeZone
        self.onSegmentFinished = onSegmentFinished
    }

    public var activeSegmentPath: String? { segment?.relativeFinalPath }
    public var activeFrameCount: Int { segment?.frameCount ?? 0 }

    // MARK: - Append

    public func append(_ image: CGImage, at date: Date) async throws -> FrameRef {
        if let s = segment, Self.shouldRotate(s, image: image, now: date, config: config) {
            await finishSegment()
        }
        if segment == nil {
            segment = try startSegment(width: image.width, height: image.height, at: date)
        }
        guard var s = segment else { throw StoreError.writerFailed("no segment") }

        guard let pool = s.adaptor.pixelBufferPool else { throw StoreError.pixelBufferUnavailable }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixelBuffer = buffer else { throw StoreError.pixelBufferUnavailable }
        Self.draw(image, into: pixelBuffer)

        // 等待输入就绪；1 fps 的写入几乎不会阻塞。
        var waited = 0
        while !s.input.isReadyForMoreMediaData, waited < 50 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        guard s.input.isReadyForMoreMediaData else { throw StoreError.appendFailed }

        let time = CMTime(value: CMTimeValue(s.frameCount), timescale: 1)
        guard s.adaptor.append(pixelBuffer, withPresentationTime: time) else {
            let reason = s.writer.error.map { String(describing: $0) } ?? "unknown"
            log.error("frame append failed: \(reason, privacy: .public)")
            segment = nil
            s.writer.cancelWriting()
            throw StoreError.appendFailed
        }
        let index = s.frameCount
        s.frameCount += 1
        segment = s
        return FrameRef(segment: s.relativeFinalPath, frameIndex: index)
    }

    /// 结束当前分段（停止、睡眠、锁屏、退出时调用）。无分段时为空操作。
    public func finishSegment() async {
        guard let s = segment else { return }
        segment = nil
        s.input.markAsFinished()
        await withCheckedContinuation { continuation in
            s.writer.finishWriting { continuation.resume() }
        }
        if s.writer.status == .failed {
            log.error("segment finalize failed: \(String(describing: s.writer.error), privacy: .public)")
            try? FileManager.default.removeItem(at: s.partURL)
            return
        }
        do {
            try FileManager.default.moveItem(at: s.partURL, to: s.finalURL)
        } catch {
            log.error("segment rename failed: \(String(describing: error), privacy: .public)")
            return
        }
        let bytes = (try? s.finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        log.info("segment finished: \(s.frameCount) frames, \(bytes) bytes")
        await onSegmentFinished(bytes)
    }

    // MARK: - Recovery

    public struct RecoveryReport: Sendable, Equatable {
        public var recovered = 0
        public var broken = 0
    }

    /// 启动时处理上次异常退出留下的 `.part` 分段（必须在开始采集之前调用）：
    /// 能读出画面的改名为 `.mp4` 继续使用；读不出的改名为 `.mp4.broken`，交给保留策略清理。
    /// 不处理时，读取方会把这些分段永远当作"仍在写入"，抽取会因此停住。
    public static func recoverInterruptedSegments(in root: URL) async -> RecoveryReport {
        var report = RecoveryReport()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return report
        }
        let parts = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix(".mp4.part") }
        for part in parts {
            // AVFoundation 按扩展名识别格式，先改回 .mp4 再尝试读取。
            let final = part.deletingPathExtension()
            let broken = final.appendingPathExtension("broken")
            do {
                if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
                try fm.moveItem(at: part, to: final)
                if (try? await image(segmentURL: final, frameIndex: 0)) != nil {
                    report.recovered += 1
                } else {
                    if fm.fileExists(atPath: broken.path) { try fm.removeItem(at: broken) }
                    try fm.moveItem(at: final, to: broken)
                    report.broken += 1
                }
            } catch {
                continue
            }
        }
        if report.recovered + report.broken > 0 {
            AmaiLog.logger("perception.frames").info("recovered \(report.recovered) interrupted segment(s), \(report.broken) unreadable")
        }
        return report
    }

    // MARK: - Read

    /// 从已完成的分段读取一帧。供抽取层与检查器使用。
    public static func image(segmentURL: URL, frameIndex: Int) async throws -> CGImage {
        let asset = AVURLAsset(url: segmentURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(value: CMTimeValue(frameIndex), timescale: 1)
        let (image, _) = try await generator.image(at: time)
        return image
    }

    // MARK: - Segment lifecycle

    private static func shouldRotate(_ s: Segment, image: CGImage, now: Date, config: Configuration) -> Bool {
        s.frameCount >= config.maxFrames
            || now.timeIntervalSince(s.startedAt) >= config.maxDuration
            || s.width != image.width || s.height != image.height
    }

    private func startSegment(width: Int, height: Int, at date: Date) throws -> Segment {
        let dayName = Self.dayName(for: date, timeZone: timeZone)
        let dayDir = root.appendingPathComponent(dayName, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let stamp = Self.stampFormatter(timeZone).string(from: date)
        let finalName = "\(stamp).mp4"
        let finalURL = dayDir.appendingPathComponent(finalName)
        let partURL = dayDir.appendingPathComponent("\(stamp).mp4.part")
        try? FileManager.default.removeItem(at: partURL)

        let writer = try AVAssetWriter(outputURL: partURL, fileType: .mp4)
        // 分片写入：进程被强制结束或崩溃时，已写入的片段仍可读取，启动时可恢复为正式分段。
        writer.movieFragmentInterval = CMTime(seconds: config.fragmentInterval, preferredTimescale: 1)
        var settings = Self.outputSettings(width: width, height: height, config: config, useQuality: true)
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings = Self.outputSettings(width: width, height: height, config: config, useQuality: false)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw StoreError.writerFailed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw StoreError.writerFailed(writer.error.map { String(describing: $0) } ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)
        log.info("segment started \(width)x\(height)")
        return Segment(
            partURL: partURL, finalURL: finalURL, relativeFinalPath: "\(dayName)/\(finalName)",
            writer: writer, input: input, adaptor: adaptor,
            width: width, height: height, startedAt: date
        )
    }

    private static func outputSettings(width: Int, height: Int, config: Configuration, useQuality: Bool) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: config.keyFrameInterval,
            AVVideoExpectedSourceFrameRateKey: 1,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if useQuality {
            compression[AVVideoQualityKey] = config.quality
        } else {
            compression[AVVideoAverageBitRateKey] = config.fallbackBitRate
        }
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
    }

    private static func dayName(for date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func stampFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd_HHmmssSSS"
        return f
    }
}

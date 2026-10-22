import AmaiCore
import CoreGraphics
import Foundation

/// `PerceptionReading` 的实现：读 RawSpool 的事件索引，从视频分段按帧号解码截图。
public struct SpoolReader: PerceptionReading {
    private let spool: RawSpool
    private let root: URL
    private let calendar: Calendar
    private let log = AmaiLog.logger("perception.reader")

    /// 分段最长 10 分钟、每 60 秒写一个片段；超过 15 分钟未更新即视为残留。
    static let stalePartAge: TimeInterval = 15 * 60

    public init(spool: RawSpool, timeZone: TimeZone = .current) {
        self.spool = spool
        self.root = spool.root
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public func events(after: Date, until: Date) async throws -> [PerceptionEvent] {
        guard until > after else { return [] }
        var result: [PerceptionEvent] = []
        var day = calendar.startOfDay(for: after)
        let lastDay = calendar.startOfDay(for: until)
        while day <= lastDay {
            // 取当天中午，避免夏令时边界把日期算错。
            let noon = calendar.date(byAdding: .hour, value: 12, to: day) ?? day
            result += try await spool.events(on: noon)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
            .filter { $0.wallTime > after && $0.wallTime <= until }
            .sorted { $0.wallTime < $1.wallTime }
    }

    public func frame(payloadRef: String, frameIndex: Int, maxHeight: Int) async -> FrameAvailability {
        let url = root.appendingPathComponent(payloadRef)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            let part = url.path + ".part"
            guard fm.fileExists(atPath: part) else { return .expired }
            // 兜底：长时间没有更新的 .part 不是"正在写入"，而是异常退出的残留。
            let modified = (try? fm.attributesOfItem(atPath: part)[.modificationDate] as? Date) ?? .distantPast
            return Date().timeIntervalSince(modified) > Self.stalePartAge ? .expired : .pending
        }
        do {
            let image = try await FrameStore.image(segmentURL: url, frameIndex: frameIndex)
            let scaled = Self.scale(image, maxHeight: maxHeight)
            return .available(try JPEGEncoder.encode(scaled, quality: 0.85))
        } catch {
            log.error("frame decode failed: \(String(describing: error), privacy: .public)")
            return .expired
        }
    }

    private static func scale(_ image: CGImage, maxHeight: Int) -> CGImage {
        guard image.height > maxHeight, maxHeight > 0 else { return image }
        let ratio = Double(maxHeight) / Double(image.height)
        let width = max(1, Int(Double(image.width) * ratio))
        guard let ctx = CGContext(
            data: nil, width: width, height: maxHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: maxHeight))
        return ctx.makeImage() ?? image
    }
}

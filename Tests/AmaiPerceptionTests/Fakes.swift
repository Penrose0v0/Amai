import AmaiCore
import CoreGraphics
import Foundation
@testable import AmaiPerception

final class FakeClock: AmaiClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var mono: UInt64 = 1_000

    init(_ date: Date = Date(timeIntervalSince1970: 1_760_000_000)) {
        self.date = date
    }

    func now() -> Date { lock.withLock { date } }

    func monotonicNanoseconds() -> UInt64 {
        lock.withLock {
            mono += 1
            return mono
        }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

final class FakeScreenSource: ScreenFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var next: Result<CapturedFrame, ScreenCaptureError>
    private(set) var calls = 0
    private(set) var lastExcluded: Set<String> = []

    init(image: CGImage) {
        next = .success(CapturedFrame(image: image, displayId: 1))
    }

    func set(image: CGImage) {
        lock.withLock { next = .success(CapturedFrame(image: image, displayId: 1)) }
    }

    func set(error: ScreenCaptureError) {
        lock.withLock { next = .failure(error) }
    }

    func captureFrame(excludingBundleIds: Set<String>, targetHeight: Int) async throws -> CapturedFrame {
        try lock.withLock {
            calls += 1
            lastExcluded = excludingBundleIds
            return try next.get()
        }
    }
}

final class FakeIdle: IdleTimeSource, @unchecked Sendable {
    var seconds: TimeInterval = 1
    func secondsSinceLastInput() -> TimeInterval { seconds }
}

final class FakeSecureInput: SecureInputDetector, @unchecked Sendable {
    var active = false
    func isSecureInputActive() -> Bool { active }
}

final class FakeFrontmost: FrontmostAppSource, @unchecked Sendable {
    var app: FrontmostApp? = FrontmostApp(name: "Xcode", bundleId: "com.apple.dt.Xcode", pid: 1)
    func frontmostApp() async -> FrontmostApp? { app }
}

final class FakeBlocker: CaptureBlocker, @unchecked Sendable {
    var blocked = false
    var isCaptureBlocked: Bool { blocked }
}

final class FakePower: PowerProfileSource, @unchecked Sendable {
    var profile: PowerProfile = .performance
    var currentProfile: PowerProfile { profile }
}

enum SyntheticImage {
    /// 64×64 RGB 图像，`seed` 决定渐变方向与色块，用于制造"相同 / 不同"画面。
    static func make(seed: Int, size: Int = 64) -> CGImage {
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let value = seed % 2 == 0 ? x * 4 : (size - 1 - x) * 4
                let block = ((x / 8 + y / 8 + seed) % 3) * 60
                pixels[i] = UInt8(min(255, value + block))
                pixels[i + 1] = UInt8(min(255, (y * 4 + block) % 256))
                pixels[i + 2] = UInt8(min(255, (seed * 37 + block) % 256))
                pixels[i + 3] = 255
            }
        }
        let data = CFDataCreate(nil, pixels, pixels.count)!
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

enum PixelStats {
    /// 两张图各自缩到 16×16 RGBA 后的逐通道平均绝对差（0...255）。
    static func meanChannelDifference(_ a: CGImage, _ b: CGImage) -> (r: Double, g: Double, b: Double) {
        let pa = rgba(a), pb = rgba(b)
        var sum = [0.0, 0.0, 0.0]
        let n = pa.count / 4
        for i in 0..<n {
            for c in 0..<3 {
                sum[c] += abs(Double(pa[i * 4 + c]) - Double(pb[i * 4 + c]))
            }
        }
        return (sum[0] / Double(n), sum[1] / Double(n), sum[2] / Double(n))
    }

    private static func rgba(_ image: CGImage, size: Int = 16) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return pixels
    }
}

enum TempDir {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amai-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

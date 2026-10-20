import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 感知哈希，用于判断"画面是否实质变化"（来源：Eira 的 dHash 实现）。
/// 缩到 9×8 灰度后比较相邻像素亮度，光标闪烁、时钟跳动不会翻转多少位，
/// 滚动、切页会翻转大量位。与分辨率无关。
public enum ImageHashing {
    /// Hamming 距离不超过此值视为同一画面。
    public static let sameScreenThreshold = 5

    public static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    public static func isSameScreen(_ a: UInt64, _ b: UInt64) -> Bool {
        distance(a, b) <= sameScreenThreshold
    }
}

public enum JPEGEncoder {
    public enum EncodeError: Error { case destinationUnavailable, finalizeFailed }

    public static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw EncodeError.destinationUnavailable }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EncodeError.finalizeFailed }
        return data as Data
    }
}

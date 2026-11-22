import AmaiCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 画面指纹的薄封装。算法本身在 AmaiCore 的 `ScreenFingerprint`，与 iOS 共用。
/// `dHash` 只反映版式；判断"画面是否实质变化"请用 `fingerprint` + `isSameScreen`，它对只换了文字的画面也敏感。
public enum ImageHashing {
    /// Hamming 距离不超过此值视为版式相同。
    public static let sameScreenThreshold = ScreenFingerprint.sameLayoutThreshold

    public static func dHash(_ image: CGImage) -> UInt64 {
        ScreenFingerprint.dHash(image)
    }

    public static func fingerprint(_ image: CGImage) -> ScreenFingerprint {
        ScreenFingerprint(image: image)
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 只比较 dHash（没有网格时的退路）。
    public static func isSameScreen(_ a: UInt64, _ b: UInt64) -> Bool {
        distance(a, b) <= sameScreenThreshold
    }

    public static func isSameScreen(_ a: ScreenFingerprint, _ b: ScreenFingerprint) -> Bool {
        a.isSameScreen(as: b)
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

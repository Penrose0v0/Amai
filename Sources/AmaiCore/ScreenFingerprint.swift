import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 判断两帧画面是否是"同一屏"的指纹。macOS 采集与 iOS 共用同一份实现。
///
/// 由两部分组成：
/// - `layoutHash`：dHash（缩到 9×8 比较相邻明暗，来源：Eira）。只反映版式，光标、时钟不会翻转多少位，
///   切页、滚动会翻转大量位；但它看不出"版式不变、只换了文字"（聊天、列表、阅读里很常见）。
/// - `detail`：128×128 灰度网格（每格是原图对应区域的平均亮度）。换掉一行文字会让这一行经过的几十个格子
///   明显变亮或变暗，光标闪烁、时钟跳动只影响个位数格子。阈值来自合成画面的测量（14pt 与 11pt 的 Mac 文字、
///   48pt 的 iPhone 文字），见 `ScreenFingerprintTests`。
///
/// 成本：多一次把整帧画到 128×128 灰度的绘制（2560×1440 约 0.15 ms），每块屏幕常驻 16 KB。
/// `detail` 为空（测试或绘制失败）时只按 `layoutHash` 判断，与原来的行为一致。
public struct ScreenFingerprint: Sendable, Equatable {
    public var layoutHash: UInt64
    public var detail: [UInt8]

    /// dHash 汉明距离不超过此值视为版式相同。
    public static let sameLayoutThreshold = 5
    /// 网格边长。
    public static let detailSide = 128
    /// 一格亮度变化超过此值（0...255）才算这一格变了。
    public static let detailCellDelta = 8
    /// 变化的格数不超过此值视为同一屏：容纳光标、时钟、小图标的跳动。
    public static let detailChangedCellLimit = 6

    public init(layoutHash: UInt64, detail: [UInt8] = []) {
        self.layoutHash = layoutHash
        self.detail = detail
    }

    public func layoutDistance(_ other: ScreenFingerprint) -> Int {
        (layoutHash ^ other.layoutHash).nonzeroBitCount
    }

    /// 网格中亮度明显变化的格数；任一方没有网格时为 nil。
    public func changedDetailCells(_ other: ScreenFingerprint) -> Int? {
        guard !detail.isEmpty, detail.count == other.detail.count else { return nil }
        var changed = 0
        for i in detail.indices where abs(Int(detail[i]) - Int(other.detail[i])) > Self.detailCellDelta {
            changed += 1
        }
        return changed
    }

    /// 是否同一屏：版式相同，且（有网格时）文字区域没有成片变化。
    public func isSameScreen(as other: ScreenFingerprint) -> Bool {
        guard layoutDistance(other) <= Self.sameLayoutThreshold else { return false }
        guard let changed = changedDetailCells(other) else { return true }
        return changed <= Self.detailChangedCellLimit
    }

    /// 有两帧的 OCR 文字时优先用文字判断（不增加识别开销，且不受光标、抗锯齿影响）；
    /// 版式明显不同时仍算不同，没有文字时退回画面指纹。
    public func isSameScreen(as other: ScreenFingerprint, text: String?, otherText: String?) -> Bool {
        guard let text, let otherText else { return isSameScreen(as: other) }
        guard layoutDistance(other) <= Self.sameLayoutThreshold else { return false }
        return ScreenTextSimilarity.isSame(text, otherText)
    }
}

#if canImport(CoreGraphics)
extension ScreenFingerprint {
    public init(image: CGImage) {
        self.init(layoutHash: Self.dHash(image), detail: Self.detailGrid(image))
    }

    public static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        guard let pixels = grayscale(image, width: w, height: h, quality: .low) else { return 0 }
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

    /// 绘制失败时返回空数组（退回只用 dHash）。
    static func detailGrid(_ image: CGImage) -> [UInt8] {
        grayscale(image, width: detailSide, height: detailSide, quality: .medium) ?? []
    }

    private static func grayscale(_ image: CGImage, width: Int, height: Int, quality: CGInterpolationQuality) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = quality
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
#endif

/// 两段屏幕文字（OCR 或辅助功能读到的）是否基本相同：按行集合的 Jaccard 相似度。
/// 行内空白折叠后比较，单字符的行（多半是图标被识别成的字符）不计入。
public enum ScreenTextSimilarity {
    public static let sameScreenThreshold = 0.9

    public static func lines(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.count > 1 ? collapsed : nil
        })
    }

    public static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        similarity(lines(a), lines(b))
    }

    public static func isSame(_ a: String, _ b: String, threshold: Double = sameScreenThreshold) -> Bool {
        similarity(a, b) >= threshold
    }
}

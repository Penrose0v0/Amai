import CoreGraphics
import CoreText
import Foundation

/// 合成的屏幕画面：顶栏（应用名、右上角时钟）＋若干行文字，可选闪烁的光标。
///
/// 文字按构造已知，是 OCR 与去重评测的 Ground Truth。尺寸以采集后的像素计（`ScreenCaptureConfiguration`
/// 默认把画面缩到 1080 高）：Retina 屏上的 14pt 文字缩到 1080 高后约 15 px。
/// 合成画面比真实屏幕干净（没有图片、阴影、复杂背景），OCR 结果应视为上界。
public struct ScreenSpec: Codable, Sendable, Equatable, Hashable {
    public enum Theme: String, Codable, Sendable { case light, dark }

    public var app: String
    public var lines: [String]
    public var theme: Theme
    /// 字体名（PostScript 或家族名）；CJK 字符缺字时由 CoreText 自动回退。
    public var font: String
    /// 字号（像素，按采集后的分辨率）。
    public var fontSize: Double
    /// 第一行文字从顶部向下偏移的像素（模拟滚动或不同的版式）。
    public var topOffset: Double

    public init(app: String, lines: [String], theme: Theme = .light, font: String = "PingFang SC", fontSize: Double = 16, topOffset: Double = 0) {
        self.app = app
        self.lines = lines
        self.theme = theme
        self.font = font
        self.fontSize = fontSize
        self.topOffset = topOffset
    }

    enum CodingKeys: String, CodingKey { case app, lines, theme, font, fontSize, topOffset }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        lines = try c.decode([String].self, forKey: .lines)
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .light
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? "PingFang SC"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 16
        topOffset = try c.decodeIfPresent(Double.self, forKey: .topOffset) ?? 0
    }

    /// 屏幕上可见的全部文字（顶栏的应用名与正文；时钟是噪声，不计入）。
    public var visibleText: [String] { [app] + lines }
}

public enum SyntheticScreen {
    public static let defaultWidth = 1728
    public static let defaultHeight = 1080
    static let barHeight = 56.0

    public static func render(
        _ spec: ScreenSpec, width: Int = defaultWidth, height: Int = defaultHeight,
        clock: String = "09:00", cursor: Bool = false
    ) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let dark = spec.theme == .dark
        let background = dark ? CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1) : CGColor(gray: 0.97, alpha: 1)
        let foreground = dark ? CGColor(gray: 0.9, alpha: 1) : CGColor(gray: 0.1, alpha: 1)
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 顶栏：按应用名取一个稳定的颜色，不同应用的版式（dHash）不同。
        let hue = Double(abs(spec.app.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 })) / 997
        ctx.setFillColor(CGColor(red: 0.2 + 0.5 * hue, green: 0.35, blue: 0.85 - 0.5 * hue, alpha: 1))
        let h = Double(height), w = Double(width)
        ctx.fill(CGRect(x: 0, y: h - barHeight, width: w, height: barHeight))
        // 左侧边栏：随应用名变宽窄，进一步区分版式。
        ctx.setFillColor(dark ? CGColor(gray: 0.18, alpha: 1) : CGColor(gray: 0.9, alpha: 1))
        let sidebar = 160 + 120 * hue
        ctx.fill(CGRect(x: 0, y: 0, width: sidebar, height: h - barHeight))

        let barFont = CTFontCreateWithName("PingFang SC" as CFString, 20, nil)
        draw(ctx, spec.app, font: barFont, x: 24, y: h - 36, color: CGColor(gray: 1, alpha: 1))
        draw(ctx, clock, font: barFont, x: w - 90, y: h - 36, color: CGColor(gray: 1, alpha: 1))

        let font = CTFontCreateWithName(spec.font as CFString, spec.fontSize, nil)
        let lineHeight = spec.fontSize * 1.7
        let left = sidebar + 32
        var y = h - barHeight - 40 - spec.topOffset - spec.fontSize
        for line in spec.lines {
            guard y > 0 else { break }
            draw(ctx, line, font: font, x: left, y: y, color: foreground)
            y -= lineHeight
        }
        if cursor {
            ctx.setFillColor(foreground)
            ctx.fill(CGRect(x: left + 420, y: h - barHeight - 44 - spec.topOffset - spec.fontSize, width: 2, height: spec.fontSize + 6))
        }
        return ctx.makeImage()!
    }

    static func draw(_ ctx: CGContext, _ text: String, font: CTFont, x: Double, y: Double, color: CGColor) {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
    }

    /// 按比例缩放（OCR 评测中模拟更低的采集分辨率）。
    public static func scaled(_ image: CGImage, height: Int) -> CGImage {
        guard image.height != height, height > 0 else { return image }
        let width = max(1, Int(Double(image.width) * Double(height) / Double(image.height)))
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import AmaiCore

/// 合成的"文字画面"：浅色背景、彩色顶栏（右上角有时钟）、若干行深色文字，可选一条闪烁的光标。
enum TextScreen {
    static func render(
        width: Int, height: Int, lines: [String], fontSize: CGFloat,
        cursor: Bool = false, clock: String = "10:41"
    ) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(gray: 0.96, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: height - 60, width: width, height: 60))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        func draw(_ text: String, x: CGFloat, y: CGFloat, color: CGColor) {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        draw(clock, x: CGFloat(width - 80), y: CGFloat(height - 40), color: CGColor(gray: 1, alpha: 1))
        for (index, line) in lines.enumerated() {
            draw(line, x: 40, y: CGFloat(height - 120) - CGFloat(index) * fontSize * 1.6, color: CGColor(gray: 0.1, alpha: 1))
        }
        if cursor {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 300, y: CGFloat(height - 124), width: 2, height: fontSize + 4))
        }
        return ctx.makeImage()!
    }

    static let base = (0..<20).map { "Line \($0): the quick brown fox jumps over the lazy dog near riverbank" }
    static let otherText = (0..<20).map { "Line \($0): a slow purple cat walks under the busy log near mountains" }
    static var oneLineChanged: [String] {
        var lines = base
        lines[5] = "Line 5: completely different message arrived from someone else today"
        return lines
    }
}

@Suite("ScreenFingerprint")
struct ScreenFingerprintTests {
    struct Display {
        var name: String
        var width: Int
        var height: Int
        var fontSize: CGFloat
    }

    static let displays = [
        Display(name: "Mac 14pt", width: 1920, height: 1080, fontSize: 14),
        Display(name: "Mac 11pt", width: 1920, height: 1080, fontSize: 11),
        Display(name: "iPhone", width: 1206, height: 2622, fontSize: 48),
    ]

    func fingerprint(_ d: Display, _ lines: [String], cursor: Bool = false, clock: String = "10:41") -> ScreenFingerprint {
        ScreenFingerprint(image: TextScreen.render(width: d.width, height: d.height, lines: lines, fontSize: d.fontSize, cursor: cursor, clock: clock))
    }

    /// 回归：版式相同、只换了文字的画面，dHash 认为是同一屏（iOS PoC 里四个画面只存下 1 张）。
    @Test("same layout with different text is a different screen", arguments: displays)
    func textChangeIsDetected(_ d: Display) {
        let base = fingerprint(d, TextScreen.base)
        for lines in [TextScreen.otherText, TextScreen.oneLineChanged] {
            let changed = fingerprint(d, lines)
            #expect(!base.isSameScreen(as: changed), "\(d.name): \(base.changedDetailCells(changed) ?? -1) cells changed")
        }
    }

    @Test("the failing case: on Mac-sized text dHash alone calls a text-only change a duplicate")
    func dHashAloneIsBlind() {
        for d in Self.displays where d.name.hasPrefix("Mac") {
            let base = fingerprint(d, TextScreen.base)
            for lines in [TextScreen.otherText, TextScreen.oneLineChanged] {
                let changed = fingerprint(d, lines)
                #expect(base.layoutDistance(changed) <= ScreenFingerprint.sameLayoutThreshold, "\(d.name)")
                #expect(!base.isSameScreen(as: changed), "\(d.name)")
            }
        }
    }

    @Test("identical frames, a blinking cursor and a ticking clock stay the same screen", arguments: displays)
    func noiseIsIgnored(_ d: Display) {
        let base = fingerprint(d, TextScreen.base)
        #expect(base == fingerprint(d, TextScreen.base))
        for variant in [fingerprint(d, TextScreen.base, cursor: true), fingerprint(d, TextScreen.base, clock: "10:42")] {
            #expect(base.isSameScreen(as: variant), "\(d.name): \(base.changedDetailCells(variant) ?? -1) cells changed")
        }
    }

    @Test("a different layout is a different screen")
    func layoutChange() {
        let mac = Self.displays[0]
        let base = fingerprint(mac, TextScreen.base)
        let dark = ScreenFingerprint(image: Self.solid(gray: 0.1, width: mac.width, height: mac.height))
        #expect(base.layoutDistance(dark) > ScreenFingerprint.sameLayoutThreshold || !base.isSameScreen(as: dark))
        #expect(!base.isSameScreen(as: dark))
    }

    @Test("without a detail grid only the layout hash decides (previous behaviour)")
    func hashOnlyFallback() {
        let a = ScreenFingerprint(layoutHash: 0)
        #expect(a.isSameScreen(as: ScreenFingerprint(layoutHash: 0b11111)))
        #expect(!a.isSameScreen(as: ScreenFingerprint(layoutHash: 0b111111)))
        #expect(a.changedDetailCells(ScreenFingerprint(layoutHash: 0, detail: [1, 2])) == nil)
    }

    @Test("dHash matches the previous AmaiPerception implementation bit for bit")
    func dHashUnchanged() {
        let images = Self.displays.flatMap { d in
            [TextScreen.base, TextScreen.otherText].map {
                TextScreen.render(width: d.width, height: d.height, lines: $0, fontSize: d.fontSize)
            }
        } + [Self.solid(gray: 0.1, width: 640, height: 480), Self.solid(gray: 0.8, width: 300, height: 900)]
        for image in images {
            #expect(ScreenFingerprint.dHash(image) == Self.referenceDHash(image))
        }
    }

    /// 移到 AmaiCore 之前 `ImageHashing.dHash` 的原样实现。
    static func referenceDHash(_ image: CGImage) -> UInt64 {
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

    @Test("OCR text, when both frames have it, decides between same-layout frames")
    func ocrTextDecides() {
        let mac = Self.displays[0]
        let base = fingerprint(mac, TextScreen.base)
        let cursor = fingerprint(mac, TextScreen.base, cursor: true)
        let text = TextScreen.base.joined(separator: "\n")
        let changedText = TextScreen.oneLineChanged.joined(separator: "\n")
        #expect(base.isSameScreen(as: cursor, text: text, otherText: text))
        #expect(!base.isSameScreen(as: cursor, text: text, otherText: changedText + "\nnew message 1\nnew message 2"))
        // 版式明显不同时即使文字相同也不算同一屏。
        let dark = ScreenFingerprint(image: Self.solid(gray: 0.1, width: mac.width, height: mac.height))
        if base.layoutDistance(dark) > ScreenFingerprint.sameLayoutThreshold {
            #expect(!base.isSameScreen(as: dark, text: text, otherText: text))
        }
        // 缺一方的文字时退回画面指纹。
        #expect(!base.isSameScreen(as: fingerprint(mac, TextScreen.oneLineChanged), text: text, otherText: nil))
    }

    @Test("fingerprinting a full-resolution frame stays cheap")
    func cost() {
        let image = TextScreen.render(width: 2560, height: 1440, lines: TextScreen.base, fontSize: 14)
        let clock = ContinuousClock()
        let runs = 20
        let elapsed = clock.measure { for _ in 0..<runs { _ = ScreenFingerprint(image: image) } }
        // 实测约 0.2 ms；上限放宽到 20 ms，只为挡住数量级的退化（调试构建、CI 负载）。
        #expect(elapsed / runs < .milliseconds(20))
        #expect(ScreenFingerprint(image: image).detail.count == ScreenFingerprint.detailSide * ScreenFingerprint.detailSide)
    }

    static func solid(gray: CGFloat, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1 - gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 3, height: height / 2))
        return ctx.makeImage()!
    }
}

@Suite("ScreenTextSimilarity")
struct ScreenTextSimilarityTests {
    @Test("whitespace differences and single-character lines do not count")
    func normalization() {
        #expect(ScreenTextSimilarity.isSame("Inbox\n  3 new   messages \n×", "Inbox\n3 new messages"))
        #expect(ScreenTextSimilarity.isSame("", "\n \n"))
    }

    @Test("a changed line in a short screen is a change")
    func change() {
        let before = "周末购物清单\n牛奶两盒\n全麦面包一袋\n咖啡豆五百克"
        let after = "今日日程安排\n上午十点 组会\n下午两点 论文修改\n晚上七点 健身"
        #expect(!ScreenTextSimilarity.isSame(before, after))
        #expect(!ScreenTextSimilarity.isSame(before, before.replacingOccurrences(of: "牛奶两盒", with: "牛奶三盒")))
        #expect(ScreenTextSimilarity.isSame(before, before))
    }
}

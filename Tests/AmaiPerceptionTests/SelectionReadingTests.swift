import Foundation
import Testing
@testable import AmaiPerception

@Suite("Selection reading rules")
struct SelectionReadingTests {
    @Test("readable text excludes whitespace, control, invisible and attachment placeholders")
    func hasContent() {
        #expect(AccessibilityReader.hasContent("hello"))
        #expect(AccessibilityReader.hasContent(" 你好 "))
        #expect(!AccessibilityReader.hasContent(""))
        #expect(!AccessibilityReader.hasContent(" \n\t"))
        #expect(!AccessibilityReader.hasContent("\u{FFFC}"))
        #expect(!AccessibilityReader.hasContent("\u{200B}\u{FEFF}"))
        #expect(AccessibilityReader.hasContent("\u{FFFC} caption"))
    }

    @Test("AXValue is sliced by UTF-16 range and out-of-range ranges are rejected")
    func slice() {
        let value = "a😀b中文"
        // 😀 占两个 UTF-16 码元。
        #expect(AXRead.slice(value, CFRange(location: 1, length: 2)) == "😀")
        #expect(AXRead.slice(value, CFRange(location: 4, length: 2)) == "中文")
        #expect(AXRead.slice(value, CFRange(location: 5, length: 2)) == nil)
        #expect(AXRead.slice(value, CFRange(location: -1, length: 1)) == nil)
        #expect(AXRead.slice(value, CFRange(location: 6, length: 0)) == "")
    }

    @Test("copy fallback: only when Accessibility cannot read it, never into Amai or under secure input")
    func copyFallbackRules() {
        for read in [SelectionRead.unknown, .emptyField] {
            #expect(CopyFallback.applies(read: read, amaiHasKeyboard: false, secureInput: false))
            #expect(!CopyFallback.applies(read: read, amaiHasKeyboard: true, secureInput: false))
            #expect(!CopyFallback.applies(read: read, amaiHasKeyboard: false, secureInput: true))
        }
        #expect(!CopyFallback.applies(read: .none(.secureField), amaiHasKeyboard: false, secureInput: false))
        #expect(!CopyFallback.applies(read: .none(.unresponsive), amaiHasKeyboard: false, secureInput: false))
        let found = SelectionRead.text(TextSelection(text: "x", pid: 1))
        #expect(!CopyFallback.applies(read: found, amaiHasKeyboard: false, secureInput: false))
    }

    @Test("copied text counts only when the pasteboard changed and holds readable text, not files")
    func copiedText() {
        #expect(CopyFallback.copiedText(changed: true, string: "selected", hasFiles: false) == "selected")
        // 剪贴板没变：那是用户自己的内容。
        #expect(CopyFallback.copiedText(changed: false, string: "user clipboard", hasFiles: false) == nil)
        #expect(CopyFallback.copiedText(changed: true, string: "report.pdf", hasFiles: true) == nil)
        #expect(CopyFallback.copiedText(changed: true, string: "  \n", hasFiles: false) == nil)
        #expect(CopyFallback.copiedText(changed: true, string: nil, hasFiles: false) == nil)
    }

    @Test("web engines are told apart by bundled frameworks")
    func webEngines() {
        #expect(WebEngine.classify(frameworks: ["Electron Framework.framework", "Squirrel.framework"]) == .electron)
        #expect(WebEngine.classify(frameworks: ["Google Chrome Framework.framework"]) == .chromiumBrowser)
        #expect(WebEngine.classify(frameworks: ["Chromium Embedded Framework.framework"]) == .chromiumBrowser)
        #expect(WebEngine.classify(frameworks: ["Sparkle.framework"]) == .other)
        #expect(WebEngine.classify(frameworks: []) == .other)
    }

    @Test("a blocking call that overruns its limit returns the fallback")
    func blockingDeadline() async {
        let quick = await BlockingCall.value(within: .milliseconds(500), fallback: 0) { 1 }
        #expect(quick == 1)
        let start = ContinuousClock.now
        let slow = await BlockingCall.value(within: .milliseconds(100), fallback: 0) {
            Thread.sleep(forTimeInterval: 0.6)
            return 1
        }
        #expect(slow == 0)
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }
}

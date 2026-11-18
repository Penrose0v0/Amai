import AmaiCore
import CoreGraphics
import Foundation
import os
import Testing
@testable import AmaiPerception

final class FakeWindowSource: WindowFrameSource, @unchecked Sendable {
    var image: CGImage?
    private(set) var calls = 0
    func captureFrontWindow(pid: pid_t, maxHeight: Int) async throws -> CapturedFrame? {
        calls += 1
        return image.map { CapturedFrame(image: $0, displayId: 0) }
    }
}

/// 按调用顺序返回脚本化的文字，并记录调用次数。
final class FakeRecognizer: TextRecognizer, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (texts: [String](), calls: 0))
    init(_ texts: [String] = []) { state.withLock { $0.texts = texts } }
    var calls: Int { state.withLock { $0.calls } }
    func recognize(jpeg: Data) async throws -> OCRResult {
        let text = state.withLock { s -> String in
            s.calls += 1
            return s.texts.isEmpty ? "screen text \(s.calls)" : s.texts.removeFirst()
        }
        return OCRResult(lines: text.split(separator: "\n").map { OCRLine(text: String($0), confidence: 0.9) })
    }
}

final class FakeFocus: FocusReading, @unchecked Sendable {
    var isTrusted = true
    var title: String? = "Draft.md"
    var selected: TextSelection? = TextSelection(text: "hello world", isEditable: true, pid: 1)
    var outcome: ReplaceOutcome = .replaced
    private(set) var replaced: [String] = []
    func windowTitle(pid: pid_t) -> String? { title }
    func selection(pid: pid_t, bundleId: String?) -> TextSelection? { selected }
    func replace(_ selection: TextSelection, with text: String) -> ReplaceOutcome {
        replaced.append(text)
        return outcome
    }
}

@Suite("Live context reader")
struct LiveContextTests {
    struct Harness {
        let reader: LiveContextReader
        let screens: FakeScreenSource
        let windows = FakeWindowSource()
        let frontmost = FakeFrontmost()
        let secure = FakeSecureInput()
        let ocr: FakeRecognizer
        let focus = FakeFocus()
        let clock = FakeClock()

        init(ocr: FakeRecognizer = FakeRecognizer(), excluded: Set<String> = ["com.1password.1password"]) {
            self.ocr = ocr
            screens = FakeScreenSource(image: SyntheticImage.make(seed: 1))
            reader = LiveContextReader(dependencies: .init(
                screens: screens, windows: windows, target: frontmost, secureInput: secure,
                policy: ExclusionListPolicy(excludedBundleIds: excluded), ocr: ocr, focus: focus, clock: clock,
                alwaysExcludedBundleIds: ["com.amai.app"]
            ))
        }

        func tick(seed: Int) async {
            let image = SyntheticImage.make(seed: seed)
            await reader.didCapture(
                ScreenCapture(frames: [CapturedFrame(image: image, displayId: 1)], focusDisplayId: 1),
                hashes: [:], frontmost: frontmost.app, at: clock.now()
            )
        }
    }

    @Test("a fresh background frame is reused; a stale one triggers a new capture that hides Amai's own windows")
    func reuseOrCapture() async throws {
        let h = Harness()
        await h.tick(seed: 1)
        h.clock.advance(1)
        let reused = try await h.reader.screen(.desktop, maxAge: 2, maxHeight: 1080)
        #expect(reused.reusedBackgroundFrame)
        #expect(h.screens.calls == 0)

        h.clock.advance(5)
        let fresh = try await h.reader.screen(.desktop, maxAge: 2, maxHeight: 1080)
        #expect(!fresh.reusedBackgroundFrame)
        #expect(h.screens.calls == 1)
        #expect(h.screens.lastExcluded == ["com.1password.1password", "com.amai.app"])
        #expect(!fresh.jpeg.isEmpty)

        // 现截的那一帧随后也可以复用。
        _ = try await h.reader.screen(.desktop, maxAge: 2, maxHeight: 1080)
        #expect(h.screens.calls == 1)
    }

    @Test("a frame captured while another app was frontmost is not reused")
    func appChanged() async throws {
        let h = Harness()
        await h.tick(seed: 1)
        h.frontmost.app = FrontmostApp(name: "Safari", bundleId: "com.apple.Safari", pid: 2)
        _ = try await h.reader.screen(.desktop, maxAge: 10, maxHeight: 1080)
        #expect(h.screens.calls == 1)
    }

    @Test("the focused window is captured on its own, falling back to the display when there is none")
    func focusedWindow() async throws {
        let h = Harness()
        h.windows.image = SyntheticImage.make(seed: 4)
        let window = try await h.reader.screen(.focusedWindow, maxAge: 2, maxHeight: 1080)
        #expect(window.scope == .focusedWindow)
        #expect(h.screens.calls == 0)

        h.windows.image = nil
        let fallback = try await h.reader.screen(.focusedWindow, maxAge: 2, maxHeight: 1080)
        #expect(fallback.scope == .desktop)
        #expect(h.screens.calls == 1)
    }

    @Test("screen text is recognized once while the screen stays the same; a changed screen or an old result is read again")
    func recognitionReuse() async throws {
        let h = Harness()
        h.windows.image = SyntheticImage.make(seed: 4)
        // 面板唤出时识别一次；用户提交时再读一次做确认——画面没变，不重复 OCR。
        let first = try await h.reader.screenText(.focusedWindow, maxAge: 2)
        h.clock.advance(20)
        #expect(try await h.reader.screenText(.focusedWindow, maxAge: 2) == first)
        #expect(h.ocr.calls == 1 && h.windows.calls == 2)

        h.windows.image = SyntheticImage.make(seed: 9)
        let changed = try await h.reader.screenText(.focusedWindow, maxAge: 2)
        #expect(changed != first && h.ocr.calls == 2)

        // 同一画面但隔得太久：哈希看不出小改动，重新识别。
        h.clock.advance(LiveContextReader.recognitionReuseWindow + 1)
        _ = try await h.reader.screenText(.focusedWindow, maxAge: 2)
        #expect(h.ocr.calls == 3)

        // 暂停或清除数据后不留着旧的文字。
        await h.reader.forget()
        _ = try await h.reader.screenText(.focusedWindow, maxAge: 2)
        #expect(h.ocr.calls == 4)
    }

    @Test("excluded apps and secure input block interactive reads; a skipped tick drops the cached frame")
    func privacy() async throws {
        let h = Harness()
        await h.tick(seed: 1)
        h.secure.active = true
        await #expect(throws: LiveContextError.blocked(reason: "secureInput")) {
            try await h.reader.screen(.desktop, maxAge: 10, maxHeight: 1080)
        }
        let blockedFocus = await h.reader.focus()
        #expect(blockedFocus.appName == nil && blockedFocus.selectedText == nil)
        h.secure.active = false

        h.frontmost.app = FrontmostApp(name: "1Password", bundleId: "com.1password.1password", pid: 9)
        await #expect(throws: LiveContextError.blocked(reason: "excludedApp")) {
            try await h.reader.screenText(.desktop, maxAge: 10)
        }
        #expect(h.screens.calls == 0 && h.ocr.calls == 0)

        // 采集器因隐私跳过一次后，之前的画面不能再复用。
        h.frontmost.app = FrontmostApp(name: "Xcode", bundleId: "com.apple.dt.Xcode", pid: 1)
        await h.reader.didNotCapture()
        _ = try await h.reader.screen(.desktop, maxAge: 10, maxHeight: 1080)
        #expect(h.screens.calls == 1)
    }

    @Test("focus reports app, window title and selection; replacement only applies to the selection that was read")
    func focusAndReplace() async {
        let h = Harness()
        let snapshot = await h.reader.focus()
        #expect(snapshot.appName == "Xcode" && snapshot.windowTitle == "Draft.md")
        #expect(snapshot.selectedText == "hello world" && snapshot.selectionIsEditable)

        #expect(await h.reader.replaceSelection(expecting: "something else", with: "x") == .selectionChanged)
        #expect(h.focus.replaced.isEmpty)
        #expect(await h.reader.replaceSelection(expecting: "hello world", with: "你好，世界") == .replaced)
        #expect(h.focus.replaced == ["你好，世界"])
        // 同一个选区只替换一次。
        #expect(await h.reader.replaceSelection(expecting: "hello world", with: "again") == .selectionChanged)

        h.focus.isTrusted = false
        let untrusted = await h.reader.focus()
        #expect(untrusted.appName == "Xcode" && untrusted.windowTitle == nil && !untrusted.accessibilityGranted)
    }

    @Test("recent states: OCR runs only when asked, once per state, and secrets are redacted")
    func recentStatesOnDemand() async {
        let ocr = FakeRecognizer(["编辑 Package.swift\nswift build", "阅读 ADR-0008\napi_key = sk-abcdefghijklmnopqrstuvwxyz123456"])
        let h = Harness(ocr: ocr)
        await h.reader.setBackgroundActive(true)
        await h.tick(seed: 1)
        h.clock.advance(10)
        await h.tick(seed: 1)       // 同一屏：不新增
        h.clock.advance(10)
        h.frontmost.app = FrontmostApp(name: "Safari", bundleId: "com.apple.Safari", pid: 2)
        await h.tick(seed: 2)
        #expect(ocr.calls == 0)

        let states = await h.reader.recentStates()
        #expect(states.map(\.appName) == ["Xcode", "Safari"])
        #expect(states[0].text.contains("Package.swift") && states[0].windowTitle == "Draft.md")
        #expect(!states[1].text.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        #expect(ocr.calls == 2)
        _ = await h.reader.recentStates()
        #expect(ocr.calls == 2)

        // 超过 5 分钟的状态被丢弃；暂停后清空。
        h.clock.advance(400)
        #expect(await h.reader.recentStates().isEmpty)
        await h.tick(seed: 3)
        await h.reader.setBackgroundActive(false)
        #expect(await h.reader.recentStates().isEmpty)
        await h.tick(seed: 4)
        #expect(await h.reader.recentStates().isEmpty)
    }
}

@Suite("Recent context buffer")
struct RecentContextBufferTests {
    static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    @Test("capacity is bounded and near-identical texts are collapsed")
    func capacityAndDedupe() {
        var buffer = RecentContextBuffer()
        var encodes = 0
        for i in 0..<8 {
            // 每个状态换一个应用，保证都是新状态。
            buffer.note(hash: UInt64(i), appName: "App\(i)", bundleId: "b\(i)", windowTitle: nil, at: Self.t0.addingTimeInterval(Double(i))) {
                encodes += 1
                return Data([UInt8(i)])
            }
        }
        #expect(buffer.states.count == 5 && encodes == 8)
        #expect(buffer.states.first?.appName == "App3")

        for index in buffer.states.indices {
            buffer.setText(index == 1 || index == 3 ? "第一行内容\n第二行内容\n第三行内容" : "独有的内容 \(index)\n另一行 \(index)", at: index)
        }
        let distinct = buffer.distinctStates()
        // 两个文字相同的状态只保留较新的那个。
        #expect(distinct.map(\.appName) == ["App3", "App5", "App6", "App7"])
    }

    @Test("small changes in the same app update the last state instead of adding one")
    func updateInPlace() {
        var buffer = RecentContextBuffer()
        let base: UInt64 = 0
        #expect(buffer.note(hash: base, appName: "Xcode", bundleId: "x", windowTitle: "a", at: Self.t0) { Data([1]) } == .added)
        #expect(buffer.note(hash: 0b111, appName: "Xcode", bundleId: "x", windowTitle: "a", at: Self.t0.addingTimeInterval(10)) { Data([2]) } == .unchanged)
        buffer.setText("old", at: 0)
        #expect(buffer.note(hash: 0xFF, appName: "Xcode", bundleId: "x", windowTitle: "b", at: Self.t0.addingTimeInterval(20)) { Data([3]) } == .updated)
        #expect(buffer.states.count == 1 && buffer.states[0].text == nil && buffer.states[0].windowTitle == "b")
        #expect(buffer.note(hash: 0xFFFF_FFFF, appName: "Xcode", bundleId: "x", windowTitle: "c", at: Self.t0.addingTimeInterval(30)) { Data([4]) } == .added)
        #expect(buffer.states.count == 2)
    }
}

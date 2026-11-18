import AppKit
import Carbon.HIToolbox
import CoreText
import Foundation
import Testing
@testable import AmaiPerception

/// 真实应用里的选区读取兼容性检查。会打开应用、向前台应用发送 ⌘A，必要时执行菜单"拷贝"，
/// 默认不运行；只在明确设置环境变量时运行，且只使用这里生成的合成文件：
///
///     AMAI_LIVE_SELECTION=1 [AMAI_LIVE_APPS=textedit,preview,safari,chrome,vscode] swift test --filter SelectionLive
///
/// 运行进程需要辅助功能权限。每个用例打印一行 `LIVE|…` 结果；没装的应用记为 skipped。
/// 对 VS Code 不关闭标签页（它可能是正在使用的编辑器）。
@Suite(
    "Live selection compatibility", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AMAI_LIVE_SELECTION"] == "1")
)
@MainActor
struct SelectionLiveTests {
    static let probe = "Amai selection probe 选区读取测试 4242"
    enum Expect { case readable, secure }

    struct Case {
        let name: String
        let bundleId: String
        let file: String
        let expect: Expect
        /// 结束时关闭打开的文档 / 标签页（⌘W）。
        let closes: Bool
    }

    static let cases: [Case] = [
        Case(name: "textedit", bundleId: "com.apple.TextEdit", file: "note.txt", expect: .readable, closes: true),
        Case(name: "preview", bundleId: "com.apple.Preview", file: "doc.pdf", expect: .readable, closes: true),
        Case(name: "safari-page", bundleId: "com.apple.Safari", file: "page.html", expect: .readable, closes: true),
        Case(name: "safari-textarea", bundleId: "com.apple.Safari", file: "textarea.html", expect: .readable, closes: true),
        Case(name: "safari-contenteditable", bundleId: "com.apple.Safari", file: "editable.html", expect: .readable, closes: true),
        Case(name: "safari-password", bundleId: "com.apple.Safari", file: "password.html", expect: .secure, closes: true),
        Case(name: "chrome-page", bundleId: "com.google.Chrome", file: "page.html", expect: .readable, closes: true),
        Case(name: "chrome-textarea", bundleId: "com.google.Chrome", file: "textarea.html", expect: .readable, closes: true),
        Case(name: "chrome-contenteditable", bundleId: "com.google.Chrome", file: "editable.html", expect: .readable, closes: true),
        Case(name: "chrome-password", bundleId: "com.google.Chrome", file: "password.html", expect: .secure, closes: true),
        Case(name: "vscode", bundleId: "com.microsoft.VSCode", file: "note.md", expect: .readable, closes: false),
        Case(name: "cursor", bundleId: "com.todesktop.230313mzl4w4u92", file: "note.md", expect: .readable, closes: false),
    ]

    @Test("selection read / replace in real apps")
    func liveApps() async throws {
        #expect(AXIsProcessTrusted(), "the test process needs Accessibility permission")
        let wanted = ProcessInfo.processInfo.environment["AMAI_LIVE_APPS"].map {
            Set($0.split(separator: ",").map(String.init))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amai-live-selection-\(UUID().uuidString)")
        try Self.writeFixtures(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wasRunning = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var launched: Set<String> = []
        for item in Self.cases where wanted.map({ set in set.contains { item.name.hasPrefix($0) } }) ?? true {
            let line = await run(item, dir: dir)
            // 读取前就失败的用例也要关掉它打开的标签页（尤其是密码页：它会一直开着安全输入）。
            if line.hasPrefix("opened|lost focus"), item.closes,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleId).first {
                _ = await press(kVK_ANSI_W, "w", in: app.processIdentifier)
            }
            if !wasRunning.contains(item.bundleId), line.hasPrefix("opened") { launched.insert(item.bundleId) }
            print("LIVE|\(item.name)|\(line)")
        }
        // 只退出这次测试启动的应用。
        for bundleId in launched {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).forEach { $0.terminate() }
        }
    }

    private func run(_ item: Case, dir: URL) async -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleId) else {
            return "skipped (not installed)"
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let app = try? await NSWorkspace.shared.open(
            [dir.appendingPathComponent(item.file)], withApplicationAt: appURL, configuration: config
        ) else { return "failed to open" }
        let pid = app.processIdentifier
        guard await waitFrontmost(pid, within: .seconds(10)) else { return "opened|not frontmost" }
        AccessibilityReader.prepare(pid: pid, bundleId: item.bundleId)
        try? await Task.sleep(for: .seconds(2))
        // 浏览器打开文件后键盘焦点可能留在地址栏：把焦点交给网页（页面脚本随后把焦点放回自己的输入框）。
        if item.file.hasSuffix(".html") {
            for _ in 0..<4 where Self.focusedRole(pid: pid)?.hasPrefix("AXTextField") ?? true {
                Self.focusWebArea(pid: pid)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }

        var fields = ["opened", "role=\(Self.focusedRole(pid: pid) ?? "-")"]
        let pasteboard = NSPasteboard.general
        let sentinel = "user clipboard \(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(sentinel, forType: .string)

        guard await press(kVK_ANSI_A, "a", in: pid) else { return "opened|lost focus" }
        try? await Task.sleep(for: .milliseconds(500))

        let reader = AccessibilityReader()
        let start = ContinuousClock.now
        let read = reader.readSelection(pid: pid, bundleId: item.bundleId)
        var selection: TextSelection?
        switch read {
        case .text(let found):
            selection = found
            fields.append("ax=text")
        case .unknown, .emptyField:
            if case .emptyField = read { fields.append("ax=emptyField") } else { fields.append("ax=unknown") }
            if let copied = await SystemSelectionCopier().copySelection(from: pid) {
                selection = TextSelection(text: copied, pid: pid, source: .copy)
                fields.append("copy=text")
            } else {
                fields.append("copy=none")
            }
        case .none(let miss):
            fields.append("ax=none(\(miss))")
        }
        fields.append("ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
        fields.append("clipboardRestored=\(pasteboard.string(forType: .string) == sentinel)")
        fields.append("secureInput=\(IsSecureEventInputEnabled())")

        if let selection {
            fields.append("matches=\(selection.text.contains(Self.probe))")
            // 合成密码，不是真实凭据：确认读取器有没有把它读出来。
            fields.append("secretRead=\(selection.text.contains("synthetic-not-a-secret"))|len=\(selection.text.count)")
            fields.append("source=\(selection.source)")
        }
        fields.append("expect=\(item.expect)")
        fields.append("verdict=\(verdict(item.expect, read: read, fields: fields))")
        if item.closes {
            _ = await press(kVK_ANSI_W, "w", in: pid)
            try? await Task.sleep(for: .milliseconds(500))
        }
        pasteboard.clearContents()
        return fields.joined(separator: "|")
    }

    private func verdict(_ expect: Expect, read: SelectionRead, fields: [String]) -> String {
        let has = { (s: String) in fields.contains(s) }
        switch expect {
        case .secure:
            if case .none(.secureField) = read { return "ok" }
            return has("copy=text") || has("ax=text") ? "LEAK" : "ok(no text)"
        case .readable:
            return has("matches=true") ? "ok" : "unreadable"
        }
    }

    /// 只向前台的目标应用发送按键；不在前台时先把它激活回来。
    private func press(_ fallback: Int, _ character: Character, in pid: pid_t) async -> Bool {
        guard await waitFrontmost(pid, within: .seconds(3)) else { return false }
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(fallback), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        return true
    }

    private func waitFrontmost(_ pid: pid_t, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            guard ContinuousClock.now < deadline else { return false }
            NSRunningApplication(processIdentifier: pid)?.activate()
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    static func focusedRole(pid: pid_t) -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return [role as? String, subrole as? String].compactMap { $0 }.joined(separator: "/")
    }

    static func focusWebArea(pid: pid_t) {
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" { return element }
            guard depth < 12 else { return nil }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement]) ?? [] {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, let area = find(window as! AXUIElement, depth: 0)
        else { return }
        AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: - Synthetic fixtures

    static func writeFixtures(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("note.txt", probe)
        try write("note.md", probe + "\n")
        let head = "<!doctype html><meta charset=utf-8><title>Amai probe</title>"
        try write("page.html", head + "<body><p>\(probe)</p></body>")
        try write("textarea.html", head + "<body><textarea id=t autofocus rows=4 cols=60>\(probe)</textarea>"
            + "<script>document.getElementById('t').focus()</script></body>")
        try write("editable.html", head + "<body><div id=e contenteditable=true>\(probe)</div>"
            + "<script>document.getElementById('e').focus()</script></body>")
        try write("password.html", head + "<body><input id=p type=password value=\"synthetic-not-a-secret\" autofocus>"
            + "<script>document.getElementById('p').focus()</script></body>")
        try writePDF(to: dir.appendingPathComponent("doc.pdf"))
    }

    static func writePDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: probe, attributes: attributes))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }
}

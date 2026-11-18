import AmaiCore
import AppKit
import ApplicationServices
import Foundation

/// 通过辅助功能（Accessibility）读取前台应用的窗口标题与选中文字，并在用户明确要求时替换选区。
/// 读取部分移植自 Eira 的 SelectionReader / ActiveAppReader。
///
/// - 只在用户发起交互时对目标应用做一次查询，不安装全局事件监听；
/// - 没有辅助功能权限时所有读取返回 nil；
/// - 每次查询设了较短的消息超时，目标应用卡住时不会拖住调用方。
public protocol FocusReading: Sendable {
    var isTrusted: Bool { get }
    func windowTitle(pid: pid_t) -> String?
    func selection(pid: pid_t, bundleId: String?) -> TextSelection?
    /// 把 `selection` 所在控件当前的选区替换为 `text`。只有选区仍与读取时一致才执行。
    func replace(_ selection: TextSelection, with text: String) -> ReplaceOutcome
}

/// 一次读取到的选区。保留着控件的引用，供之后替换时确认"还是那个选区"。
public struct TextSelection: @unchecked Sendable {
    public let text: String
    /// 控件的选中文字属性是否可写。网页正文、PDF 等只读内容为 false。
    public let isEditable: Bool
    public let pid: pid_t
    // AXUIElement 是不可变的 CF 引用，跨并发域传递安全。
    let element: AXUIElement?

    public init(text: String, isEditable: Bool, pid: pid_t) {
        self.init(text: text, isEditable: isEditable, pid: pid, element: nil)
    }

    init(text: String, isEditable: Bool, pid: pid_t, element: AXUIElement?) {
        self.text = text
        self.isEditable = isEditable
        self.pid = pid
        self.element = element
    }
}

public enum ReplaceOutcome: Sendable, Equatable {
    case replaced
    /// 选区已经变了（用户改了选择或内容），为避免改错地方没有执行。
    case selectionChanged
    /// 控件不支持直接写入，调用方可以改用粘贴。
    case notSupported
    case notTrusted
}

public struct AccessibilityReader: FocusReading {
    /// 基于 Chromium 的应用在有辅助客户端请求之前不建立网页内容的 AX 树；
    /// 对这些应用先打开 `AXManualAccessibility`（Chromium / Electron 为此提供的开关，不影响窗口动画）。
    public static let chromiumBundleIds: Set<String> = [
        "company.thebrowser.dia", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "com.microsoft.VSCode", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "notion.id",
    ]

    private static let messagingTimeout: Float = 0.5

    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    /// 触发系统的辅助功能授权提示（只在用户点击"授权"时调用）。
    @discardableResult
    public static func requestTrust() -> Bool {
        // kAXTrustedCheckOptionPrompt 的值；该全局变量在 Swift 6 下不是并发安全的，直接写出字面量。
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @MainActor
    public static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// 让 Chromium 应用开始建立 AX 树。树需要一点时间才可读，所以在应用被激活时就调用。
    public static func prepare(pid: pid_t, bundleId: String?) {
        guard AXIsProcessTrusted(), let bundleId, chromiumBundleIds.contains(bundleId) else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    public func windowTitle(pid: pid_t) -> String? {
        guard isTrusted else { return nil }
        let app = Self.application(pid)
        guard let window = Self.element(app, kAXFocusedWindowAttribute),
              let title = Self.string(window, kAXTitleAttribute), !title.isEmpty
        else { return nil }
        return title
    }

    public func selection(pid: pid_t, bundleId: String?) -> TextSelection? {
        guard isTrusted else { return nil }
        Self.prepare(pid: pid, bundleId: bundleId)
        let app = Self.application(pid)
        guard let focused = Self.element(app, kAXFocusedUIElementAttribute) else { return nil }

        if let text = Self.string(focused, kAXSelectedTextAttribute), !Self.isBlank(text) {
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable)
            return TextSelection(text: text, isEditable: settable.boolValue, pid: pid, element: focused)
        }
        // 不可编辑的网页内容（WebKit / Chromium）用不透明的 text marker 区间表示选区。
        if let text = Self.textMarkerSelection(focused), !Self.isBlank(text) {
            return TextSelection(text: text, isEditable: false, pid: pid, element: focused)
        }
        return nil
    }

    public func replace(_ selection: TextSelection, with text: String) -> ReplaceOutcome {
        guard isTrusted else { return .notTrusted }
        guard selection.isEditable, let element = selection.element else { return .notSupported }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        // 写入前确认控件里选中的仍是当初那段文字。
        guard Self.string(element, kAXSelectedTextAttribute) == selection.text else { return .selectionChanged }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return status == .success ? .replaced : .notSupported
    }

    // MARK: - AX helpers

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(ref, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func textMarkerSelection(_ element: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let range
        else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, range, &text
        ) == .success else { return nil }
        return text as? String
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

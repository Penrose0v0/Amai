import AmaiCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os

/// 通过辅助功能（Accessibility）读取前台应用的窗口标题与选中文字。只读：不写入其他应用。
/// 读取顺序参考 AtD（JUNERDD/Atd，MIT）的 macOS Selection 模块，见 docs/references/atd.md。
///
/// - 只在用户发起交互时对目标应用做一次查询，不安装全局事件监听，也不持续监听选区；
/// - 没有辅助功能权限时所有读取返回空；
/// - 每条 AX 消息有较短的超时，一次读取还有总时限；目标应用没有回应（`cannotComplete`）就放弃整次读取。
///   这些调用都是阻塞的，调用方须放在主线程以外（`LiveContextReader` 经 `BlockingCall` 执行）。
public protocol FocusReading: Sendable {
    var isTrusted: Bool { get }
    func windowTitle(pid: pid_t) -> String?
    /// 只经辅助功能读取选区；读不到时说明原因（以及能不能用复制回退）。
    func readSelection(pid: pid_t, bundleId: String?) -> SelectionRead
}

extension FocusReading {
    public func selection(pid: pid_t, bundleId: String?) -> TextSelection? {
        readSelection(pid: pid, bundleId: bundleId).selection
    }
}

/// 一次读取到的选区。
public struct TextSelection: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// 经辅助功能读到。
        case accessibility
        /// 辅助功能看不到选区，经菜单"拷贝"读到。
        case copy
    }

    public let text: String
    public let pid: pid_t
    public let source: Source

    public init(text: String, pid: pid_t, source: Source = .accessibility) {
        self.text = text
        self.pid = pid
        self.source = source
    }
}

/// 一次辅助功能读取的结果。
public enum SelectionRead: Sendable {
    case text(TextSelection)
    /// 辅助功能看不出有没有选区：自绘选区的编辑器（VS Code 非读屏模式）、网页自绘的选区、
    /// 读不出文字的非空区间等。只有这种情况允许复制回退。
    case unknown
    /// 焦点是空的原生文本框。通常确实没选东西；但有的应用（微信）在别处（消息气泡）选中文字时
    /// 键盘焦点仍留在输入框里。只有菜单栏"拷贝"可用时才经菜单复制。
    case emptyField
    case none(SelectionMiss)

    public var selection: TextSelection? {
        if case .text(let selection) = self { selection } else { nil }
    }
}

public enum SelectionMiss: Sendable, Equatable {
    /// 没有权限、没有焦点控件，或者焦点在 Amai 自己身上。
    case unavailable
    /// 密码框：不读取，也不复制。
    case secureField
    /// 目标应用在时限内没有回应。
    case unresponsive
}

public struct AccessibilityReader: FocusReading {
    /// 单条 AX 消息的超时。AX 默认约 6 秒，目标应用卡住时会拖住调用方。
    static let messagingTimeout: Float = 0.25
    /// 一次读取（含子 / 父控件搜索）的总时限；超过后放弃剩下的查询。
    static let readBudget: Duration = .milliseconds(800)

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

    // MARK: - Web content preparation

    /// 让网页内容的 AX 树在快捷键按下之前就建立好（在应用被激活时调用，树需要一点时间才可读）。
    ///
    /// - Chromium 浏览器：设置 `AXManualAccessibility`（Chromium 为辅助客户端提供的开关，没有
    ///   `AXEnhancedUserInterface` 那样的窗口动画副作用）。
    /// - Electron 应用（VS Code、Cursor、Slack…）：只读一次应用的 `AXRole`，让它进入基本辅助模式。
    ///   这些应用把 `AXManualAccessibility` 当作屏幕阅读器在场：VS Code / Cursor 会弹出提示、
    ///   把编辑器切到读屏模式，选"否"还会写入用户设置（AtD 的结论）。
    public static func prepare(pid: pid_t, bundleId: String?) {
        guard AXIsProcessTrusted() else { return }
        let app = application(pid)
        switch WebEngine.of(pid: pid, bundleId: bundleId) {
        case .chromiumBrowser:
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        case .electron:
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
        case .other:
            break
        }
    }

    // MARK: - Reading

    public func windowTitle(pid: pid_t) -> String? {
        guard isTrusted else { return nil }
        var read = AXRead(budget: Self.readBudget)
        guard let window: AXUIElement = read.copy(Self.application(pid), kAXFocusedWindowAttribute),
              let title: String = read.copy(window, kAXTitleAttribute), !title.isEmpty
        else { return nil }
        return title
    }

    public func readSelection(pid: pid_t, bundleId: String?) -> SelectionRead {
        guard isTrusted, pid != ProcessInfo.processInfo.processIdentifier else { return .none(.unavailable) }
        // 安全输入开启说明有密码框拿着键盘。网页里的密码框焦点常报告为 AXWebArea 而不是
        // AXSecureTextField，选中后还能读到等长的掩码，所以这里先整体拒绝。
        if IsSecureEventInputEnabled() { return .none(.secureField) }
        var read = AXRead(budget: Self.readBudget)
        let app = Self.application(pid)
        var focused: AXUIElement? = read.copy(app, kAXFocusedUIElementAttribute)
        if focused == nil, !read.aborted { focused = read.copy(app, kAXFocusedWindowAttribute) }
        guard let focused, !read.aborted else { return .none(read.aborted ? .unresponsive : .unavailable) }
        if read.isSecure(focused) { return .none(.secureField) }

        var found = read.search(from: focused)
        // Chromium / Electron 在自己的窗口失去键盘焦点后（例如 Amai 的面板成了 key window）不再报告焦点控件，
        // 只剩焦点窗口：到窗口里找网页区域，读它的文档选区。
        if found == nil, !read.aborted, read.isWindow(focused) {
            found = read.searchWebAreas(in: focused)
        }
        if let (text, _) = found {
            return .text(TextSelection(text: text, pid: pid, source: .accessibility))
        }
        if read.touchedSecureField { return .none(.secureField) }
        guard !read.aborted else { return .none(.unresponsive) }
        if read.isEmptyNativeText(focused) { return .emptyField }
        guard !read.aborted else { return .none(.unresponsive) }
        return .unknown
    }

    // MARK: - Helpers

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    /// 是否有可读的文字：只有空白、控制字符、不可见字符或附件占位符（U+FFFC）不算。
    static func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value != 0xFFFC
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
                && !scalar.properties.isDefaultIgnorableCodePoint
        }
    }
}

// MARK: - One read

/// 原生文本控件的角色。
let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

/// 只有网页内容（WebKit、Chromium）才声明的属性。
let webAttributes: Set<String> = [
    "AXSelectedTextMarkerRange", "AXStartTextMarker", "AXDOMIdentifier", "AXDOMClassList",
]

/// 一次读取的 AX 调用：任何一条 `cannotComplete`（应用没有回应）或超过总时限都中止整次读取。
struct AXRead {
    enum ElementSelection {
        case text(String)
        /// 控件明确表示选区为空：停止搜索。
        case empty
        /// 这个控件看不出：继续找子控件 / 父控件。
        case none
    }

    /// 焦点读不到时，搜索焦点的前若干个子控件，再往上找若干层父控件。
    static let childLimit = 20
    static let ancestorLimit = 10
    /// 焦点只剩窗口时搜索网页区域的范围：层数与访问的节点数。
    static let webAreaSearchDepth = 24
    static let webAreaSearchLimit = 400

    private(set) var aborted = false
    /// 搜索中发现选区落在密码框里。
    private(set) var touchedSecureField = false
    private let deadline: ContinuousClock.Instant

    init(budget: Duration) {
        deadline = .now + budget
    }

    /// 焦点 → 它的子控件 → 它的父控件，返回第一段选中文字和读出它的控件。
    mutating func search(from focused: AXUIElement) -> (String, AXUIElement)? {
        var candidates = [focused]
        if let children: [AXUIElement] = copy(focused, kAXChildrenAttribute) {
            candidates += children.prefix(Self.childLimit)
        }
        for element in candidates where !aborted {
            switch selection(of: element) {
            case .text(let text): return (text, element)
            case .empty: return nil
            case .none: continue
            }
        }
        var current = focused
        for _ in 0..<Self.ancestorLimit where !aborted {
            guard let parent: AXUIElement = copy(current, kAXParentAttribute) else { break }
            let role: String? = copy(parent, kAXRoleAttribute)
            if role == kAXApplicationRole { break }
            switch selection(of: parent) {
            case .text(let text): return (text, parent)
            case .empty: return nil
            case .none: current = parent
            }
            if role == kAXWindowRole { break }
        }
        return nil
    }

    /// 在窗口里有限地广度优先搜索网页区域，返回第一个有文档选区的。没有选区的网页区域也要往里找：
    /// VS Code 的扩展面板（如 Claude 对话框）是嵌在工作台网页里的另一个网页（实测在第 16 层）。
    mutating func searchWebAreas(in window: AXUIElement) -> (String, AXUIElement)? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < Self.webAreaSearchLimit, !aborted {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role: String? = copy(element, kAXRoleAttribute)
            if role == "AXWebArea", case .text(let text) = selection(of: element) { return (text, element) }
            guard depth < Self.webAreaSearchDepth,
                  let children: [AXUIElement] = copy(element, kAXChildrenAttribute)
            else { continue }
            queue += children.map { ($0, depth + 1) }
        }
        return nil
    }

    mutating func isWindow(_ element: AXUIElement) -> Bool {
        let role: String? = copy(element, kAXRoleAttribute)
        return role == kAXWindowRole
    }

    /// 单个控件的选区：AXSelectedText → Web Text Marker → AXSelectedTextRange + AXStringForRange
    /// → AXValue 按区间截取。
    mutating func selection(of element: AXUIElement) -> ElementSelection {
        if let text: String = copy(element, kAXSelectedTextAttribute), !text.isEmpty {
            return AccessibilityReader.hasContent(text) ? .text(text) : .none
        }
        if aborted { return .none }

        var selectedRange: (value: AXValue, range: CFRange)?
        var emptyTextControlRange = false
        if let rangeValue: AXValue = copy(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0 {
                if range.length == 0, advertisesEmptyTextControlRange(of: element, at: range.location) {
                    emptyTextControlRange = true
                } else if range.length > 0 {
                    selectedRange = (rangeValue, range)
                }
            }
        }
        if aborted { return .none }

        // WebKit / Chromium 用不透明的 text marker 区间表示网页里的选区。先于 AXStringForRange：
        // Chromium 的 AXStringForRange 会丢掉 U+FFFC 占位符，区间与文字对不上。
        if let marker: CFTypeRef = copy(element, "AXSelectedTextMarkerRange"),
           let text: String = copy(element, "AXStringForTextMarkerRange", parameter: marker), !text.isEmpty {
            guard AccessibilityReader.hasContent(text) else { return .none }
            // 选区起点在密码框里：不读（即使读到的只是掩码，也会暴露长度）。
            if markerStartsInSecureField(marker, of: element) {
                touchedSecureField = true
                return .empty
            }
            // 空的文本框里有 marker 文字：可能是网页其它地方的 DOM 选区（键盘焦点留在隐藏的 textarea 上）。
            // 两端都落在这个控件里才说明它确实是空的。
            if emptyTextControlRange, markers(marker, stayWithin: element) { return .empty }
            return .text(text)
        }
        if aborted { return .none }

        if let (rangeValue, range) = selectedRange {
            if let text: String = copy(element, kAXStringForRangeParameterizedAttribute, parameter: rangeValue),
               !text.isEmpty {
                return AccessibilityReader.hasContent(text) ? .text(text) : .none
            }
            if aborted { return .none }
            if let value: String = copy(element, kAXValueAttribute),
               let slice = Self.slice(value, range), !slice.isEmpty {
                return AccessibilityReader.hasContent(slice) ? .text(slice) : .none
            }
        }
        return .none
    }

    /// 按 UTF-16 区间截取（AX 的区间以 UTF-16 码元计）。越界时返回 nil。
    static func slice(_ value: String, _ range: CFRange) -> String? {
        let string = value as NSString
        guard range.location >= 0, range.length >= 0, range.length <= string.length,
              range.location <= string.length - range.length
        else { return nil }
        return string.substring(with: NSRange(location: range.location, length: range.length))
    }

    /// 原生文本角色、声明了选区区间、空区间位置合法：这是一个真的"什么都没选"的文本框。
    private mutating func advertisesEmptyTextControlRange(of element: AXUIElement, at location: Int) -> Bool {
        guard let role: String = copy(element, kAXRoleAttribute), textRoles.contains(role),
              let names = attributeNames(element), names.contains(kAXSelectedTextRangeAttribute)
        else { return false }
        if let count: Int = copy(element, kAXNumberOfCharactersAttribute), count >= 0 {
            return location <= count
        }
        return true
    }

    /// marker 区间的两端是否都在 `container` 之内（而不是网页里别的地方）。
    private mutating func markers(_ marker: CFTypeRef, stayWithin container: AXUIElement) -> Bool {
        guard CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID() else { return false }
        let range = unsafeDowncast(marker, to: AXTextMarkerRange.self)
        for end in [AXTextMarkerRangeCopyStartMarker(range), AXTextMarkerRangeCopyEndMarker(range)] {
            guard let node: AXUIElement = copy(container, "AXUIElementForTextMarker", parameter: end),
                  isWithin(node, container)
            else { return false }
        }
        return true
    }

    private mutating func markerStartsInSecureField(_ marker: CFTypeRef, of element: AXUIElement) -> Bool {
        guard CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID() else { return false }
        let start = AXTextMarkerRangeCopyStartMarker(unsafeDowncast(marker, to: AXTextMarkerRange.self))
        guard var node: AXUIElement = copy(element, "AXUIElementForTextMarker", parameter: start) else { return false }
        for _ in 0..<3 {
            if isSecure(node) { return true }
            guard let parent: AXUIElement = copy(node, kAXParentAttribute) else { return false }
            node = parent
        }
        return false
    }

    private mutating func isWithin(_ node: AXUIElement, _ container: AXUIElement) -> Bool {
        var current = node
        for _ in 0..<32 where !aborted {
            if CFEqual(current, container) { return true }
            let role: String? = copy(current, kAXRoleAttribute)
            if role == "AXWebArea" || role == kAXWindowRole || role == kAXApplicationRole { return false }
            guard let parent: AXUIElement = copy(current, kAXParentAttribute) else { return false }
            current = parent
        }
        return false
    }

    mutating func isSecure(_ element: AXUIElement) -> Bool {
        let subrole: String? = copy(element, kAXSubroleAttribute)
        return subrole == kAXSecureTextFieldSubrole
    }

    /// 原生文本控件：文本角色、声明了选区区间、没有网页内容的属性。
    mutating func isNativeText(_ element: AXUIElement) -> Bool {
        guard let role: String = copy(element, kAXRoleAttribute), textRoles.contains(role),
              let names = attributeNames(element)
        else { return false }
        return names.contains(kAXSelectedTextRangeAttribute) && names.isDisjoint(with: webAttributes)
    }

    /// 焦点是原生文本控件，且选区为空。自定义编辑器（WPS 等）在选中文字时也可能回答一个
    /// 未声明的空区间，那仍然算"看不出"。
    mutating func isEmptyNativeText(_ element: AXUIElement) -> Bool {
        guard isNativeText(element), let range = selectedRange(of: element) else { return false }
        return range.length == 0
    }

    mutating func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value: AXValue = copy(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    private mutating func attributeNames(_ element: AXUIElement) -> Set<String>? {
        guard ContinuousClock.now < deadline else { aborted = true; return nil }
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(element, &names)
        if error == .cannotComplete { aborted = true }
        guard error == .success, let names = names as? [String] else { return nil }
        return Set(names)
    }

    mutating func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        guard !aborted, ContinuousClock.now < deadline else { aborted = true; return nil }
        AXUIElementSetMessagingTimeout(element, AccessibilityReader.messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return settle(error, value)
    }

    mutating func copy<T>(_ element: AXUIElement, _ attribute: String, parameter: CFTypeRef) -> T? {
        guard !aborted, ContinuousClock.now < deadline else { aborted = true; return nil }
        AXUIElementSetMessagingTimeout(element, AccessibilityReader.messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
        return settle(error, value)
    }

    private mutating func settle<T>(_ error: AXError, _ value: CFTypeRef?) -> T? {
        if error == .cannotComplete { aborted = true }
        guard error == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (unsafeDowncast(value, to: AXUIElement.self) as! T)
        }
        if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return (unsafeDowncast(value, to: AXValue.self) as! T)
        }
        return value as? T
    }
}

// MARK: - Web engines

/// 应用用的网页引擎，按应用包里带的框架判断（不只靠 bundle id 名单），结果按应用路径缓存。
enum WebEngine: Equatable, Sendable {
    case chromiumBrowser
    case electron
    case other

    /// 已知的 Chromium 浏览器；没列出的、带 Chromium 框架又不是 Electron 的应用也按浏览器处理。
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "company.thebrowser.Browser", "company.thebrowser.dia",
    ]

    private static let cache = OSAllocatedUnfairLock(initialState: [String: WebEngine]())

    static func of(pid: pid_t, bundleId: String?) -> WebEngine {
        if let bundleId, browsers.contains(bundleId) { return .chromiumBrowser }
        guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return .other }
        let key = bundleURL.path
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks").path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks)) ?? []
        let engine = classify(frameworks: names)
        cache.withLock { $0[key] = engine }
        return engine
    }

    static func classify(frameworks names: [String]) -> WebEngine {
        let lowered = names.map { $0.lowercased() }
        if lowered.contains(where: { $0.hasPrefix("electron framework") }) { return .electron }
        // "Chromium Embedded Framework"（CEF）也含 chromium。
        if lowered.contains(where: { $0.contains("chromium") || $0.contains("chrome framework") }) {
            return .chromiumBrowser
        }
        return .other
    }
}

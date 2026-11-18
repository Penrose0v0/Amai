import AmaiCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// 辅助功能读不到选区时，经菜单栏"拷贝"读取选中文字。只在用户按聊天快捷键打开面板之前调用一次。
public protocol SelectionCopying: Sendable {
    /// 在前台应用 `pid` 里执行一次菜单"拷贝"，返回复制到的纯文本，并把剪贴板恢复原样。
    /// 菜单项不可用（没有选区的证据）、不再是前台、安全输入、Amai 自己的窗口有键盘焦点、剪贴板正被占用，
    /// 或者没有复制到文字时返回 nil。不发送任何按键。
    func copySelection(from pid: pid_t) async -> String?
}

/// 复制回退的规则（与系统交互无关的部分，便于单元测试）。参考 AtD 的 CopyFallback。
public enum CopyFallback {
    /// 应用把复制内容放上剪贴板的时限。
    static let copyLimit: Duration = .milliseconds(300)
    /// 超过 `copyLimit` 才到的复制继续观察这么久，到了就恢复用户的剪贴板（但不再算作选区）。
    static let lateCopyLimit: Duration = .seconds(1)

    /// 只在辅助功能读不到选区（`unknown` / `emptyField`）时复制；Amai 自己的窗口有键盘焦点、
    /// 或安全输入（有密码框拿着键盘）时不复制。
    static func applies(read: SelectionRead, amaiHasKeyboard: Bool, secureInput: Bool) -> Bool {
        switch read {
        case .unknown, .emptyField: return mayCopy(amaiHasKeyboard: amaiHasKeyboard, secureInput: secureInput)
        case .text, .none: return false
        }
    }

    static func mayCopy(amaiHasKeyboard: Bool, secureInput: Bool) -> Bool {
        !amaiHasKeyboard && !secureInput
    }

    /// 复制留在剪贴板上的选区：只在剪贴板确实变了之后读（没变就是用户自己的内容，绝不当作选区）；
    /// 复制的是文件（Finder 也会放一份文件名字符串）或没有可读文字时为 nil。
    static func copiedText(changed: Bool, string: String?, hasFiles: Bool) -> String? {
        guard changed, !hasFiles, let string, AccessibilityReader.hasContent(string) else { return nil }
        return string
    }
}

/// 剪贴板事务的互斥：同一时间只允许一次复制读取，避免两次读取交错时恢复出错的"原剪贴板"。
@MainActor
enum ClipboardLock {
    private static var held = false

    static func acquire() -> Bool {
        guard !held else { return false }
        held = true
        return true
    }

    static func release() { held = false }
}

public struct SystemSelectionCopier: SelectionCopying {
    public init() {}

    public func copySelection(from pid: pid_t) async -> String? {
        await Self.copy(from: pid)
    }

    private static let pollInterval: Duration = .milliseconds(10)
    /// 只记录走到了哪一步（与原因），不记录任何复制到的内容。
    private static let log = AmaiLog.logger("perception.selection")

    @MainActor
    private static func copy(from pid: pid_t) async -> String? {
        guard allowed(pid) else { log.info("copy skipped: \(denial(pid), privacy: .public)"); return nil }
        guard ClipboardLock.acquire() else { log.info("copy skipped: clipboard busy"); return nil }
        var lockHandedOff = false
        defer { if !lockHandedOff { ClipboardLock.release() } }

        // 菜单栏里的"拷贝"（按快捷键 ⌘C 识别，与界面语言无关）可用，是"有选区"的证据；
        // 经辅助功能按下它，不发送键盘事件。
        let command = await BlockingCall.value(within: .milliseconds(300), fallback: nil) {
            EditMenu.copyCommand(pid: pid)
        }
        guard let command else { log.info("copy skipped: no enabled Copy menu item"); return nil }
        guard allowed(pid) else { log.info("copy skipped after menu lookup: \(denial(pid), privacy: .public)"); return nil }

        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(of: pasteboard)
        let before = pasteboard.changeCount
        guard await BlockingCall.value(within: .milliseconds(300), fallback: true, { command.perform() }) else {
            log.info("copy skipped: Copy menu item did not respond")
            return nil
        }

        guard await landed(pasteboard, since: before, within: CopyFallback.copyLimit) else {
            // 复制没有及时到：之后才到的话照样恢复用户的剪贴板，在那之前一直占着锁。
            lockHandedOff = true
            log.info("copy did not land")
            Task { @MainActor in
                if await changed(pasteboard, since: before, within: CopyFallback.lateCopyLimit) {
                    saved.restore(to: pasteboard)
                }
                ClipboardLock.release()
            }
            return nil
        }
        let text = CopyFallback.copiedText(
            changed: pasteboard.changeCount != before,
            string: pasteboard.string(forType: .string),
            hasFiles: pasteboard.types?.contains(.fileURL) ?? false
        )
        saved.restore(to: pasteboard)
        log.info("copy landed: text=\(text != nil, privacy: .public), length=\(text?.count ?? 0, privacy: .public)")
        return text
    }

    @MainActor
    private static func denial(_ pid: pid_t) -> String {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return "target not frontmost" }
        if NSApp?.keyWindow != nil { return "Amai window has keyboard" }
        if IsSecureEventInputEnabled() { return "secure input" }
        return "other"
    }

    /// 菜单命令作用于前台应用：它必须仍是读取的那个应用，Amai 自己的窗口不能有键盘焦点，也不能在输入密码。
    @MainActor
    private static func allowed(_ pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              pid != ProcessInfo.processInfo.processIdentifier
        else { return false }
        return CopyFallback.mayCopy(amaiHasKeyboard: NSApp?.keyWindow != nil, secureInput: IsSecureEventInputEnabled())
    }

    /// 剪贴板变了并且有字符串（有的应用先清空再写），或者变了但到时限仍没有字符串（复制了非文本）。
    @MainActor
    private static func landed(_ pasteboard: NSPasteboard, since before: Int, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while pasteboard.changeCount == before || pasteboard.string(forType: .string) == nil {
            guard ContinuousClock.now < deadline else { return pasteboard.changeCount != before }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }

    @MainActor
    private static func changed(_ pasteboard: NSPasteboard, since before: Int, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while pasteboard.changeCount == before {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }
}

// MARK: - Edit menu

/// 菜单栏里的标准"拷贝"命令，按快捷键（⌘C，无其它修饰键）而不是应用名或本地化标题查找。
struct EditMenu {
    struct Command: @unchecked Sendable {
        fileprivate let item: AXUIElement

        /// 超时（`cannotComplete`）也可能已经执行了，算作已执行，避免再发一次 ⌘C。
        func perform() -> Bool {
            let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
            return result == .success || result == .cannotComplete
        }
    }

    private static let searchLimit: Duration = .milliseconds(250)

    /// 可用（enabled）且可按下的"拷贝"菜单项；找不到、有歧义或不可用时为 nil。阻塞调用。
    static func copyCommand(pid: pid_t) -> Command? {
        let deadline = ContinuousClock.now + searchLimit
        let app = AccessibilityReader.application(pid)
        guard let bar = attribute(app, kAXMenuBarAttribute, deadline), CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return nil }
        var found: AXUIElement?
        // 跳过苹果菜单；只看各菜单的直接项，不展开子菜单（最近文档、服务等）。
        for heading in children(unsafeDowncast(bar, to: AXUIElement.self), deadline).dropFirst() {
            for menu in children(heading, deadline) {
                for item in children(menu, deadline) {
                    guard ContinuousClock.now < deadline else { return nil }
                    AXUIElementSetMessagingTimeout(item, AccessibilityReader.messagingTimeout)
                    var values: CFArray?
                    let names = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute] as CFArray
                    guard AXUIElementCopyMultipleAttributeValues(item, names, AXCopyMultipleAttributeOptions(), &values)
                            == .success,
                          let values = values as? [Any], values.count == 2,
                          (values[0] as? String)?.lowercased() == "c", values[1] as? Int == 0
                    else { continue }
                    // 两个菜单项都用 ⌘C 时不算数，不随便挑第一个。
                    guard found == nil else { return nil }
                    found = item
                }
            }
        }
        guard let found, attribute(found, kAXEnabledAttribute, deadline) as? Bool == true else { return nil }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(found, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true
        else { return nil }
        return Command(item: found)
    }

    private static func children(_ element: AXUIElement, _ deadline: ContinuousClock.Instant) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute, deadline) as? [AXUIElement] ?? []
    }

    private static func attribute(
        _ element: AXUIElement, _ name: String, _ deadline: ContinuousClock.Instant
    ) -> CFTypeRef? {
        guard ContinuousClock.now < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, AccessibilityReader.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

// MARK: - Pasteboard snapshot

/// 剪贴板上每一项、每种类型数据的副本（原对象属于剪贴板，`clearContents` 后就没了）。
/// 只在内存里保留到恢复为止，不写日志、不落盘。
struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    init(of pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// 用快照替换剪贴板内容。每个快照只能恢复一次（剪贴板项只能写入一次）。
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

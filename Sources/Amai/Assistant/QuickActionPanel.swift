import AmaiAssistant
import AmaiPerception
import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
// 只按需导入：AmaiCore 的 `Observation` 类型会与 @Observable 宏依赖的 Observation 模块同名冲突。
import enum AmaiCore.ChatEvent
import struct AmaiCore.FocusSnapshot

/// 快速操作面板的状态：读到的选区、正在运行的操作、结果，以及复制 / 替换 / 转给对话。
/// 推理直接调用 Agent 所用的同一个 `ChatModel`（一次性请求），不经过 Agent 循环。
@MainActor
@Observable
final class QuickActionModel {
    let focus: FocusSnapshot
    private(set) var running: QuickAction?
    private(set) var finished: QuickAction?
    private(set) var result = ""
    private(set) var notice: String?
    private(set) var error: String?

    @ObservationIgnored private unowned let assistant: AssistantController
    @ObservationIgnored private var task: Task<Void, Never>?

    init(focus: FocusSnapshot, assistant: AssistantController) {
        self.focus = focus
        self.assistant = assistant
    }

    var selection: String { focus.selectedText ?? "" }
    var hasSelection: Bool { !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var accessibilityGranted: Bool { focus.accessibilityGranted }
    var isReady: Bool { assistant.isReady }
    var setupMessage: String? { assistant.setupMessage }
    var sendsDataOffDevice: Bool { assistant.sendsDataOffDevice }
    var modelLabel: String { assistant.modelLabel }
    /// 只有产出"可替换文本"的操作完成后才提供替换。
    var canReplace: Bool { finished?.producesReplacement == true && !result.isEmpty && running == nil }

    func run(_ action: QuickAction) {
        guard let model = assistant.chatModel else {
            error = assistant.setupMessage ?? String(localized: "还没有选择 Agent 模型。请在设置的「助手」中选择。")
            return
        }
        task?.cancel()
        result = ""
        notice = nil
        error = nil
        finished = nil
        do {
            let request = try QuickActions.request(action, text: selection, language: assistant.languageName)
            running = action
            task = Task { [weak self] in
                do {
                    for try await event in model.stream(request) {
                        guard let self, !Task.isCancelled else { return }
                        if case .text(let delta) = event { self.result += delta }
                    }
                    guard let self, !Task.isCancelled else { return }
                    self.result = self.result.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.finished = action
                } catch is CancellationError {
                } catch {
                    self?.error = ChatViewModel.describe(error)
                }
                self?.running = nil
            }
        } catch QuickActionError.selectionTooLong(let limit) {
            error = String(localized: "选中的文字超过 \(limit) 个字符，请缩小选区。")
        } catch {
            self.error = String(localized: "没有可处理的文字。")
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = nil
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        notice = String(localized: "已复制")
    }

    /// 用结果替换原应用里的选区。只在用户点击"替换"时执行：
    /// 先经辅助功能直接写入（会确认选区没变）；控件不支持时改为粘贴；都不行就只复制。
    func replace() {
        guard canReplace, let live = assistant.live else { return }
        let original = selection
        let text = result
        Task { [weak self] in
            let outcome = await live.replaceSelection(expecting: original, with: text)
            guard let self else { return }
            switch outcome {
            case .replaced:
                self.notice = String(localized: "已替换")
                try? await Task.sleep(for: .milliseconds(600))
                self.assistant.closeQuickActions()
            case .selectionChanged:
                self.copy()
                self.notice = String(localized: "选区已经变化，没有替换。结果已复制到剪贴板。")
            case .notTrusted:
                self.copy()
                self.notice = String(localized: "没有辅助功能权限，无法替换。结果已复制到剪贴板。")
            case .notSupported:
                if let pid = self.focus.pid, await TextPaster.paste(text, intoApplication: pid) {
                    self.notice = String(localized: "这个应用不支持直接替换，已改为粘贴到原处。")
                } else {
                    self.copy()
                    self.notice = String(localized: "这个应用不支持替换。结果已复制到剪贴板。")
                }
            }
        }
    }

    func askAmai() {
        stop()
        assistant.askAmai(about: focus)
    }

    func openSettings() {
        assistant.closeQuickActions()
        assistant.openSettings()
    }
}

/// 粘贴替换：把文字放进剪贴板，回到原应用按一次 ⌘V，随后恢复剪贴板原来的文字。
/// 只在用户点击"替换"、且辅助功能直接写入不可用时调用。无法确认原应用是否真的接受了粘贴。
@MainActor
enum TextPaster {
    static func paste(_ text: String, intoApplication pid: pid_t) async -> Bool {
        // 合成按键需要辅助功能权限；正在输入密码时不发送任何按键。
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
        else { return false }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let expectedChange = pasteboard.changeCount

        app.activate()
        try? await Task.sleep(for: .milliseconds(180))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        // 等原应用读完剪贴板再恢复；期间用户自己复制了别的内容就不动它。
        try? await Task.sleep(for: .milliseconds(700))
        if pasteboard.changeCount == expectedChange {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
        return true
    }
}

// MARK: - Panel

private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 快速操作的轻量浮动面板：不激活 Amai，原应用保持在前台、选区不丢。出现在鼠标附近，
/// 按 ESC 或点到别处时关闭。
@MainActor
final class QuickActionPanelController {
    private static let size = NSSize(width: 420, height: 330)
    private var panel: NSPanel?
    private var model: QuickActionModel?
    private var resignObserver: (any NSObjectProtocol)?

    func show(_ model: QuickActionModel) {
        close()
        self.model = model
        let panel = QuickPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        let host = NSHostingView(rootView: QuickActionView(model: model, onClose: { [weak self] in self?.close() }))
        host.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
        panel.setFrame(Self.frame(near: NSEvent.mouseLocation), display: false)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 焦点去了 Amai 自己的其他窗口（设置、聊天面板）或别的应用：都关闭。
                self?.close()
            }
        }
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        model?.stop()
        model = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// 放在鼠标右下方，并保证整个面板在所在屏幕的可见范围内。
    private static func frame(near point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 12)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        return NSRect(origin: origin, size: size)
    }
}

private struct QuickActionView: View {
    let model: QuickActionModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !model.accessibilityGranted {
                permissionHint
            } else if !model.hasSelection {
                message(String(localized: "没有读到选中的文字。先在任意应用里选中一段文字，再按快捷键。有些应用不提供选区，可以改用「问 Amai」。"))
            } else {
                selectionPreview
                actionRow
                resultArea
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .background(
            Button("") { onClose() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tint)
            Text("快速操作")
                .font(.system(size: 13, weight: .semibold))
            if let app = model.focus.appName {
                Text(verbatim: "· \(app)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isReady {
                Image(systemName: model.sendsDataOffDevice ? "cloud" : "desktopcomputer")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help(model.sendsDataOffDevice
                          ? String(localized: "云端模型：选中的文字会发送给 \(model.modelLabel)。")
                          : String(localized: "本地模型：内容不离开这台 Mac。"))
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "关闭 (esc)"))
        }
    }

    private var permissionHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            message(String(localized: "读取其他应用里选中的文字需要「辅助功能」权限。Amai 只在你按下快捷键时读取一次，不监听键盘。"))
            Button("授权辅助功能…") {
                AccessibilityReader.requestTrust()
                AccessibilityReader.openSystemSettings()
                onClose()
            }
        }
    }

    private var selectionPreview: some View {
        Text(verbatim: model.selection.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            actionButton(.translate, String(localized: "翻译"), "character.bubble")
            actionButton(.polish, String(localized: "润色"), "wand.and.stars")
            actionButton(.explain, String(localized: "解释"), "questionmark.circle")
            Spacer()
            Button { model.askAmai() } label: {
                Label("问 Amai", systemImage: "bubble.left")
                    .font(.system(size: 12))
            }
            .help(String(localized: "带着这段文字打开对话"))
        }
    }

    private func actionButton(_ action: QuickAction, _ title: String, _ symbol: String) -> some View {
        Button { model.run(action) } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
        }
        .disabled(model.running != nil)
        .buttonStyle(.borderedProminent)
        .tint(model.finished == action || model.running == action ? Color.accentColor : Color.white.opacity(0.16))
    }

    @ViewBuilder
    private var resultArea: some View {
        if let error = model.error {
            message(error, color: .orange)
            if !model.isReady {
                Button("打开设置…") { model.openSettings() }
            }
        } else if model.running != nil || !model.result.isEmpty {
            ScrollView {
                Text(verbatim: model.result.isEmpty ? "•••" : model.result)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let notice = model.notice {
                Text(verbatim: notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if model.running != nil {
                Button("停止") { model.stop() }
            } else if !model.result.isEmpty {
                Button("复制") { model.copy() }
                if model.canReplace {
                    Button("替换原文") { model.replace() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(model.focus.selectionIsEditable
                              ? String(localized: "用结果替换原来选中的文字 (⌘↩)")
                              : String(localized: "原应用没有声明选区可编辑，将尝试粘贴到原处 (⌘↩)"))
                }
            }
        }
        .controlSize(.small)
    }

    private func message(_ text: String, color: Color = .secondary) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

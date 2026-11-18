import AmaiAssistant
import AppKit
import SwiftUI

/// 聊天面板（移植自 Eira 的 ChatView）：顶部标题与上下文提示、消息列表或空状态、输入行。
/// 整个面板是一块玻璃（见 ChatWindowController），顶部和底部用渐变保证文字可读。
/// 与 Eira 的差别：没有浏览器页面读取与 P2P 状态；顶部提示显示感知层实际读到的焦点与所用模型。
struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    var onOpenSource: (MemorySource) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}

    @State private var showHistory = false

    private static let topScrimFraction: CGFloat = 1.5
    private static let bottomScrimFraction: CGFloat = 0.4
    private static let suggestionChipOpacity: Double = 0.2
    private static let scrollFadeHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            header
            if let err = viewModel.errorBanner {
                errorBanner(err)
            }
            content
            InputCardView(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            GeometryReader { geo in
                LinearGradient(colors: [.black.opacity(0.9), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.size.height * Self.topScrimFraction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .allowsHitTesting(false)
        }
        .background(alignment: .bottom) {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    .frame(height: geo.size.height * Self.bottomScrimFraction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
        }
        .chatCardSurface()
        .background(
            // ⌘N：新建对话。
            Button("") { viewModel.newSession() }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .background(
            // ESC：关闭面板。
            Button("") { NSApp.keyWindow?.orderOut(nil) }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                headerButton("clock.arrow.circlepath", help: String(localized: "查看历史对话")) { showHistory.toggle() }
                    .popover(isPresented: $showHistory, arrowEdge: .top) {
                        HistoryPopover(viewModel: viewModel)
                    }
                headerButton("square.and.pencil", help: String(localized: "新建对话 (⌘N)")) { viewModel.newSession() }
                Text(verbatim: "Amai")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    viewModel.isPinned.toggle()
                } label: {
                    Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(viewModel.isPinned ? Color.accentColor : Color.secondary)
                        .rotationEffect(.degrees(viewModel.isPinned ? 0 : 30))
                        .frame(width: 22, height: 22)
                        .background(.quaternary.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .help(viewModel.isPinned
                      ? String(localized: "已固定：窗口保持打开。点击取消固定，失去焦点时自动关闭。")
                      : String(localized: "失去焦点时自动关闭。点击固定（保持打开直到按 ESC 或关闭）。"))
                headerButton("xmark", help: String(localized: "关闭 (esc)")) { NSApp.keyWindow?.orderOut(nil) }
            }
            contextLine
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.quaternary.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 一行提示：正在看哪个应用 / 窗口、是否有选区，以及所用的模型（云端模型明确标出）。
    @ViewBuilder
    private var contextLine: some View {
        HStack(spacing: 6) {
            if let focus = viewModel.focus, let app = focus.appName {
                Image(systemName: "eye")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(verbatim: Self.watching(app: app, title: focus.windowTitle, hasSelection: !(focus.selectedText ?? "").isEmpty))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if viewModel.lastContext?.blockedReason != nil {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                Text("当前应用在隐私排除范围内，未读取屏幕")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if viewModel.isConfigured {
                HStack(spacing: 3) {
                    Image(systemName: viewModel.sendsDataOffDevice ? "cloud" : "desktopcomputer")
                        .font(.system(size: 9))
                    Text(verbatim: viewModel.modelLabel)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .help(viewModel.sendsDataOffDevice
                      ? String(localized: "云端模型：对话内容、屏幕上下文和检索到的记忆会发送给该服务。")
                      : String(localized: "本地模型：内容不离开这台 Mac。"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func watching(app: String, title: String?, hasSelection: Bool) -> String {
        var text = if let title, !title.isEmpty {
            String(localized: "正在看 \(app) · \(title)")
        } else {
            String(localized: "正在看 \(app)")
        }
        if hasSelection { text += String(localized: " · 已选中文字") }
        return text
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(verbatim: message)
                .font(.system(size: 11))
                .lineLimit(3)
            Spacer()
            Button {
                viewModel.errorBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !viewModel.isConfigured {
            setupState
        } else if viewModel.messages.isEmpty {
            emptyState
        } else {
            messageList
        }
    }

    /// 还没有选 Agent 模型（或所选模型不可用）时的说明。
    private var setupState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 24)
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tint.opacity(0.85))
            Text("先为助手选择一个模型")
                .font(.system(size: 16, weight: .medium))
            // 只在有具体问题时说明（模型没下载、云端未确认等）。
            if let problem = viewModel.setupMessage {
                Text(verbatim: problem)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button("打开设置…") { onOpenSettings() }
                .controlSize(.large)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tint.opacity(0.85))
                .padding(.bottom, 18)
            Text("有什么想问的？")
                .font(.system(size: 16, weight: .medium))
                .padding(.bottom, 6)
            Text("选一个开始，或直接打字提问。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 22)
            VStack(spacing: 8) {
                ForEach(suggestions(), id: \.prompt) { suggestion in
                    suggestionChip(suggestion)
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestionChip(_ suggestion: Suggestion) -> some View {
        Button {
            viewModel.input = suggestion.prompt
            viewModel.send(includeMemory: suggestion.usesMemory)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: suggestion.label)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(Self.suggestionChipOpacity), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        let isLast = message.id == viewModel.messages.last?.id
                        MessageBubble(
                            message: message, onOpenSource: onOpenSource,
                            showsActions: !(isLast && viewModel.isStreaming),
                            onRegenerate: isLast && viewModel.canRegenerate ? { viewModel.regenerate() } : nil
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollContentBackground(.hidden)
            .mask(scrollFadeMask)
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.scrollFadeHeight)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.scrollFadeHeight)
        }
    }

    // MARK: - Suggestions

    private struct Suggestion {
        let icon: String
        let label: String
        let prompt: String
        /// 翻译、润色只处理选中的文字，不检索记忆。
        var usesMemory = true
    }

    /// 有选区时建议针对选区，否则建议针对屏幕与记忆。
    private func suggestions() -> [Suggestion] {
        if !(viewModel.focus?.selectedText ?? "").isEmpty {
            return [
                Suggestion(icon: "character.bubble", label: String(localized: "翻译所选内容"), prompt: String(localized: "请把我选中的内容翻译成中文。"), usesMemory: false),
                Suggestion(icon: "wand.and.stars", label: String(localized: "润色所选内容"), prompt: String(localized: "请润色我选中的文字：修正语法、错别字和不通顺的地方，保持原来的语言、意思和语气，不添加新内容。只输出润色后的文字。"), usesMemory: false),
                Suggestion(icon: "questionmark.circle", label: String(localized: "解释所选内容"), prompt: String(localized: "请解释我选中的内容。")),
                Suggestion(icon: "text.alignleft", label: String(localized: "概括所选内容"), prompt: String(localized: "请帮我概括我选中的内容。")),
            ]
        }
        return [
            Suggestion(icon: "text.alignleft", label: String(localized: "概括屏幕上的内容"), prompt: String(localized: "请帮我概括屏幕上正在显示的内容。")),
            Suggestion(icon: "clock", label: String(localized: "我今天做了什么"), prompt: String(localized: "我今天都做了什么？")),
            Suggestion(icon: "list.bullet", label: String(localized: "我最近在忙哪些项目"), prompt: String(localized: "我最近在忙哪些项目？")),
        ]
    }
}

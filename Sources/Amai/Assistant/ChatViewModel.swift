import AmaiAssistant
import AmaiCloud
// 只按需导入：AmaiCore 的 `Observation` 类型会与 @Observable 宏依赖的 Observation 模块同名冲突。
import struct AmaiCore.FocusSnapshot
import AmaiExtraction
import AppKit
import Foundation
import Observation

/// 聊天面板里的一条消息。
struct ChatItem: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    var content: String
    var sources: [MemorySource] = []
    /// 回答生成过程中的状态说明（"正在检索记忆…"）。
    var activity: String?
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, content: String, sources: [MemorySource] = [], createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.sources = sources
        self.createdAt = createdAt
    }
}

/// 聊天面板的状态（移植自 Eira 的 ChatViewModel）：消息列表、输入、流式生成、会话的新建 / 切换 / 删除。
/// 生成由 `AssistantSession` 完成，这里只把事件流变成界面状态，并把用户看到的内容存进会话记录。
@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatItem] = []
    var input = ""
    var isStreaming = false
    var errorBanner: String?
    /// 随下一条消息带上当前窗口的截图。发送后自动关闭。
    var attachScreen = false
    /// 面板打开时读到的焦点（应用、窗口、是否有选区），用于顶部的"正在看…"提示。
    private(set) var focus: FocusSnapshot?
    /// 上一轮实际带给模型的上下文摘要。
    private(set) var lastContext: TurnContextSummary?

    /// 为 true 时面板失去焦点不自动关闭。跨启动保存。
    var isPinned: Bool = UserDefaults.standard.bool(forKey: ChatViewModel.pinnedKey) {
        didSet { UserDefaults.standard.set(isPinned, forKey: ChatViewModel.pinnedKey) }
    }
    private static let pinnedKey = "Amai.ChatWindow.Pinned"

    private(set) var currentSessionId = UUID()
    private unowned let assistant: AssistantController
    private var streamingTask: Task<Void, Never>?
    /// 打开面板时交接过来的焦点（经复制读到的选区）：下一条消息用它而不是重新读取。
    private var handedOverFocus: FocusSnapshot?
    /// 最近一轮的交接焦点与是否检索记忆。重新生成最后一条回答时沿用：
    /// 否则经复制读到的选区会丢，翻译也会重新挂上记忆来源。
    private var lastTurnFocus: FocusSnapshot?
    private var lastTurnIncludesMemory = true

    init(assistant: AssistantController) {
        self.assistant = assistant
    }

    var isConfigured: Bool { assistant.isReady }
    var modelLabel: String { assistant.modelLabel }
    var sendsDataOffDevice: Bool { assistant.sendsDataOffDevice }
    var setupMessage: String? { assistant.setupMessage }

    // MARK: - Context preview

    /// 面板出现时调用：立刻开始为下一个问题做准备——读焦点、对当前窗口做 OCR、预热模型并预填充上下文。
    /// 用户还在打字的时候这些就在后台进行；顶部提示在焦点读到后马上更新，不等 OCR。
    func onPopoverOpened() {
        // 打开面板时交接过来选区的话，`handOver` 已经带着它开始准备了。
        guard !isStreaming, handedOverFocus == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            if let live = self.assistant.live { self.focus = await live.focus() }
            _ = await self.assistant.prepareSession()
        }
    }

    /// 面板开着时定期调用：用户切换了应用、窗口或选区才重新准备（读焦点很便宜，OCR 与预填充不便宜）。
    func refreshContextIfChanged() {
        guard !isStreaming, handedOverFocus == nil, let live = assistant.live else { return }
        Task { [weak self] in
            let snapshot = await live.focus()
            guard let self, !self.isStreaming else { return }
            let previous = self.focus
            self.focus = snapshot
            guard snapshot.appName != previous?.appName || snapshot.windowTitle != previous?.windowTitle
                || (snapshot.selectedText ?? "") != (previous?.selectedText ?? "")
            else { return }
            _ = await self.assistant.prepareSession()
        }
    }

    /// 丢掉上一次交接过来、但没有用于提问的选区（再次打开聊天框时，它可能早已不是当前选区）。
    func discardHandOver() {
        handedOverFocus = nil
    }

    /// 打开聊天面板时读到的、只能经复制得到的选区：带着它开始提问。
    func handOver(focus: FocusSnapshot) {
        handedOverFocus = focus
        self.focus = focus
        Task { [weak self] in _ = await self?.assistant.prepareSession(focus: focus) }
    }

    // MARK: - Sessions

    func newSession() {
        cancelStreaming()
        messages.removeAll()
        currentSessionId = UUID()
        input = ""
        errorBanner = nil
        attachScreen = false
        lastContext = nil
        handedOverFocus = nil
        lastTurnFocus = nil
        lastTurnIncludesMemory = true
        // 先清掉旧对话的状态，再为新对话做准备（顺序反了的话，刚准备好的上下文会被清掉）。
        Task { [weak self] in
            await self?.assistant.session?.reset()
            self?.onPopoverOpened()
        }
    }

    func loadSession(id: UUID) {
        cancelStreaming()
        errorBanner = nil
        input = ""
        lastContext = nil
        handedOverFocus = nil
        lastTurnFocus = nil
        lastTurnIncludesMemory = true
        currentSessionId = id
        let saved = (try? assistant.store?.messages(in: id)) ?? []
        messages = saved.map { ChatItem(id: $0.id, role: $0.role == .user ? .user : .assistant, content: $0.text, sources: $0.sources, createdAt: $0.createdAt) }
        Task { [weak self] in
            await self?.assistant.session?.restore(saved)
            self?.onPopoverOpened()
        }
    }

    func deleteSession(id: UUID) {
        try? assistant.store?.deleteSession(id)
        if id == currentSessionId { newSession() }
    }

    func deleteAllSessions() {
        try? assistant.store?.deleteAll()
        newSession()
    }

    func recentSessions() -> [SessionSummary] {
        (try? assistant.store?.recentSessions(limit: 50)) ?? []
    }

    /// Agent 被重新配置（换模型、改可读分区）：当前对话接到新的会话对象上。
    func sessionDidChange() {
        let history = Self.history(messages[...])
        cancelStreaming()
        Task { await assistant.session?.restore(history) }
    }

    // MARK: - Sending

    /// - Parameter includeMemory: 翻译、润色这类只处理选中文字的建议传 false，不检索记忆。
    func send(includeMemory: Bool = true) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let session = assistant.session else {
            errorBanner = assistant.setupMessage ?? String(localized: "还没有选择 Agent 模型。请在设置的「助手」中选择。")
            return
        }
        input = ""
        errorBanner = nil

        var options = AssistantSession.TurnOptions()
        options.attachScreen = attachScreen ? .focusedWindow : nil
        options.focus = handedOverFocus
        options.includeMemory = includeMemory
        lastTurnFocus = handedOverFocus
        lastTurnIncludesMemory = includeMemory
        attachScreen = false
        handedOverFocus = nil

        let user = ChatItem(role: .user, content: text)
        messages.append(user)
        try? assistant.store?.save(
            DisplayMessage(id: user.id, role: .user, text: text, createdAt: user.createdAt),
            in: currentSessionId, suggestedTitle: text
        )
        startTurn(text, session: session, options: options, rewindTo: nil)
    }

    /// 最后一条消息是已完成的回答时，可以重新生成。
    var canRegenerate: Bool {
        !isStreaming && messages.last?.role == .assistant
            && messages.dropLast().contains { $0.role == .user }
    }

    /// 撤回最后一条回答，把会话退回到那个问题之前，再问一次同样的问题。
    func regenerate() {
        guard canRegenerate, let session = assistant.session,
              let userIndex = messages.lastIndex(where: { $0.role == .user })
        else { return }
        let old = messages.removeLast()
        try? assistant.store?.deleteMessage(old.id)
        errorBanner = nil
        let text = messages[userIndex].content
        var options = AssistantSession.TurnOptions()
        options.focus = lastTurnFocus
        options.includeMemory = lastTurnIncludesMemory
        startTurn(text, session: session, options: options, rewindTo: Self.history(messages[..<userIndex]))
    }

    private static func history(_ items: ArraySlice<ChatItem>) -> [DisplayMessage] {
        items.filter { $0.role != .system && !$0.content.isEmpty }.map {
            DisplayMessage(id: $0.id, role: $0.role == .user ? .user : .assistant, text: $0.content, sources: $0.sources, createdAt: $0.createdAt)
        }
    }

    /// 生成一轮回答。`rewindTo` 不为 nil 时先把会话恢复到这段历史（重新生成）。
    private func startTurn(
        _ text: String, session: AssistantSession, options: AssistantSession.TurnOptions, rewindTo history: [DisplayMessage]?
    ) {
        // 发送时就记下会话：生成过程中用户新建对话，回答仍写回原来的会话。
        let sessionId = currentSessionId
        let store = assistant.store

        var reply = ChatItem(role: .assistant, content: "")
        reply.activity = String(localized: "正在检索记忆…")
        messages.append(reply)
        let replyId = reply.id
        isStreaming = true

        streamingTask = Task { [weak self] in
            if let history { await session.restore(history) }
            var finished: (text: String, sources: [MemorySource])?
            do {
                for try await event in session.send(text, options: options) {
                    guard let self, !Task.isCancelled else { break }
                    self.apply(event, to: replyId)
                    if case .finished(let text, let sources) = event { finished = (text, sources) }
                }
            } catch is CancellationError {
                // 用户点了停止：保留已显示的部分，不写入记录。
            } catch {
                guard let self else { return }
                self.errorBanner = Self.describe(error)
                if let index = self.messages.firstIndex(where: { $0.id == replyId }), self.messages[index].content.isEmpty {
                    self.messages.remove(at: index)
                }
            }
            guard let self else { return }
            self.isStreaming = false
            if let index = self.messages.firstIndex(where: { $0.id == replyId }) {
                self.messages[index].activity = nil
                if finished != nil, self.messages[index].content.isEmpty {
                    self.messages[index].content = String(localized: "（模型没有给出回答）")
                }
            }
            // 面板还开着的话，用户很可能接着问：为下一轮做准备。
            if finished != nil { _ = Task { await self.assistant.prepareSession() } }
            // 只有完整结束的回答才写入记录。
            if let finished, !finished.text.isEmpty, !Task.isCancelled {
                try? store?.save(
                    DisplayMessage(id: replyId, role: .assistant, text: finished.text, sources: finished.sources),
                    in: sessionId
                )
                try? store?.prune()
            }
        }
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false
        for index in messages.indices { messages[index].activity = nil }
    }

    private func apply(_ event: AssistantEvent, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .context(let summary):
            lastContext = summary
            messages[index].activity = String(localized: "正在整理回答…")
        case .text(let delta):
            messages[index].content += delta
            messages[index].activity = nil
        case .finished(let text, let sources):
            messages[index].content = text
            messages[index].sources = sources
            messages[index].activity = nil
        }
    }

    /// 给用户看的错误说明。不包含请求内容。
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as CloudError:
            return error.description
        case ModelProviderError.modelNotInstalled:
            return String(localized: "本地模型尚未下载，请在设置中下载或改选其他模型。")
        case ModelProviderError.loadFailed:
            return String(localized: "本地模型加载失败。")
        case ModelProviderError.generationFailed:
            return String(localized: "本地模型生成失败，请重试。")
        case AssistantError.busy:
            return String(localized: "上一条消息还在生成中。")
        default:
            return String(localized: "出错了，请重试。")
        }
    }
}

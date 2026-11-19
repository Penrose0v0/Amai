import AmaiAssistant
import AmaiCloud
import AmaiExtraction
import AmaiMemory
import AmaiPerception
import AppKit
import Foundation
import Observation
// 只按需导入：AmaiCore 的 `Observation` 类型会与 @Observable 宏依赖的 Observation 模块同名冲突。
import enum AmaiCore.AmaiLog
import protocol AmaiCore.ChatModel
import struct AmaiCore.FocusSnapshot
import enum AmaiCore.MemoryLanguage

/// 内置助手在 App 里的装配点：按配置创建模型与对话会话，持有聊天面板与全局快捷键。
/// 不含业务逻辑：问答流水线在 AmaiAssistant，屏幕读取在 AmaiPerception，模型在 AmaiInference / AmaiCloud。
@MainActor
@Observable
final class AssistantController {
    struct Environment {
        var live: LiveContextReader?
        var memoryRoot: URL
        var memoryIndex: MemoryIndex?
        /// 记忆语义检索用的向量模型；没有下载时检索只用关键词。
        var embedder: MLXTextEmbedder?
        var keychain: KeychainStore
        var chatGPT: ChatGPTSession
        var claudeWorkdir: URL
        /// 对话记录数据库的位置；nil 时不保存记录。
        var storeURL: URL?
        var language: @MainActor () -> MemoryLanguage
        var openSource: @MainActor (MemorySource) -> Void
        var openSettings: @MainActor () -> Void
    }

    private(set) var configuration: AssistantConfiguration
    private(set) var session: AssistantSession?
    private(set) var chatModel: (any ChatModel)?
    /// 助手不可用时给用户的说明（没选模型、模型没下载、未确认云端使用等）。
    private(set) var setupMessage: String?
    /// 没能注册的快捷键（被其他应用占用）。
    private(set) var hotKeyProblems: [String] = []

    @ObservationIgnored let store: ChatSessionStore?
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private let hotKeys = HotKeyManager()
    @ObservationIgnored private(set) lazy var chat = ChatViewModel(assistant: self)
    @ObservationIgnored private var chatWindow: ChatWindowController?
    @ObservationIgnored private let log = AmaiLog.logger("assistant")
    @ObservationIgnored private var embedding: Task<Void, Never>?
    /// 设为常驻的本地对话模型。换模型时把旧的恢复为空闲卸载。
    @ObservationIgnored private var residentModelTag: String?

    init(configuration: AssistantConfiguration, environment: Environment) {
        self.configuration = configuration
        self.environment = environment
        if let url = environment.storeURL {
            do {
                store = try ChatSessionStore(path: url.path)
            } catch {
                // 存储打不开时助手照常可用，只是不保存对话记录。
                store = nil
                AmaiLog.logger("assistant").error("chat store unavailable: \(String(describing: type(of: error)), privacy: .public)")
            }
        } else {
            store = nil
        }
        rebuild()
    }

    var live: LiveContextReader? { environment.live }
    var isReady: Bool { session != nil }
    var modelLabel: String { configuration.agent?.label ?? "" }
    var sendsDataOffDevice: Bool { chatModel?.sendsDataOffDevice ?? false }

    /// 回答与翻译所用的语言（英文名，写进提示词）。
    var languageName: String {
        switch environment.language() {
        case .zhHans: "Chinese"
        case .en: "English"
        case .ja: "Japanese"
        }
    }

    // MARK: - Configuration

    /// 配置变化后调用（已由调用方保存到 config.json）。
    func apply(_ configuration: AssistantConfiguration) {
        let hotKeysChanged = configuration.chatHotKey != self.configuration.chatHotKey
        self.configuration = configuration
        rebuild()
        chat.sessionDidChange()
        if hotKeysChanged { registerHotKeys() }
    }

    /// 本地模型下载完成等外部状态变化后重新检查可用性。
    func refresh() {
        guard session == nil else { return }
        rebuild()
    }

    private func rebuild() {
        session = nil
        chatModel = nil
        setupMessage = nil
        guard let choice = configuration.agent else { return }
        if configuration.usesCloud, !configuration.cloudAcknowledged {
            setupMessage = String(localized: "所选模型在云端运行。请先在设置的「助手」中确认发送范围。")
            return
        }
        let context = AssistantModelFactory.Context(
            keychain: environment.keychain, chatGPT: environment.chatGPT, claudeWorkdir: environment.claudeWorkdir
        )
        let model: any ChatModel
        switch AssistantModelFactory.make(choice, context: context) {
        case .success(let made):
            model = made
        case .failure(let error):
            setupMessage = error.description
            return
        }
        let memory = MemoryAPI(
            root: environment.memoryRoot, index: environment.memoryIndex, access: configuration.access,
            embedder: environment.embedder
        )
        chatModel = model
        keepResident(choice.source.mode == .local ? choice.localModelTag : nil)
        session = AssistantSession(
            model: model, memory: memory, live: environment.live,
            builder: ContextBuilder(language: languageName)
        )
        log.info("assistant ready: \(model.identifier, privacy: .public), off-device=\(model.sendsDataOffDevice), categories=\(self.configuration.memoryCategories.count)")
    }

    /// 参考 Eira：助手的本地对话模型常驻后台，启动时就在后台预加载，按下快捷键时不必等 5–15 秒的冷加载。
    /// 只有 critical 内存压力（且最近两分钟没有对话）才释放。后台抽取用的模型不受影响，仍然空闲 5 分钟卸载。
    private func keepResident(_ tag: String?) {
        let previous = residentModelTag
        guard tag != previous else { return }
        residentModelTag = tag
        let embedder = environment.embedder
        Task.detached(priority: .utility) {
            if let previous { await LocalModelRuntime.host(for: previous).setIdleUnload(after: 300) }
            await embedder?.setResident(tag != nil)
            guard let tag else { return }
            let host = LocalModelRuntime.host(for: tag)
            await host.setIdleUnload(after: nil)
            await host.warmUp()
            await embedder?.warmUp()
        }
    }

    // MARK: - Prepare

    /// 面板唤出（或用户换了窗口、上一轮结束）时调用：让会话提前读屏幕、预热模型并预填充上下文，
    /// 同时在后台给新增的记忆补算向量。返回读到的上下文摘要。
    func prepareSession(focus: FocusSnapshot? = nil) async -> TurnContextSummary? {
        guard let session else { return nil }
        embedPendingMemory()
        return await session.prepare(focus: focus)
    }

    /// 给还没有向量的记忆块补算向量。后台优先级：与对话抢闸门时让对话先走。同一时间只跑一个。
    private func embedPendingMemory() {
        guard embedding == nil, let index = environment.memoryIndex, let embedder = environment.embedder,
              embedder.isAvailable, !configuration.memoryCategories.isEmpty
        else { return }
        embedding = Task(priority: .utility) { [weak self] in
            _ = try? await index.refresh()
            let count = (try? await index.embedPending(using: embedder)) ?? 0
            if count > 0 { AmaiLog.logger("assistant").info("embedded \(count) memory chunks") }
            self?.embedding = nil
        }
    }

    // MARK: - Hot keys

    func registerHotKeys() {
        var problems: [String] = []
        if !hotKeys.register(id: 1, keyCode: configuration.chatHotKey.keyCode, modifiers: configuration.chatHotKey.modifiers, handler: { [weak self] in self?.toggleChat() }) {
            problems.append(configuration.chatHotKey.title)
        }
        hotKeyProblems = problems
    }

    func unregisterHotKeys() {
        hotKeys.unregisterAll()
    }

    // MARK: - Chat panel

    /// 聊天快捷键。打开面板之前先读一次焦点：只有辅助功能看不到、经菜单复制读到的选区（微信等）
    /// 才交给聊天框保留（面板打开后的定期刷新只用辅助功能，会读不到它）。
    func toggleChat() {
        let controller = chatController()
        guard !controller.isVisible else {
            controller.toggle()
            return
        }
        Task {
            await chat.startNewSessionIfIdle()
            if let live = environment.live {
                let focus = await live.focusForChatOpening()
                if focus.selectionIsCopied, !(focus.selectedText ?? "").isEmpty {
                    chat.handOver(focus: focus)
                } else {
                    chat.discardHandOver()
                }
            }
            controller.toggle()
        }
    }

    func showChat() {
        let controller = chatController()
        if !controller.isVisible { controller.show() }
    }

    private func chatController() -> ChatWindowController {
        if let chatWindow { return chatWindow }
        let controller = ChatWindowController(
            viewModel: chat,
            onOpenSource: { [environment] source in environment.openSource(source) },
            onOpenSettings: { [environment] in environment.openSettings() }
        )
        chatWindow = controller
        return controller
    }

    func openSettings() {
        environment.openSettings()
    }
}

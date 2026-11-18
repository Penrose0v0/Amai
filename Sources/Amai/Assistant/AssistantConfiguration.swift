import AmaiCloud
import AmaiCore
import AmaiExtraction
import AmaiMemory
import Carbon.HIToolbox
import Foundation

/// 一个模型的选择：本地 MLX 模型，或云端的某种来源。
/// 云端部分直接复用记忆整理的配置结构（来源、Provider、模型名），API Key 与登录状态也共用同一份钥匙串条目，
/// 不为助手另建一套账户设置。
struct AssistantModelChoice: Codable, Equatable {
    /// `mode == .local` 时使用 `localModelTag`；其余取值的含义与记忆整理相同。
    var source: ConsolidationModelConfiguration
    var localModelTag: String

    static func local(_ tag: String) -> AssistantModelChoice {
        AssistantModelChoice(source: ConsolidationModelConfiguration(), localModelTag: tag)
    }

    var isCloud: Bool { source.mode.isCloud }

    /// 设置与聊天面板中显示的名称。
    var label: String {
        if source.mode == .local {
            return LocalModelCatalog.option(for: localModelTag)?.displayName ?? localModelTag
        }
        return ConsolidationModelFactory.label(source, localIdentifier: "")
    }

    private enum CodingKeys: String, CodingKey { case source, localModelTag }

    init(source: ConsolidationModelConfiguration, localModelTag: String) {
        self.source = source
        self.localModelTag = localModelTag
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(ConsolidationModelConfiguration.self, forKey: .source) ?? .default
        localModelTag = try c.decodeIfPresent(String.self, forKey: .localModelTag) ?? LocalInferenceBackend.defaultModelTag
    }
}

/// 全局快捷键。
struct HotKeyBinding: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon 修饰键位掩码（cmdKey / shiftKey / optionKey / controlKey）。
    var modifiers: UInt32

    static let chatDefault = HotKeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))
    static let quickActionDefault = HotKeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))

    /// 设置中可选的组合。不提供任意录制：少数几个不与系统冲突的组合足够，且不会被误设成常用按键。
    static let presets: [HotKeyBinding] = [
        HotKeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)),
        HotKeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey)),
        HotKeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
        HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey)),
        HotKeyBinding(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(controlKey | optionKey)),
        HotKeyBinding(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)),
    ]

    var title: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        switch Int(keyCode) {
        case kVK_Space: text += "Space"
        case kVK_ANSI_A: text += "A"
        case kVK_ANSI_E: text += "E"
        case kVK_ANSI_T: text += "T"
        default: text += "#\(keyCode)"
        }
        return text
    }
}

/// `config.json` 的 `assistant` 段。
///
/// - Agent 模型没有默认值：用户在引导或设置里选定之前，助手不可用，也不会加载任何模型；
/// - `memoryCategories` 是助手可读的记忆分区，本地与云端模型用同一份；
/// - `cloudAcknowledged`：用户已确认过"选用云端模型会把对话内容、屏幕上下文和检索到的记忆发给该服务"。
///   确认在选择云端模型时进行一次，之后的每次调用不再询问。
struct AssistantConfiguration: Codable, Equatable {
    var agent: AssistantModelChoice?
    var memoryCategories: [MemoryCategory]
    var cloudAcknowledged: Bool
    var chatHotKey: HotKeyBinding
    var quickActionHotKey: HotKeyBinding

    /// 默认可读分区：综合、工作、目标与每日记录。健康与财务需要用户自己勾选。
    static let defaultCategories: [MemoryCategory] = [.general, .work, .goals, .daily]

    static let `default` = AssistantConfiguration(
        agent: nil, memoryCategories: defaultCategories, cloudAcknowledged: false,
        chatHotKey: .chatDefault, quickActionHotKey: .quickActionDefault
    )

    init(
        agent: AssistantModelChoice?, memoryCategories: [MemoryCategory],
        cloudAcknowledged: Bool, chatHotKey: HotKeyBinding, quickActionHotKey: HotKeyBinding
    ) {
        self.agent = agent
        self.memoryCategories = memoryCategories
        self.cloudAcknowledged = cloudAcknowledged
        self.chatHotKey = chatHotKey
        self.quickActionHotKey = quickActionHotKey
    }

    var access: MemoryAccess { MemoryAccess(categories: Set(memoryCategories)) }

    /// 是否有任何内容会离开本机。
    var usesCloud: Bool { agent?.isCloud == true }

    private enum CodingKeys: String, CodingKey {
        case agent, memoryCategories, cloudAcknowledged, chatHotKey, quickActionHotKey
    }

    /// 缺字段补默认值；不认识的分区名忽略。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        agent = try? c.decodeIfPresent(AssistantModelChoice.self, forKey: .agent)
        let names = try? c.decodeIfPresent([String].self, forKey: .memoryCategories)
        memoryCategories = names.map { $0.compactMap(MemoryCategory.init(rawValue:)) } ?? d.memoryCategories
        cloudAcknowledged = (try? c.decodeIfPresent(Bool.self, forKey: .cloudAcknowledged)) ?? false
        chatHotKey = (try? c.decodeIfPresent(HotKeyBinding.self, forKey: .chatHotKey)) ?? d.chatHotKey
        quickActionHotKey = (try? c.decodeIfPresent(HotKeyBinding.self, forKey: .quickActionHotKey)) ?? d.quickActionHotKey
    }
}

/// 把模型选择变成可用的 `ChatModel`。
enum AssistantModelFactory {
    struct Context {
        let keychain: KeychainStore
        let chatGPT: ChatGPTSession
        let claudeWorkdir: URL
    }

    static func make(_ choice: AssistantModelChoice, context: Context) -> Result<any ChatModel, CloudError> {
        if choice.source.mode == .local {
            guard LocalInferenceBackend.isInstalled(tag: choice.localModelTag) else {
                return .failure(.local(String(localized: "本地模型尚未下载：\(choice.label)")))
            }
            return .success(MLXChatModel(modelTag: choice.localModelTag))
        }
        // 云端客户端的构建沿用记忆整理的工厂；这里不需要本地模型，传一个不会被用到的占位。
        let consolidation = ConsolidationModelContext(
            local: MLXModelProvider(modelTag: choice.localModelTag), keychain: context.keychain,
            chatGPT: context.chatGPT, claudeWorkdir: context.claudeWorkdir
        )
        switch ConsolidationModelFactory.client(choice.source, context: consolidation) {
        case .success(let client):
            guard let model = client as? any ChatModel else {
                return .failure(.local(String(localized: "这个模型来源不支持对话")))
            }
            return .success(model)
        case .failure(let error):
            return .failure(error)
        }
    }
}

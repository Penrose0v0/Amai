import AmaiCloud
import AmaiExtraction
import AmaiMemory
import AmaiPerception
import SwiftUI

/// 模型来源的选项（界面用）。云端来源与记忆整理相同，账户（API Key、ChatGPT 登录、Claude Code）
/// 在「模型」页里设置，这里只选来源与模型名。
private enum ModelSourceKind: String, CaseIterable, Identifiable {
    case none, local, anthropic, openai, chatgpt, claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "未选择")
        case .local: String(localized: "本地模型（不联网）")
        case .anthropic: "Anthropic API Key"
        case .openai: String(localized: "OpenAI 兼容接口（API Key）")
        case .chatgpt: String(localized: "ChatGPT 订阅")
        case .claudeCode: String(localized: "Claude 订阅（本机 Claude Code）")
        }
    }

    init(_ choice: AssistantModelChoice?) {
        guard let choice else { self = .none; return }
        switch choice.source.mode {
        case .local: self = .local
        case .apiKey: self = choice.source.provider == .anthropic ? .anthropic : .openai
        case .chatgptPlan: self = .chatgpt
        case .claudeCode: self = .claudeCode
        }
    }
}

/// 选择 Agent 模型：来源 + 具体模型。
private struct ModelChoiceEditor: View {
    let model: AppModel
    @Binding var choice: AssistantModelChoice?
    /// "未选择"这一项的文字。
    let noneTitle: String

    @State private var installed: [LocalModelOption] = []

    var body: some View {
        Picker("来源", selection: Binding(get: { ModelSourceKind(choice) }, set: { select($0) })) {
            ForEach(ModelSourceKind.allCases) { kind in
                Text(verbatim: kind == .none ? noneTitle : kind.title).tag(kind)
            }
        }
        // 挂在选择器上：挂在 EmptyView 上的 task 不会执行，已下载的模型就列不出来。
        .task(id: model.installedModelsVersion) {
            installed = LocalModelCatalog.all.filter { LocalInferenceBackend.isInstalled(tag: $0.tag) }
        }
        if let current = choice {
            switch ModelSourceKind(current) {
            case .none:
                EmptyView()
            case .local:
                if installed.isEmpty {
                    Text("还没有下载本地模型。可以在「模型」页的屏幕理解里下载。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("模型", selection: Binding(
                        get: { current.localModelTag },
                        set: { tag in update { $0.localModelTag = tag } }
                    )) {
                        ForEach(installed) { option in
                            Text(verbatim: "\(option.displayName) · \(String(localized: "占约 \(option.memoryGB) GB 内存"))").tag(option.tag)
                        }
                    }
                    if current.localModelTag == model.modelTag {
                        Text("与屏幕理解是同一个模型，共用一份权重，不额外占用内存。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .anthropic:
                TextField("模型", text: text(\.anthropicModel), prompt: Text(verbatim: AnthropicClient.defaultModel))
                accountNote(model.keychain.apiKey(for: .anthropic) != nil)
            case .openai:
                TextField("模型", text: text(\.openaiModel), prompt: Text(verbatim: "gpt-…"))
                TextField("接口地址", text: text(\.openaiBaseURL))
                accountNote(model.keychain.apiKey(for: .openai) != nil)
            case .chatgpt:
                TextField("模型", text: text(\.chatgptModel))
                accountNote(model.chatGPTStatus?.signedIn == true)
            case .claudeCode:
                TextField("模型", text: text(\.claudeCodeModel), prompt: Text(verbatim: ClaudeCodeClient.defaultModel))
                Text("通过本机已登录的 Claude Code 调用，使用订阅额度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accountNote(_ configured: Bool) -> some View {
        Text(configured
             ? String(localized: "使用「模型」页里已设置的账户。")
             : String(localized: "还没有设置账户：请先在「模型」页的记忆整理里填写 API Key 或登录。"))
            .font(.caption)
            .foregroundStyle(configured ? Color.secondary : Color.orange)
    }

    private func text(_ keyPath: WritableKeyPath<ConsolidationModelConfiguration, String>) -> Binding<String> {
        Binding(
            get: { choice?.source[keyPath: keyPath] ?? "" },
            set: { value in update { $0.source[keyPath: keyPath] = value } }
        )
    }

    private func update(_ change: (inout AssistantModelChoice) -> Void) {
        guard var current = choice else { return }
        change(&current)
        choice = current
    }

    /// 切换来源时，云端的模型名等沿用记忆整理里已填的值，省得再填一遍。
    private func select(_ kind: ModelSourceKind) {
        guard kind != ModelSourceKind(choice) else { return }
        var source = choice?.source ?? model.consolidationModel
        let localTag = choice?.localModelTag
            ?? installed.first { $0.tag == model.modelTag }?.tag ?? installed.first?.tag ?? model.modelTag
        switch kind {
        case .none:
            choice = nil
            return
        case .local: source.mode = .local
        case .anthropic: source.mode = .apiKey; source.provider = .anthropic
        case .openai: source.mode = .apiKey; source.provider = .openai
        case .chatgpt: source.mode = .chatgptPlan
        case .claudeCode: source.mode = .claudeCode
        }
        choice = AssistantModelChoice(source: source, localModelTag: localTag)
    }
}

/// 助手的设置项：Agent 模型、可读取的记忆分区。设置页与首次引导共用。
/// 改动先停留在草稿里，点"保存并应用"才生效；选用云端模型时在这里确认一次发送范围，之后的调用不再询问。
struct AssistantModelSections: View {
    let model: AppModel
    /// 保存成功后调用（引导用它来放行"下一步"）。
    var onApplied: () -> Void = {}

    @State private var draft = AssistantConfiguration.default
    @State private var loaded = false
    @State private var message: String?
    @State private var confirmCloud = false

    private var dirty: Bool { draft != model.assistantConfiguration }

    var body: some View {
        Group {
            Section {
                ModelChoiceEditor(model: model, choice: $draft.agent, noneTitle: String(localized: "未选择（助手不可用）"))
            } header: {
                Text("Agent 模型")
            } footer: {
                Text("对话、记忆问答和对选中文字的翻译润色都用这个模型。本地模型不联网；云端模型更强，但内容会发给该服务。")
            }

            Section {
                ForEach(MemoryCategory.allCases, id: \.self) { category in
                    Toggle(isOn: Binding(
                        get: { draft.memoryCategories.contains(category) },
                        set: { on in
                            draft.memoryCategories.removeAll { $0 == category }
                            if on { draft.memoryCategories.append(category) }
                        }
                    )) {
                        Text(verbatim: category == .daily ? String(localized: "每日记录（时间线与每日总结）") : category.localizedName)
                    }
                }
            } header: {
                Text("助手可读取的记忆")
            } footer: {
                Text("未勾选的分区助手读不到，也不会出现在检索结果里。本地模型与云端模型使用同一份授权。助手只读记忆，不会修改。")
            }

            Section {
                LabeledContent {
                    Button("保存并应用") { save() }
                        .disabled(!dirty)
                        .keyboardShortcut(.defaultAction)
                } label: {
                    Text(verbatim: message ?? status)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            draft = model.assistantConfiguration
            loaded = true
        }
        .alert("使用云端模型？", isPresented: $confirmCloud) {
            Button("取消", role: .cancel) {}
            Button("确认并应用") { apply(acknowledged: true) }
        } message: {
            Text(Self.cloudNote(draft))
        }
    }

    /// 当前生效配置的状态说明。
    private var status: String {
        if dirty { return String(localized: "有未保存的修改") }
        guard let assistant = model.assistant else { return "" }
        if let problem = assistant.setupMessage { return problem }
        if assistant.isReady {
            return assistant.sendsDataOffDevice
                ? String(localized: "已启用 · 云端 · \(assistant.modelLabel)")
                : String(localized: "已启用 · 本地 · \(assistant.modelLabel)")
        }
        return String(localized: "尚未选择 Agent 模型")
    }

    static func cloudNote(_ configuration: AssistantConfiguration) -> String {
        var services: [String] = []
        for choice in [configuration.agent].compactMap({ $0 }) where choice.isCloud {
            if !services.contains(choice.source.serviceName) { services.append(choice.source.serviceName) }
        }
        let names = services.joined(separator: "、")
        let categories = MemoryCategory.allCases.filter(configuration.memoryCategories.contains).map(\.localizedName).joined(separator: "、")
        return String(localized: "使用助手时，以下内容会发送给 \(names)：你的提问与对话、选中的文字、当前窗口的应用名与屏幕文字、你要求查看屏幕时的截图，以及助手从这些分区检索到的记忆：\(categories.isEmpty ? String(localized: "（无）") : categories)。\n\n只在你使用助手时发送；后台的截图与屏幕理解仍然只在本机进行。之后每次使用不再询问，可以随时在这里改回本地模型。")
    }

    private func save() {
        // 第一次选用云端模型，或云端的发送范围（服务、可读分区）变大时，重新确认一次。
        let current = model.assistantConfiguration
        let needsConfirmation = draft.usesCloud && (
            !current.cloudAcknowledged || !current.usesCloud
                || Set(draft.memoryCategories) != Set(current.memoryCategories)
                || draft.agent?.source.serviceName != current.agent?.source.serviceName
        )
        if needsConfirmation {
            confirmCloud = true
        } else {
            apply(acknowledged: draft.usesCloud ? current.cloudAcknowledged : false)
        }
    }

    private func apply(acknowledged: Bool) {
        draft.cloudAcknowledged = acknowledged
        if let error = model.applyAssistant(draft) {
            message = error
        } else {
            message = nil
            onApplied()
        }
    }
}

/// 设置的「助手」页。
struct AssistantSettingsView: View {
    let model: AppModel
    @State private var accessibilityGranted = AccessibilityReader().isTrusted
    @State private var confirmDelete = false
    @State private var message: String?
    @State private var embedderInstalled = false

    var body: some View {
        Form {
            if model.isMemoryPreview || model.assistant == nil {
                Text("预览模式下助手不可用。").foregroundStyle(.secondary)
            } else {
                AssistantModelSections(model: model)
                semanticSearch
                shortcuts
                permissions
                history
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                accessibilityGranted = AccessibilityReader().isTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 记忆的语义检索：一个可选的本地向量模型。下载后自动启用，没有它时只按关键词检索。
    private var semanticSearch: some View {
        let tag = MLXTextEmbedder.defaultModelTag
        return Section {
            LabeledContent {
                if let progress = model.modelDownloads[tag] {
                    HStack(spacing: 6) {
                        if let progress {
                            ProgressView(value: progress).frame(width: 80)
                            Text("\(Int(progress * 100))%").font(.caption.monospacedDigit())
                        } else {
                            ProgressView().controlSize(.small)
                            Text("准备中").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("取消") { model.cancelLocalModelDownload(tag) }
                    }
                } else if embedderInstalled {
                    Text("已安装").foregroundStyle(.secondary)
                } else {
                    Button("下载") { model.downloadLocalModel(tag) }
                        .disabled(model.isMemoryPreview)
                }
            } label: {
                Text("语义检索模型")
                Text("Qwen3 Embedding 0.6B · 下载约 \(MLXTextEmbedder.downloadMB) MB")
                if let error = model.modelDownloadErrors[tag] {
                    Text(error).foregroundStyle(.red)
                }
            }
        } header: {
            Text("记忆检索")
        } footer: {
            Text("助手在回答前会先检索你的记忆。有了这个模型，问法与记录的措辞不同、或语言不同时也能找到；没有它时只按关键词检索。模型只在本机运行。")
        }
        .task(id: model.installedModelsVersion) {
            embedderInstalled = LocalInferenceBackend.isInstalled(tag: tag)
        }
    }

    private var shortcuts: some View {
        Section {
            hotKeyPicker(String(localized: "打开对话"), \.chatHotKey)
            if let problems = model.assistant?.hotKeyProblems, !problems.isEmpty {
                Text("无法注册 \(problems.joined(separator: "、"))：可能已被其他应用占用，请换一个组合。")
                    .foregroundStyle(.orange)
            }
            if let message { Text(verbatim: message).foregroundStyle(.secondary) }
        } header: {
            Text("快捷键")
        } footer: {
            Text("在任意应用里选中文字后打开对话，可以翻译、润色、解释，或带着这段文字提问。")
        }
    }

    private func hotKeyPicker(_ title: String, _ keyPath: WritableKeyPath<AssistantConfiguration, HotKeyBinding>) -> some View {
        Picker(title, selection: Binding(
            get: { model.assistantConfiguration[keyPath: keyPath] },
            set: { binding in
                var updated = model.assistantConfiguration
                updated[keyPath: keyPath] = binding
                message = model.applyAssistant(updated)
            }
        )) {
            ForEach(HotKeyBinding.presets, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
    }

    private var permissions: some View {
        Section {
            LabeledContent("辅助功能") {
                if accessibilityGranted {
                    Text("已授权").foregroundStyle(.secondary)
                } else {
                    Button("授权…") {
                        AccessibilityReader.requestTrust()
                        AccessibilityReader.openSystemSettings()
                    }
                }
            }
        } header: {
            Text("权限")
        } footer: {
            Text("用于读取其他应用的窗口标题和选中的文字。只在你唤起助手时读取，不监听键盘。没有这项权限时对话仍可使用，但读不到选区。屏幕截图沿用已有的屏幕录制权限和「感知」里的排除名单。")
        }
    }

    private var history: some View {
        Section {
            LabeledContent("对话记录") {
                Button("全部删除…", role: .destructive) { confirmDelete = true }
            }
        } footer: {
            Text("对话记录只保存在这台 Mac 上，包含你的提问、助手的回答和引用的记忆来源，不保存截图和屏幕文字。它不是记忆的一部分。")
        }
        .confirmationDialog("删除全部对话记录？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { model.assistant?.chat.deleteAllSessions() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作无法撤销。")
        }
    }
}

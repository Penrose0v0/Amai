import AmaiCloud
import SwiftUI

/// 模型页的「记忆整理」（ADR-0004 / ADR-0005）：本地、API Key、ChatGPT 订阅、Claude 订阅四种来源。
/// 只显示当前选中来源的配置；从本地切换到云端来源时，先确认会发送哪些数据、发往哪里。
struct ConsolidationModelSections: View {
    let model: AppModel

    @State private var draft = ConsolidationModelConfiguration.default
    @State private var message: String?
    @State private var busy = false
    @State private var confirmCloud = false

    // API Key
    @State private var keyInput = ""
    @State private var storedKeys: [CloudProvider: String] = [:]

    // ChatGPT
    @State private var chatGPTModels: [ChatGPTModel] = []
    @State private var signingIn = false
    @State private var showWelcome = false

    // Claude Code
    @State private var claudeStatus: Result<ClaudeCodeStatus, CloudError>?
    @State private var customClaudeModel = false

    var body: some View {
        Group {
            Section {
                Picker("来源", selection: $draft.mode) {
                    ForEach(ConsolidationModelConfiguration.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("记忆整理")
            } footer: {
                Text("用于日终摘要、各分区记忆与综合档案的整理。屏幕理解始终在本机进行。")
            }

            switch draft.mode {
            case .local: EmptyView()
            case .apiKey: apiKeySections
            case .chatgptPlan: chatGPTSections
            case .claudeCode: claudeSections
            }

            Section {
                LabeledContent("当前生效", value: model.consolidationModelLabel)
                if let message {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    if draft.mode.isCloud {
                        Button("测试连接") { test() }.disabled(busy || signingIn)
                    }
                    Button("保存并应用") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || signingIn)
                }
            } footer: {
                if draft.mode.isCloud {
                    Text("整理时会把记忆相关的文本发送给 \(draft.serviceName)，不发送截图与屏幕文字。")
                        .help(Self.privacyNote(draft))
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: draft.mode) { onModeChange() }
        .alert("开启云端整理？", isPresented: $confirmCloud) {
            Button("取消", role: .cancel) {}
            Button("确认开启") { Task { await apply() } }
        } message: {
            Text(Self.privacyNote(draft))
        }
        // 官方 UI 规范：首次以套餐用量登录后显示一次，可关闭。
        .alert("You're using your ChatGPT plan", isPresented: $showWelcome) {
            Button("Got it") { Task { await model.markChatGPTWelcomed() } }
            Button("Manage usage") {
                model.openChatGPTUsage()
                Task { await model.markChatGPTWelcomed() }
            }
        } message: {
            Text("Amai 的记忆整理请求会使用你的 ChatGPT 套餐额度。可以在 ChatGPT 设置中查看和管理用量。这与 Amai 自身的任何收费无关。")
        }
    }

    // MARK: - API Key

    @ViewBuilder
    private var apiKeySections: some View {
        Section("API") {
            Picker("提供商", selection: $draft.provider) {
                ForEach(CloudProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .onChange(of: draft.provider) { keyInput = "" }
            switch draft.provider {
            case .anthropic:
                TextField("模型", text: $draft.anthropicModel, prompt: Text(AnthropicClient.defaultModel))
                Picker("推理强度", selection: $draft.anthropicEffort) {
                    ForEach(AnthropicClient.efforts, id: \.self) { Text($0).tag($0) }
                }
            case .openai:
                TextField("模型", text: $draft.openaiModel, prompt: Text("必填，你账户可用的模型 ID"))
                Picker("推理强度", selection: $draft.openaiReasoningEffort) {
                    ForEach(OpenAIClient.reasoningEfforts, id: \.self) { Text($0.isEmpty ? String(localized: "不发送") : $0).tag($0) }
                }
                TextField("API 地址", text: $draft.openaiBaseURL)
            }
        }
        Section {
            if let stored = storedKeys[draft.provider] {
                LabeledContent("已保存") {
                    HStack(spacing: 10) {
                        Text(KeychainStore.masked(stored)).foregroundStyle(.secondary)
                        Button("删除", role: .destructive) { deleteKey() }
                    }
                }
            }
            LabeledContent(storedKeys[draft.provider] == nil ? "API Key" : "替换") {
                HStack(spacing: 10) {
                    SecureField("", text: $keyInput, prompt: Text("粘贴 API Key"))
                        .labelsHidden()
                    Button("保存") { saveKey() }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("保存在 macOS 钥匙串中。")
        }
    }

    // MARK: - ChatGPT subscription

    @ViewBuilder
    private var chatGPTSections: some View {
        Section {
            let status = model.chatGPTStatus
            if let status, status.signedIn {
                LabeledContent("账号", value: status.email ?? "ChatGPT 账号")
                LabeledContent("套餐用量") {
                    Text(status.planUsageGranted ? "Using ChatGPT plan" : "未授予，请退出后重新登录并允许")
                        .foregroundStyle(status.planUsageGranted ? Color.secondary : Color.orange)
                }
                HStack {
                    Spacer()
                    Button("Manage usage") { model.openChatGPTUsage() }
                    Button("退出登录") { signOutChatGPT() }.disabled(busy)
                }
            } else {
                LabeledContent("账号") {
                    Button(signingIn ? "等待浏览器授权…" : "Continue with ChatGPT") { signInChatGPT() }
                        .disabled(signingIn)
                }
            }
        } header: {
            Text("ChatGPT 账号")
        } footer: {
            if model.chatGPTStatus?.signedIn != true {
                Text("在浏览器中登录 OpenAI 并授权。Amai 看不到你的密码和对话。")
            }
        }
        if model.chatGPTStatus?.signedIn == true {
            Section("模型") {
                LabeledContent("模型") {
                    HStack(spacing: 10) {
                        if chatGPTModels.isEmpty {
                            TextField("", text: $draft.chatgptModel, prompt: Text("点击刷新获取可用模型"))
                                .labelsHidden()
                        } else {
                            Picker("", selection: $draft.chatgptModel) {
                                ForEach(chatGPTModels) { Text($0.displayName).tag($0.slug) }
                                if !draft.chatgptModel.isEmpty, !chatGPTModels.contains(where: { $0.slug == draft.chatgptModel }) {
                                    Text(draft.chatgptModel).tag(draft.chatgptModel)
                                }
                            }
                            .labelsHidden()
                        }
                        Button("刷新") { loadChatGPTModels() }.disabled(busy)
                    }
                }
            }
        }
    }

    // MARK: - Claude subscription

    @ViewBuilder
    private var claudeSections: some View {
        Section {
            LabeledContent("状态") {
                HStack(spacing: 10) {
                    claudeStatusText
                    Button("重新检测") { loadClaudeStatus() }
                }
            }
            if case .success(let status) = claudeStatus {
                LabeledContent("程序", value: "\(status.executable.lastPathComponent) \(status.version)")
                    .help(status.executable.path)
            }
            TextField("程序路径", text: $draft.claudeCodePath, prompt: Text("留空自动查找"))
        } header: {
            Text("本机 Claude Code")
        } footer: {
            Text("仅限个人使用：在本机以只生成文字的方式调用你已登录的 Claude Code。")
                .help("Amai 启动 claude -p，不启用任何工具，不加载你的全局配置与插件，也不读取或保存你的登录凭据。Anthropic 未对第三方应用以这种方式调用 Claude Code 作出明确许可，向他人分发包含此功能的版本前需要取得 Anthropic 的书面确认。")
        }
        Section("模型") {
            if customClaudeModel {
                TextField("模型 ID", text: $draft.claudeCodeModel, prompt: Text("例如 claude-opus-5-5"))
            } else {
                Picker("模型", selection: $draft.claudeCodeModel) {
                    ForEach(ClaudeCodeClient.modelAliases, id: \.self) { Text($0).tag($0) }
                    if !ClaudeCodeClient.modelAliases.contains(draft.claudeCodeModel) {
                        Text(draft.claudeCodeModel).tag(draft.claudeCodeModel)
                    }
                }
            }
            Toggle("使用完整模型 ID", isOn: $customClaudeModel)
        }
    }

    @ViewBuilder
    private var claudeStatusText: some View {
        switch claudeStatus {
        case .none:
            Text("正在检测…").foregroundStyle(.secondary)
        case .failure(let error):
            Text("未找到").foregroundStyle(.orange)
                .help("\(error.description)\n请先安装 Claude Code，或在下方指定 claude 程序路径。")
        case .success(let status):
            if status.usesSubscription {
                Text(String(localized: "已用 Claude 订阅登录") + (status.subscriptionType.map { "（\($0)）" } ?? "")).foregroundStyle(.secondary)
            } else if status.loggedIn {
                Text("未使用订阅登录").foregroundStyle(.orange)
                    .help("Claude Code 当前的登录方式是 \(status.authMethod ?? String(localized: "未知"))，调用不会使用订阅额度。")
            } else {
                Text("尚未登录").foregroundStyle(.orange)
                    .help("请在终端运行 claude，然后执行 /login。")
            }
        }
    }

    // MARK: - Privacy

    static func privacyNote(_ config: ConsolidationModelConfiguration) -> String {
        """
        开启后，每天整理与每周更新 General 时会把以下文本发送给 \(config.serviceName)：当天活动片段的标题与摘要、所用应用名、你在 daily 中手写的笔记、日终摘要，以及综合、工作、健康、财务、目标五个记忆文件的内容（含你手写的部分）。
        不会发送：截图、屏幕文字识别（OCR）原文、观察记录和任何原始数据。发送前会自动去掉密钥、令牌、银行卡号等凭据。
        数据按该服务的数据政策处理。云端调用失败时不会改用其他模型，当天会在下次重试。
        """
    }

    // MARK: - Actions

    private func load() {
        draft = model.consolidationModel
        customClaudeModel = !ClaudeCodeClient.modelAliases.contains(draft.claudeCodeModel)
        refreshStoredKeys()
        onModeChange()
    }

    private func onModeChange() {
        message = nil
        switch draft.mode {
        case .chatgptPlan:
            Task {
                await model.refreshChatGPTStatus()
                if model.chatGPTStatus?.signedIn == true && chatGPTModels.isEmpty { loadChatGPTModels() }
            }
        case .claudeCode:
            loadClaudeStatus()
        default:
            break
        }
    }

    private func refreshStoredKeys() {
        var keys: [CloudProvider: String] = [:]
        for provider in CloudProvider.allCases {
            if let key = model.keychain.apiKey(for: provider) { keys[provider] = key }
        }
        storedKeys = keys
    }

    private func saveKey() {
        do {
            try model.keychain.setAPIKey(keyInput, for: draft.provider)
            keyInput = ""
            refreshStoredKeys()
            message = String(localized: "\(draft.provider.displayName) API Key 已保存到钥匙串")
            if model.consolidationModel.mode == .apiKey { Task { _ = await model.applyConsolidationModel(model.consolidationModel) } }
        } catch {
            message = String(localized: "保存 Key 失败：\(String(describing: error))")
        }
    }

    private func deleteKey() {
        try? model.keychain.deleteAPIKey(for: draft.provider)
        refreshStoredKeys()
        message = String(localized: "已删除 \(draft.provider.displayName) API Key")
        if model.consolidationModel.mode == .apiKey { Task { _ = await model.applyConsolidationModel(model.consolidationModel) } }
    }

    private func signInChatGPT() {
        signingIn = true
        message = String(localized: "已在浏览器中打开 OpenAI 授权页面，请完成登录并允许 Amai 使用你的 ChatGPT 套餐。")
        Task {
            let error = await model.signInChatGPT()
            signingIn = false
            if let error {
                message = String(localized: "登录失败：\(String(describing: error))")
                return
            }
            await model.refreshChatGPTStatus()
            message = String(localized: "已登录 ChatGPT")
            showWelcome = model.chatGPTStatus?.needsWelcome == true
            loadChatGPTModels()
        }
    }

    private func signOutChatGPT() {
        busy = true
        Task {
            message = await model.signOutChatGPT() ?? String(localized: "已退出 ChatGPT 登录并撤销授权")
            chatGPTModels = []
            busy = false
        }
    }

    private func loadChatGPTModels() {
        busy = true
        Task {
            switch await model.chatGPTModels() {
            case .success(let models):
                chatGPTModels = models
                if draft.chatgptModel.isEmpty, let first = models.first { draft.chatgptModel = first.slug }
                if models.isEmpty { message = String(localized: "没有可用的模型") }
            case .failure(let error):
                message = String(localized: "获取模型列表失败：\(error.description)")
            }
            busy = false
        }
    }

    private func loadClaudeStatus() {
        claudeStatus = nil
        let path = draft.claudeCodePath
        Task { claudeStatus = await model.claudeCodeStatus(configuredPath: path) }
    }

    private func test() {
        busy = true
        message = String(localized: "正在测试…")
        let config = draft
        let key = keyInput
        Task {
            message = await model.testConnection(config, apiKey: key)
            busy = false
        }
    }

    private func save() {
        if draft.mode.isCloud && draft.mode != model.consolidationModel.mode {
            confirmCloud = true
        } else {
            Task { await apply() }
        }
    }

    private func apply() async {
        busy = true
        if let error = await model.applyConsolidationModel(draft) {
            message = error
        } else {
            message = String(localized: "已应用：\(model.consolidationModelLabel)")
            switch draft.mode {
            case .apiKey where storedKeys[draft.provider] == nil:
                message! += String(localized: "。注意：尚未保存 \(draft.provider.displayName) API Key，整理会失败。")
            case .chatgptPlan where model.chatGPTStatus?.signedIn != true:
                message! += String(localized: "。注意：尚未登录 ChatGPT，整理会失败。")
            case .chatgptPlan where draft.chatgptModel.isEmpty:
                message! += String(localized: "。注意：尚未选择模型。")
            default:
                break
            }
        }
        busy = false
    }
}

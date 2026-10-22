import AmaiCloud
import SwiftUI

/// 记忆整理模型设置（ADR-0004 / ADR-0005）：本地、API Key、ChatGPT 订阅、Claude 订阅四种来源。
/// 从本地切换到任一云端来源时，先确认会发送哪些数据、发往哪里。
struct ModelSettingsView: View {
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
        Form {
            Section {
                Picker("整理模型", selection: $draft.mode) {
                    ForEach(ConsolidationModelConfiguration.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("只影响日终摘要、work 专题与 summary 的整理。屏幕抽取始终在本机运行，截图与屏幕文字不会发送到任何服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch draft.mode {
            case .local: EmptyView()
            case .apiKey: apiKeySections
            case .chatgptPlan: chatGPTSections
            case .claudeCode: claudeSections
            }

            if draft.mode.isCloud {
                Section("隐私") {
                    Text(Self.privacyNote(draft))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let message {
                Text(message).font(.callout).textSelection(.enabled)
            }

            HStack {
                Text("当前：\(model.consolidationModelLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if draft.mode.isCloud {
                    Button("测试连接") { test() }.disabled(busy || signingIn)
                }
                Button("保存并应用") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || signingIn)
            }
        }
        .formStyle(.grouped)
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
        Section("提供商") {
            Picker("提供商", selection: $draft.provider) {
                ForEach(CloudProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .onChange(of: draft.provider) { keyInput = "" }
            switch draft.provider {
            case .anthropic:
                TextField("模型", text: $draft.anthropicModel, prompt: Text(AnthropicClient.defaultModel))
                Picker("推理强度（effort）", selection: $draft.anthropicEffort) {
                    ForEach(AnthropicClient.efforts, id: \.self) { Text($0).tag($0) }
                }
            case .openai:
                TextField("模型", text: $draft.openaiModel, prompt: Text("必填，你账户可用的模型 ID"))
                Picker("推理强度（reasoning_effort）", selection: $draft.openaiReasoningEffort) {
                    ForEach(OpenAIClient.reasoningEfforts, id: \.self) { Text($0.isEmpty ? "不发送" : $0).tag($0) }
                }
                TextField("API 地址", text: $draft.openaiBaseURL)
            }
        }
        Section("API Key（保存在 macOS 钥匙串）") {
            if let stored = storedKeys[draft.provider] {
                HStack {
                    Text("已保存 \(KeychainStore.masked(stored))")
                    Spacer()
                    Button("删除", role: .destructive) { deleteKey() }
                }
            }
            HStack {
                SecureField(storedKeys[draft.provider] == nil ? "粘贴 API Key" : "替换 API Key", text: $keyInput)
                Button("保存 Key") { saveKey() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - ChatGPT subscription

    @ViewBuilder
    private var chatGPTSections: some View {
        Section("ChatGPT 账号") {
            let status = model.chatGPTStatus
            if let status, status.signedIn {
                HStack {
                    VStack(alignment: .leading) {
                        Text("已登录：\(status.email ?? "ChatGPT 账号")")
                        Text(status.planUsageGranted ? "Using ChatGPT plan" : "未授予套餐用量：请退出后重新登录并允许")
                            .font(.caption)
                            .foregroundStyle(status.planUsageGranted ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    Button("Manage usage") { model.openChatGPTUsage() }
                    Button("退出登录") { signOutChatGPT() }.disabled(busy)
                }
            } else {
                Text("用你的 ChatGPT 订阅额度做记忆整理。点击下方按钮会打开浏览器，在 OpenAI 页面登录并授权 Amai；Amai 不会看到你的密码，也无法访问你的 ChatGPT 对话。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button(signingIn ? "等待浏览器授权…" : "Continue with ChatGPT") { signInChatGPT() }
                    .disabled(signingIn)
            }
        }
        if model.chatGPTStatus?.signedIn == true {
            Section("模型") {
                if chatGPTModels.isEmpty {
                    TextField("模型 slug", text: $draft.chatgptModel, prompt: Text("点击“刷新列表”获取可用模型"))
                } else {
                    Picker("模型", selection: $draft.chatgptModel) {
                        ForEach(chatGPTModels) { Text($0.displayName).tag($0.slug) }
                        if !draft.chatgptModel.isEmpty, !chatGPTModels.contains(where: { $0.slug == draft.chatgptModel }) {
                            Text(draft.chatgptModel).tag(draft.chatgptModel)
                        }
                    }
                }
                Button("刷新列表") { loadChatGPTModels() }.disabled(busy)
            }
        }
    }

    // MARK: - Claude subscription

    @ViewBuilder
    private var claudeSections: some View {
        Section("本机 Claude Code") {
            switch claudeStatus {
            case .none:
                Text("正在检测…").font(.caption)
            case .failure(let error):
                Text(error.description).foregroundStyle(.orange)
                Text("请先安装 Claude Code，或在下方指定 claude 程序路径。").font(.caption)
            case .success(let status):
                Text("\(status.executable.path)\n版本 \(status.version)")
                    .font(.caption)
                    .textSelection(.enabled)
                if status.usesSubscription {
                    Text("已用 Claude 订阅登录" + (status.subscriptionType.map { "（\($0)）" } ?? ""))
                } else if status.loggedIn {
                    Text("Claude Code 当前不是用 Claude 订阅登录（\(status.authMethod ?? "未知")），调用不会使用订阅额度。")
                        .foregroundStyle(.orange)
                } else {
                    Text("Claude Code 尚未登录：请在终端运行 claude，然后执行 /login。Amai 不会读取或保存你的登录凭据。")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("claude 程序路径", text: $draft.claudeCodePath, prompt: Text("留空自动查找"))
            Button("重新检测") { loadClaudeStatus() }
        }
        Section("模型") {
            Picker("模型", selection: $draft.claudeCodeModel) {
                ForEach(ClaudeCodeClient.modelAliases, id: \.self) { Text($0).tag($0) }
                if !ClaudeCodeClient.modelAliases.contains(draft.claudeCodeModel) {
                    Text(draft.claudeCodeModel).tag(draft.claudeCodeModel)
                }
            }
            Toggle("使用完整模型 ID", isOn: $customClaudeModel)
            if customClaudeModel {
                TextField("模型 ID", text: $draft.claudeCodeModel, prompt: Text("例如 claude-opus-5-5"))
            }
        }
        Section {
            Text("个人使用：Amai 在本机启动你已登录的 Claude Code（claude -p），只生成文字，不启用任何工具，不加载你的全局配置与插件。Anthropic 未对第三方应用以这种方式调用 Claude Code 作出明确许可，向他人分发包含此功能的版本前需要取得 Anthropic 的书面确认。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Privacy

    static func privacyNote(_ config: ConsolidationModelConfiguration) -> String {
        """
        开启后，每天整理与每周更新 summary 时会把以下文本发送给 \(config.serviceName)：daily 文件全文（时间线、日终摘要、你手写的笔记）、work 专题条目、summary.md 全文（含你手写的部分）。
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
            message = "\(draft.provider.displayName) API Key 已保存到钥匙串"
            if model.consolidationModel.mode == .apiKey { Task { _ = await model.applyConsolidationModel(model.consolidationModel) } }
        } catch {
            message = "保存 Key 失败：\(error)"
        }
    }

    private func deleteKey() {
        try? model.keychain.deleteAPIKey(for: draft.provider)
        refreshStoredKeys()
        message = "已删除 \(draft.provider.displayName) API Key"
        if model.consolidationModel.mode == .apiKey { Task { _ = await model.applyConsolidationModel(model.consolidationModel) } }
    }

    private func signInChatGPT() {
        signingIn = true
        message = "已在浏览器中打开 OpenAI 授权页面，请完成登录并允许 Amai 使用你的 ChatGPT 套餐。"
        Task {
            let error = await model.signInChatGPT()
            signingIn = false
            if let error {
                message = "登录失败：\(error)"
                return
            }
            await model.refreshChatGPTStatus()
            message = "已登录 ChatGPT"
            showWelcome = model.chatGPTStatus?.needsWelcome == true
            loadChatGPTModels()
        }
    }

    private func signOutChatGPT() {
        busy = true
        Task {
            message = await model.signOutChatGPT() ?? "已退出 ChatGPT 登录并撤销授权"
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
                if models.isEmpty { message = "没有可用的模型" }
            case .failure(let error):
                message = "获取模型列表失败：\(error.description)"
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
        message = "正在测试…"
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
            message = "已应用：\(model.consolidationModelLabel)"
            switch draft.mode {
            case .apiKey where storedKeys[draft.provider] == nil:
                message! += "。注意：尚未保存 \(draft.provider.displayName) API Key，整理会失败。"
            case .chatgptPlan where model.chatGPTStatus?.signedIn != true:
                message! += "。注意：尚未登录 ChatGPT，整理会失败。"
            case .chatgptPlan where draft.chatgptModel.isEmpty:
                message! += "。注意：尚未选择模型。"
            default:
                break
            }
        }
        busy = false
    }
}

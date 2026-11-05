import AmaiCore
import AmaiPerception
import AppKit
import SwiftUI

/// 设置窗口的标签页。菜单中的"查看运行状态…"会直接打开运行状态页。
enum SettingsTab: String, CaseIterable {
    case general, perception, model, status, advanced
    static let storageKey = "settings.tab"
}

/// 原生"设置"窗口（⌘,）：通用、感知、模型、运行状态、高级。
/// 每页使用 grouped Form：Section 有标题，设置行统一为左侧名称、右侧值或操作。
struct SettingsView: View {
    let model: AppModel
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            PerceptionSettingsView(model: model)
                .tabItem { Label("感知", systemImage: "eye") }
                .tag(SettingsTab.perception.rawValue)
            ModelSettingsTab(model: model)
                .tabItem { Label("模型", systemImage: "cpu") }
                .tag(SettingsTab.model.rawValue)
            RuntimeStatusView(model: model)
                .tabItem { Label("运行状态", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(SettingsTab.status.rawValue)
            AdvancedSettingsView(model: model)
                .tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced.rawValue)
        }
        .frame(width: 620, height: 560)
        .onAppear {
            // 旧版本保存过已不存在的标签（例如 localModel），回到通用。
            if SettingsTab(rawValue: tab) == nil { tab = SettingsTab.general.rawValue }
        }
    }
}

// MARK: - 通用

private struct GeneralSettingsView: View {
    let model: AppModel
    @State private var languageMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("状态") {
                    HStack(spacing: 10) {
                        Text(recordingState).foregroundStyle(.secondary)
                        recordingButton
                    }
                }
            } header: {
                Text("记录")
            } footer: {
                Text("暂停期间不截图，也不处理屏幕活动。")
            }

            Section {
                Picker("界面语言", selection: Binding(
                    get: { model.interfaceLanguage },
                    set: { model.interfaceLanguage = $0 }
                )) {
                    ForEach(AppModel.InterfaceLanguage.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                if model.interfaceLanguage != model.interfaceLanguageAtLaunch {
                    LabeledContent("重新启动后生效") {
                        Button("立即重启") { model.relaunch() }
                    }
                }
                Picker("记忆语言", selection: Binding(
                    get: { model.memoryLanguage },
                    set: { languageMessage = model.setMemoryLanguage($0) }
                )) {
                    ForEach(MemoryLanguage.allCases, id: \.self) { Text(verbatim: $0.nativeName).tag($0) }
                }
                if let languageMessage {
                    Text(languageMessage).foregroundStyle(.secondary)
                }
            } header: {
                Text("语言")
            } footer: {
                Text("界面语言切换后需要重新启动。记忆语言用于之后新写入或修改的活动记录与记忆，已保存的内容保持原样。")
            }

            Section("记忆存储") {
                LabeledContent("位置") {
                    HStack(spacing: 10) {
                        Text(model.memoryRoot.path(percentEncoded: false))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.memoryRoot.path(percentEncoded: false))
                        Button("在访达中显示") { model.openMemoryFolder() }
                    }
                }
                LabeledContent("上次更新", value: model.lastMemoryUpdate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "尚无"))
            }
        }
        .formStyle(.grouped)
    }

    private var recordingState: String {
        switch model.status?.state {
        case .running: String(localized: "正在记录")
        case .paused: String(localized: "已暂停")
        case .permissionMissing: String(localized: "缺少屏幕录制权限")
        case .error: String(localized: "截图出错，正在重试")
        case .stopped: String(localized: "未在记录")
        case nil: String(localized: "正在启动")
        }
    }

    @ViewBuilder
    private var recordingButton: some View {
        switch model.status?.state {
        case .paused: Button("继续") { model.resume() }
        case .stopped: Button("开始") { model.start() }
        case nil: Button("暂停") {}.disabled(true)
        default: Button("暂停") { model.pause() }
        }
    }
}

// MARK: - 感知

/// 屏幕采集、权限与隐私。采集参数与排除名单目前在配置文件中修改，这里只读展示，避免放置没有作用的控件。
private struct PerceptionSettingsView: View {
    let model: AppModel

    private var config: PerceptionConfiguration { model.perceptionConfiguration }

    var body: some View {
        Form {
            Section("屏幕采集") {
                LabeledContent("截图间隔", value: String(localized: "每 \(Int(config.screen.interval)) 秒"))
                    .help("电池供电或低电量时会自动拉长间隔。")
                LabeledContent("显示器", value: model.status.map { $0.screen.displays > 0 ? String(localized: "全部 \($0.screen.displays) 块") : String(localized: "全部") } ?? String(localized: "全部"))
                LabeledContent("原始截图保留", value: String(localized: "最多 \(Int(config.spool.maxAge / 3600)) 小时 · \(ByteCountFormatter.string(fromByteCount: config.spool.maxBytes, countStyle: .file))"))
                    .help("超过时间或容量上限的原始截图会自动删除；活动记录与记忆不受影响。")
            }

            Section("权限") {
                LabeledContent("屏幕录制") {
                    HStack(spacing: 10) {
                        Text(granted ? "已授权" : "未授权").foregroundStyle(granted ? Color.secondary : Color.orange)
                        if !granted {
                            Button("申请权限") { model.requestScreenRecording() }
                        }
                        Button("系统设置…") { model.openSystemSettings() }
                    }
                }
            }

            Section {
                LabeledContent("密码输入", value: String(localized: "自动跳过"))
                    .help("检测到安全输入（例如密码框）时不截图。")
                ForEach(excludedApps, id: \.self) { name in
                    LabeledContent(name, value: String(localized: "不记录"))
                }
            } header: {
                Text("隐私")
            } footer: {
                HStack {
                    Text("排除的应用在配置文件中编辑，重新启动后生效。")
                    Spacer()
                    Button("显示配置文件") { model.revealConfig() }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var granted: Bool { model.status?.screenRecordingGranted ?? false }

    /// 排除名单中的应用：能找到的显示应用名，否则显示 bundle id。
    private var excludedApps: [String] {
        let byId = config.exclusions.bundleIds.map { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
        }
        return (byId + config.exclusions.appNames).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

// MARK: - 模型

/// 屏幕理解（本地 VLM）与记忆整理（本地或云端来源）放在同一页的两个 Section 中。
private struct ModelSettingsTab: View {
    let model: AppModel

    var body: some View {
        Form {
            LocalModelSection(model: model)
            ConsolidationModelSections(model: model)
        }
        .formStyle(.grouped)
    }
}

// MARK: - 高级

/// 手动维护（平时自动进行）、文件与诊断。
private struct AdvancedSettingsView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                action(String(localized: "处理积压活动"), help: String(localized: "平时每分钟自动处理一次。")) { model.runExtractionNow() }
                action(String(localized: "同步记忆"), help: String(localized: "平时每分钟自动同步一次。")) { model.syncMemoryNow() }
                action(String(localized: "整理今日记忆"), help: String(localized: "生成今天的日终摘要并整理各分区；平时在第二天凌晨 4 点后自动整理。")) { model.consolidateToday() }
                action(String(localized: "更新综合档案"), help: String(localized: "平时每周自动更新一次。")) { model.updateGeneralNow() }
            } header: {
                Text("手动维护")
            } footer: {
                Text("这些操作平时会自动进行，通常不需要手动执行。")
            }

            Section("文件") {
                LabeledContent("记忆文件夹") { Button("在访达中显示") { model.openMemoryFolder() } }
                LabeledContent("原始数据") { Button("在访达中显示") { model.revealRawFolder() } }
                LabeledContent("配置文件") { Button("在访达中显示") { model.revealConfig() } }
            }

            Section("诊断") {
                LabeledContent("重新启动 Amai") { Button("重新启动") { model.relaunch() } }
                    .help("修改配置文件或更换本地模型后使用。")
                LabeledContent("首次使用引导") {
                    Button("重新显示") {
                        model.reopenOnboarding()
                        openWindow(id: "onboarding")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func action(_ title: String, help: String, perform: @escaping () -> Void) -> some View {
        LabeledContent(title) { Button("立即执行", action: perform) }
            .help(help)
    }
}

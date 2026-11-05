import AmaiCore
import AmaiExtraction
import AmaiMemoryUI
import AmaiPerception
import SwiftUI

/// 菜单栏应用入口（docs/architecture.md §2.4）。
///
/// 主界面是统一窗口：日常回顾（时间线、每日总结）与长期记忆（五个分区）。
/// 菜单面向普通用户，只保留：状态与上次记忆更新时间、暂停 / 继续、打开 Amai（主窗口）、立即同步、
/// 设置、退出。详细指标在"设置 → 运行状态"里，维护操作在设置的"高级"里。
/// 正常运行时只显示一行状态；出现异常时才列出具体问题和建议操作。
@main
struct AmaiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: Self.symbol(for: model))
        }

        Window("Amai", id: "main") {
            MemoryBrowserView(env: model.memoryBrowserEnvironment, controller: model.memoryBrowser) { day in
                ActivityTimelineView(model: model, day: day)
            }
            .background(SettingsRequestListener(model: model))
        }
        .defaultSize(width: 1100, height: 720)
        // 隔离预览模式（--memory-preview）启动后直接打开主窗口。
        .defaultLaunchBehavior(model.isMemoryPreview && !model.showsOnboarding ? .presented : .automatic)

        // 首次启动的引导；完成前不开始记录。
        Window("欢迎使用 Amai", id: "onboarding") {
            OnboardingView(model: model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(model.showsOnboarding ? .presented : .suppressed)

        Settings {
            // 预览模式只显示屏幕理解（只读磁盘上的安装状态，下载与改选被禁用）：
            // 记忆整理会读写钥匙串中的 API Key。
            if model.isMemoryPreview {
                Form { LocalModelSection(model: model) }
                    .formStyle(.grouped)
                    .frame(width: 620, height: 420)
            } else {
                SettingsView(model: model)
            }
        }
    }

    private static func symbol(for model: AppModel) -> String {
        if !model.issues.isEmpty { return "exclamationmark.triangle" }
        switch model.status?.state {
        case .running: return "record.circle"
        case .paused: return "pause.circle"
        case .permissionMissing, .error: return "exclamationmark.triangle"
        case .stopped, nil: return "circle.dotted"
        }
    }
}

/// 开发预览的截图流程需要打开设置窗口，而 SwiftUI 只允许从视图里调用 `openSettings`。
private struct SettingsRequestListener: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onChange(of: model.settingsRequests) { openSettings() }
    }
}

private struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.isMemoryPreview {
            Text("Amai 记忆预览（只读示例数据）")
            Divider()
            Button("打开 Amai") { showMain() }
            Divider()
            Button("退出预览") { model.quit() }
                .keyboardShortcut("q")
        } else if model.showsOnboarding {
            Text("Amai 尚未开始记录")
            Divider()
            Button("继续设置…") { showOnboarding() }
            Divider()
            Button("退出 Amai") { model.quit() }
                .keyboardShortcut("q")
        } else {
            fullMenu
        }
    }

    @ViewBuilder
    private var fullMenu: some View {
        Text(statusTitle)
        if let updated = model.lastMemoryUpdate {
            Text("记忆更新于 \(updated.formatted(.relative(presentation: .named)))")
        }

        let issues = model.issues
        if !issues.isEmpty {
            Divider()
            ForEach(issues) { issue in
                Text("⚠︎ \(issue.message)")
                ForEach(issue.actions, id: \.self) { action in
                    Button(action.title) { perform(action) }
                }
            }
        }

        Divider()
        recordingControl

        Divider()
        Button("打开 Amai") { showMain() }
        Button("立即同步") { model.syncNow() }

        Divider()
        Button("设置…") { showSettings() }
            .keyboardShortcut(",")

        Divider()
        Button("退出 Amai") { model.quit() }
            .keyboardShortcut("q")
    }

    private var statusTitle: String {
        if model.startupError != nil { return String(localized: "Amai 无法启动") }
        switch model.status?.state {
        case .running, .error: return String(localized: "Amai 正在记录")
        case .paused: return String(localized: "Amai 已暂停记录")
        case .permissionMissing: return String(localized: "Amai 等待屏幕录制权限")
        case .stopped: return String(localized: "Amai 未在记录")
        case nil: return String(localized: "Amai 正在启动…")
        }
    }

    /// 暂停期间仍保留时间线上的"已暂停"占位；真正停止只在退出时发生。
    @ViewBuilder
    private var recordingControl: some View {
        switch model.status?.state {
        case .stopped:
            Button("开始记录") { model.start() }
        case .paused:
            Button("继续记录") { model.resume() }
        case .running, .error, .permissionMissing:
            Button("暂停记录") { model.pause() }
        case nil:
            Button("暂停记录") {}.disabled(true)
        }
    }

    private func perform(_ action: AppIssue.Action) {
        switch action {
        case .grantScreenRecording: model.requestScreenRecording()
        case .openSettings: showSettings()
        case .openLocalModels: showSettings(tab: .model)
        case .openStatus: showSettings(tab: .status)
        case .revealConfig: model.revealConfig()
        case .relaunch: model.relaunch()
        }
    }

    /// 主窗口，每次从菜单打开都回到「综合」；打开记忆文件夹的入口在窗口工具栏与设置里。
    private func showMain() {
        model.memoryBrowser.showDefault()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOnboarding() {
        openWindow(id: "onboarding")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings(tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey) }
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

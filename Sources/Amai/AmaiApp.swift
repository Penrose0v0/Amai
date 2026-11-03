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
        }
        .defaultSize(width: 1100, height: 720)
        // 隔离预览模式（--memory-preview）启动后直接打开主窗口。
        .defaultLaunchBehavior(model.isMemoryPreview ? .presented : .automatic)

        Settings {
            // 预览模式不显示真实设置：模型设置页会读写钥匙串中的 API Key。
            if model.isMemoryPreview {
                Text("记忆预览模式下没有设置。")
                    .foregroundStyle(.secondary)
                    .frame(width: 360, height: 120)
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
        if model.startupError != nil { return "Amai 无法启动" }
        switch model.status?.state {
        case .running, .error: return "Amai 正在记录"
        case .paused: return "Amai 已暂停记录"
        case .permissionMissing: return "Amai 等待屏幕录制权限"
        case .stopped: return "Amai 未在记录"
        case nil: return "Amai 正在启动…"
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

    private func showSettings(tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey) }
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

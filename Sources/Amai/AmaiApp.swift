import AmaiCore
import AmaiExtraction
import AmaiPerception
import SwiftUI

/// 菜单栏应用入口（docs/architecture.md §2.4）。
///
/// 菜单面向普通用户，只保留：状态与上次记忆更新时间、暂停 / 继续、打开记忆、立即同步、
/// 活动检查器、设置、退出。详细指标在活动检查器的"运行状态"里，维护操作在设置的"高级"里。
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

        Window("活动检查器", id: "inspector") {
            InspectorView(model: model)
        }

        Settings {
            SettingsView(model: model)
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
        Text(statusTitle)
        if let updated = model.lastMemoryUpdate {
            Text("记忆更新于 \(updated.formatted(.relative(presentation: .named)))")
        }

        let issues = model.issues
        if !issues.isEmpty {
            Divider()
            ForEach(issues) { issue in
                Text("⚠︎ \(issue.message)")
                if let action = issue.action {
                    Button(action.title) { perform(action) }
                }
            }
        }

        Divider()
        recordingControl

        Divider()
        Button("打开记忆") { model.openMemoryFolder() }
        Button("立即同步") { model.syncNow() }

        Divider()
        Button("活动检查器…") { showInspector() }
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
        case .openInspector: showInspector()
        case .revealConfig: model.revealConfig()
        }
    }

    private func showInspector() {
        openWindow(id: "inspector")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

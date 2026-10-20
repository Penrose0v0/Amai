import AmaiCore
import AmaiPerception
import SwiftUI

/// 菜单栏应用入口（docs/architecture.md §2.4）。
@main
struct AmaiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: Self.symbol(for: model.status))
        }
    }

    private static func symbol(for status: PerceptionStatus?) -> String {
        switch status?.state {
        case .running: "record.circle"
        case .paused: "pause.circle"
        case .permissionMissing: "exclamationmark.triangle"
        case .error: "xmark.circle"
        case .stopped, nil: "circle.dotted"
        }
    }
}

private struct MenuContent: View {
    let model: AppModel

    var body: some View {
        if let error = model.startupError {
            Text(error)
        } else if let status = model.status {
            statusSection(status)
            Divider()
            controls(status)
            Divider()
        } else {
            Text("Amai · 初始化中")
            Divider()
        }

        if let warning = model.configWarning {
            Text(warning)
            Divider()
        }

        Button("打开原始数据目录") { model.revealRawFolder() }
        Button("打开配置文件") { model.revealConfig() }
        Divider()
        Button("退出 Amai") { model.quit() }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func statusSection(_ status: PerceptionStatus) -> some View {
        Text("Amai · \(label(for: status))")
        if status.state != .stopped {
            Text("已截图 \(status.screen.captured) · 重复 \(status.screen.duplicates) · 跳过 \(status.screen.skipped) · 失败 \(status.screen.failures)")
            Text("焦点切换 \(status.focusChanges) · 缓冲 \(Self.formatBytes(status.spoolBytes))")
            Text("档位 \(status.powerProfile.rawValue) · 间隔 \(Self.formatInterval(status.effectiveInterval))")
            if status.systemBlocked {
                Text("系统睡眠 / 锁屏，暂不截图")
            }
            if let error = status.screen.lastError {
                Text("上次错误：\(String(describing: error))")
            }
        }
    }

    @ViewBuilder
    private func controls(_ status: PerceptionStatus) -> some View {
        // 只有"开始 / 暂停 / 继续"：暂停期间监听器保持运行，只是不截图并留占位。
        // 完全停止只在退出应用时发生。
        switch status.state {
        case .stopped:
            Button("开始采集") { model.start() }
        case .running, .error:
            Button("暂停采集") { model.pause() }
        case .paused:
            Button("继续采集") { model.resume() }
        case .permissionMissing:
            Button("申请屏幕录制权限") { model.requestScreenRecording() }
            Button("打开系统设置") { model.openSystemSettings() }
            Button("暂停采集") { model.pause() }
        }
    }

    private func label(for status: PerceptionStatus) -> String {
        switch status.state {
        case .stopped: "未采集"
        case .running: "采集中"
        case .paused: "已暂停"
        case .permissionMissing: "缺少屏幕录制权限"
        case .error: "采集出错"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func formatInterval(_ seconds: TimeInterval) -> String {
        seconds.isFinite ? "\(Int(seconds)) 秒" : "暂停"
    }
}

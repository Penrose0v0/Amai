import AmaiCore
import AmaiPerception
import SwiftUI

/// 原生"设置"窗口（⌘,）：通用、记忆整理模型、高级。
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            ModelSettingsView(model: model)
                .tabItem { Label("记忆整理", systemImage: "brain") }
            AdvancedSettingsView(model: model)
                .tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 580)
    }
}

private struct GeneralSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("记录") {
                LabeledContent("状态", value: stateText)
                switch model.status?.state {
                case .paused:
                    Button("继续记录") { model.resume() }
                case .stopped:
                    Button("开始记录") { model.start() }
                default:
                    Button("暂停记录") { model.pause() }
                }
                Text("Amai 定时截取屏幕并在本机整理成活动记录。原始截图只保留很短时间，之后自动删除。密码输入和你排除的应用不会被记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("记忆") {
                LabeledContent("位置", value: model.memoryRoot.path)
                if let updated = model.lastMemoryUpdate {
                    LabeledContent("上次更新", value: updated.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("整理方式", value: model.consolidationModelLabel)
                Button("打开记忆") { model.openMemoryFolder() }
            }
        }
        .formStyle(.grouped)
    }

    private var stateText: String {
        switch model.status?.state {
        case .running: "正在记录"
        case .paused: "已暂停"
        case .permissionMissing: "缺少屏幕录制权限"
        case .error: "截图出错，正在重试"
        case .stopped: "未在记录"
        case nil: "正在启动"
        }
    }
}

/// 高级：维护操作与文件入口。这些操作平时由 Amai 自动完成。
private struct AdvancedSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Button("立即处理积压的屏幕活动") { model.runExtractionNow() }
                Button("立即同步记忆") { model.syncMemoryNow() }
                Button("整理今天（日终摘要与 work 专题）") { model.consolidateToday() }
                Button("更新长期记忆（summary）") { model.updateSummaryNow() }
                if model.consolidationModel.mode == .chatgptPlan {
                    Button("Manage usage") { model.openChatGPTUsage() }
                }
            } header: {
                Text("手动维护")
            } footer: {
                Text("这些操作平时会自动进行：屏幕活动每分钟处理一次，记忆每分钟同步一次，日终摘要在凌晨 4 点后生成，summary 每周更新。")
            }

            Section("权限") {
                Button("申请屏幕录制权限") { model.requestScreenRecording() }
                Button("打开系统设置中的屏幕录制") { model.openSystemSettings() }
            }

            Section("文件") {
                Button("打开记忆目录") { model.openMemoryFolder() }
                Button("显示原始数据目录") { model.revealRawFolder() }
                Button("显示配置文件") { model.revealConfig() }
            }
        }
        .formStyle(.grouped)
    }
}

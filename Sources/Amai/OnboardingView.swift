import enum AmaiCore.MemoryLanguage
import enum AmaiPerception.ScreenRecordingPermission
import Observation
import SwiftUI

/// 首次启动引导（参考 Eira 的引导）：语言 → 会记录什么 → 屏幕录制权限 → 本地模型 → 开始记录。
///
/// - 引导完成前不采集任何内容；最后一页点"开始记录"才开始。
/// - 界面语言在引导内立即切换（通过环境中的 locale），其他窗口在重启后跟随。
/// - 新授予的屏幕录制权限与新的界面语言都要重启 Amai 才完全生效，需要时在完成时自动重启。
@MainActor
@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable {
        case welcome, privacy, permission, model, done
    }

    var step: Step = .welcome
    var screenRecordingGranted = ScreenRecordingPermission.isGranted()

    func next() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }
}

struct OnboardingView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    private var state: OnboardingState { model.onboarding }

    /// 让引导中的文字随所选界面语言立即切换。
    private var locale: Locale {
        model.interfaceLanguage == .system ? .current : Locale(identifier: model.interfaceLanguage.rawValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 14)
                .padding(.horizontal, 28)

            Group {
                switch state.step {
                case .welcome: WelcomePage(model: model)
                case .privacy: PrivacyPage(model: model)
                case .permission: PermissionPage(model: model)
                case .model: ModelPage(model: model)
                case .done: DonePage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.top, 20)

            footer
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
        }
        .frame(width: 580, height: 520)
        .environment(\.locale, locale)
        // 菜单栏应用默认不在前台，引导窗口打开时要主动激活。
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .task {
            // 用户常在系统设置里授权后切回来，状态应当自己更新（不触发系统弹窗）。
            while !Task.isCancelled {
                state.screenRecordingGranted = ScreenRecordingPermission.isGranted()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingState.Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= state.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 3)
            }
        }
    }

    private var footer: some View {
        HStack {
            if state.step != .welcome {
                Button("上一步") { state.back() }
            }
            Spacer()
            if state.step == .done {
                Button(model.onboardingNeedsRelaunch ? "开始记录并重新启动" : "开始记录") {
                    model.finishOnboarding()
                    dismissWindow(id: "onboarding")
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("下一步") { state.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Pages

/// 每页统一的标题与说明。
private struct PageHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}

private struct WelcomePage: View {
    let model: AppModel
    @State private var memoryLanguageMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                title: "欢迎使用 Amai",
                subtitle: "Amai 在后台记下你在电脑上做的事，并在本机整理成可以随时查看的时间线和长期记忆。"
            )

            Form {
                Section {
                    Picker("界面语言", selection: Binding(
                        get: { model.interfaceLanguage },
                        set: { model.interfaceLanguage = $0 }
                    )) {
                        ForEach(AppModel.InterfaceLanguage.allCases, id: \.self) { language in
                            if language == .system {
                                Text("跟随系统").tag(language)
                            } else {
                                Text(verbatim: language.title).tag(language)
                            }
                        }
                    }
                    // 预览版与正式版共用偏好域，预览中不改界面语言。
                    .disabled(model.isMemoryPreview)
                    Picker("记忆语言", selection: Binding(
                        get: { model.memoryLanguage },
                        set: { memoryLanguageMessage = model.setMemoryLanguage($0) }
                    )) {
                        ForEach(MemoryLanguage.allCases, id: \.self) { Text(verbatim: $0.nativeName).tag($0) }
                    }
                    if let memoryLanguageMessage {
                        Text(memoryLanguageMessage).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("记忆语言是 Amai 写入记忆时使用的语言，之后可以在设置中修改。")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }
}

private struct PrivacyPage: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Amai 会记录什么", subtitle: "默认所有处理都在这台 Mac 上进行。你可以随时暂停记录。")
            VStack(alignment: .leading, spacing: 14) {
                row("rectangle.on.rectangle", "屏幕", "每 \(Int(model.perceptionConfiguration.screen.interval)) 秒截一次图，由本机模型理解后生成活动记录。原始截图最多保留 \(Int(model.perceptionConfiguration.spool.maxAge / 3600)) 小时。")
                row("lock", "不会记录", "输入密码时、密码管理器等被排除的应用、暂停期间。")
                row("doc.text", "记忆", "保存为 Markdown 文件，你可以直接阅读、修改或删除。")
                row("icloud.slash", "云端", "默认全部在本机处理。只有你在设置中选择云端整理模型后，才会把活动记录与记忆的文字发送给所选服务；截图始终只在本机处理。")
            }
            Spacer()
        }
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionPage: View {
    let model: AppModel

    private var granted: Bool { model.onboarding.screenRecordingGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "授权屏幕录制", subtitle: "Amai 需要屏幕录制权限才能看到屏幕上的内容。可以随时在系统设置中撤销。")
            Form {
                Section {
                    LabeledContent {
                        HStack(spacing: 10) {
                            if granted {
                                Text("已授权").foregroundStyle(.secondary)
                            } else {
                                Button("授权") { model.requestScreenRecording() }
                                    .buttonStyle(.borderedProminent)
                                Button("系统设置…") { model.openSystemSettings() }
                            }
                        }
                    } label: {
                        Label {
                            Text("屏幕录制")
                        } icon: {
                            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(granted ? Color.green : Color.orange)
                        }
                    }
                } footer: {
                    Text(granted
                         ? "已经可以开始记录。"
                         : "在系统设置中打开 Amai 的开关后回到这里。系统可能提示需要重新打开 Amai，可以选择「稍后」，完成引导时 Amai 会自动重新启动。")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Spacer()
        }
    }
}

private struct ModelPage: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageHeader(title: "选择本地模型", subtitle: "本地模型把截图理解成活动记录，始终在本机运行。下载后才能使用，大模型需要几分钟。")
            Form {
                LocalModelSection(model: model)
                if !model.selectedModelInstalled {
                    Section {
                        Label("还没有下载所选模型。不下载也可以开始记录，但下载完成之前不会生成活动记录。", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct DonePage: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "准备好了", subtitle: "Amai 住在菜单栏里，开始记录后会在后台安静运行。")
            VStack(alignment: .leading, spacing: 14) {
                row("menubar.rectangle", "菜单栏", "点 Amai 图标可以暂停或继续记录、打开 Amai、进入设置。")
                row("clock", "时间线与每日总结", "打开 Amai 查看每天做了什么。活动整理会在记录开始几分钟后出现。")
                row("brain", "长期记忆", "每天凌晨 4 点后，Amai 会把前一天的记录整理进综合、工作、健康、财务、目标五个分区。")
            }
            if model.onboardingNeedsRelaunch {
                Label("为了让刚才的设置生效，Amai 会重新启动一次。", systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            Spacer()
        }
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

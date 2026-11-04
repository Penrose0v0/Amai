import AmaiExtraction
import SwiftUI

/// 本地模型设置：屏幕抽取（以及选择"本地"时的记忆整理）使用的 VLM。按本机内存给出推荐，
/// 未安装的模型可以在这里下载。模型在启动时加载，改选后重启生效。
struct LocalModelSettingsView: View {
    let model: AppModel

    @State private var installed: Set<String> = []
    @State private var message: String?

    private let recommended = LocalModelCatalog.recommended()

    var body: some View {
        Form {
            Section {
                ForEach(LocalModelCatalog.all) { option in
                    row(option)
                }
            } header: {
                Text("屏幕理解模型")
            } footer: {
                Text("本机内存约 \(LocalModelCatalog.machineMemoryGB) GB，推荐 \(recommended.displayName)：Amai 长期在后台运行，推荐常驻内存不超过本机三分之一的模型。模型始终在本机运行，截图与屏幕文字不会离开这台 Mac；下载只连接 Hugging Face。")
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message {
                Text(message).font(.callout)
            }

            if model.selectedModelTag != model.modelTag {
                Section {
                    HStack {
                        Text("已选择 \(name(model.selectedModelTag))，重新启动 Amai 后生效。")
                        Spacer()
                        Button("立即重启") { model.relaunch() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model.installedModelsVersion) {
            installed = Set(LocalModelCatalog.all.map(\.tag).filter { LocalInferenceBackend.isInstalled(tag: $0) })
        }
    }

    private func row(_ option: LocalModelOption) -> some View {
        let isInstalled = installed.contains(option.tag)
        let isSelected = model.selectedModelTag == option.tag
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.displayName).fontWeight(.medium)
                    if option == recommended { badge("推荐", .green) }
                    if !option.verified { badge("未验证", .secondary) }
                    if model.modelTag == option.tag { badge("运行中", .accentColor) }
                }
                HStack(spacing: 4) {
                    Text("下载约 \(option.diskGB) GB ·")
                    if option.memoryGB > LocalModelCatalog.machineMemoryGB {
                        Label("占约 \(option.memoryGB) GB 内存", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("需要约 \(option.memoryGB) GB，但本机只有约 \(LocalModelCatalog.machineMemoryGB) GB，加载时可能内存不足。")
                    } else {
                        Text("占约 \(option.memoryGB) GB 内存")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = model.modelDownloadErrors[option.tag] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            action(option, installed: isInstalled)
        }
        .contentShape(Rectangle())
        .opacity(isInstalled || model.modelDownloads[option.tag] != nil ? 1 : 0.7)
        .onTapGesture { select(option, installed: isInstalled) }
        .help(option.verified ? option.tag : "\(option.tag)\n尚未在 Amai 中验证抽取效果，可以使用，但结果可能不如已验证的模型。")
    }

    @ViewBuilder
    private func action(_ option: LocalModelOption, installed: Bool) -> some View {
        if let progress = model.modelDownloads[option.tag] {
            HStack(spacing: 6) {
                if let progress {
                    ProgressView(value: progress).frame(width: 80)
                    Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).frame(width: 32, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small)
                    Text("准备中").font(.caption)
                }
                Button("取消") { model.cancelLocalModelDownload(option.tag) }
                    .controlSize(.small)
            }
        } else if installed {
            Text("已安装").font(.caption).foregroundStyle(.secondary)
        } else {
            Button("下载") { model.downloadLocalModel(option.tag) }
                .controlSize(.small)
                .disabled(model.isMemoryPreview)
        }
    }

    private func select(_ option: LocalModelOption, installed: Bool) {
        guard model.selectedModelTag != option.tag else { return }
        guard installed else {
            message = "请先下载 \(option.displayName)。"
            return
        }
        message = model.selectLocalModel(option.tag)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func name(_ tag: String) -> String {
        LocalModelCatalog.option(for: tag)?.displayName ?? tag
    }
}

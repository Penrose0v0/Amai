import AmaiExtraction
import SwiftUI

/// 模型页的「屏幕理解」：屏幕抽取（以及选择"本地"时的记忆整理）使用的 VLM。按本机内存给出推荐，
/// 未安装的模型可以在这里下载。模型在启动时加载，改选后重启生效。
struct LocalModelSection: View {
    let model: AppModel

    @State private var installed: Set<String> = []
    @State private var message: String?

    private let recommended = LocalModelCatalog.recommended()

    var body: some View {
        Section {
            ForEach(LocalModelCatalog.all) { option in
                row(option)
            }
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
            if model.selectedModelTag != model.modelTag {
                LabeledContent("已选择 \(name(model.selectedModelTag))，重新启动后生效") {
                    Button("立即重启") { model.relaunch() }
                }
            }
        } header: {
            Text("屏幕理解")
        } footer: {
            Text("本机内存约 \(LocalModelCatalog.machineMemoryGB) GB，推荐 \(recommended.displayName)。模型只在本机运行，截图与屏幕文字不会离开这台 Mac。")
                .help("Amai 长期在后台运行，推荐常驻内存不超过本机三分之一的模型。下载只连接 Hugging Face。")
        }
        .task(id: model.installedModelsVersion) {
            installed = Set(LocalModelCatalog.all.map(\.tag).filter { LocalInferenceBackend.isInstalled(tag: $0) })
        }
    }

    /// 一行一个模型：左侧单选与名称、资源需求；右侧安装状态或下载操作。点击已安装的行即选用。
    private func row(_ option: LocalModelOption) -> some View {
        let isInstalled = installed.contains(option.tag)
        let isSelected = model.selectedModelTag == option.tag
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.displayName)
                Text(details(option))
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
        .onTapGesture { select(option, installed: isInstalled) }
        .help(option.verified ? option.tag : "\(option.tag)\n尚未在 Amai 中验证抽取效果，可以使用，但结果可能不如已验证的模型。")
    }

    /// 资源需求与标记，用一行灰色文字表示。
    private func details(_ option: LocalModelOption) -> String {
        var parts = ["下载约 \(option.diskGB) GB", "占约 \(option.memoryGB) GB 内存"]
        if option.memoryGB > LocalModelCatalog.machineMemoryGB { parts[1] += "（超过本机内存）" }
        if option == recommended { parts.append("推荐") }
        if model.modelTag == option.tag { parts.append("运行中") }
        if !option.verified { parts.append("未验证") }
        return parts.joined(separator: " · ")
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
                    Text("准备中").font(.caption).foregroundStyle(.secondary)
                }
                Button("取消") { model.cancelLocalModelDownload(option.tag) }
            }
        } else if installed {
            Text("已安装").foregroundStyle(.secondary)
        } else {
            Button("下载") { model.downloadLocalModel(option.tag) }
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

    private func name(_ tag: String) -> String {
        LocalModelCatalog.option(for: tag)?.displayName ?? tag
    }
}

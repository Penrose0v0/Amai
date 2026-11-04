import AmaiCore
import AmaiExtraction
import AmaiMemory
import AmaiPerception
import SwiftUI

/// 设置中的"运行状态"：采集、抽取、记忆、整理的详细指标。菜单里只显示简要状态。
struct RuntimeStatusView: View {
    let model: AppModel

    var body: some View {
        Form {
            if !model.issues.isEmpty {
                Section("需要注意") {
                    ForEach(model.issues) { Text($0.message).foregroundStyle(.orange) }
                }
            }
            captureSection
            extractionSection
            memorySection
            consolidationSection
        }
        .formStyle(.grouped)
    }

    // MARK: - 采集

    @ViewBuilder
    private var captureSection: some View {
        Section("屏幕采集") {
            if let s = model.status {
                LabeledContent("状态", value: label(s.state))
                LabeledContent("已截图", value: String(localized: "\(s.screen.captured)（其中画面重复 \(s.screen.duplicates)）"))
                if s.screen.displays > 0 {
                    LabeledContent("显示器", value: String(localized: "\(s.screen.displays) 块"))
                }
                LabeledContent("跳过", value: "\(s.screen.skipped)")
                    .help("暂停、密码输入、排除的应用等原因跳过的截图次数。")
                LabeledContent("失败", value: "\(s.screen.failures)")
                if let last = s.screen.lastCaptureAt {
                    LabeledContent("上次截图", value: last.formatted(date: .omitted, time: .standard))
                }
                if let error = s.screen.lastError {
                    LabeledContent("上次错误", value: String(describing: error))
                }
                LabeledContent("应用切换", value: "\(s.focusChanges)")
                LabeledContent("原始数据缓冲", value: ByteCountFormatter.string(fromByteCount: s.spoolBytes, countStyle: .file))
                LabeledContent("电源档位", value: String(localized: "\(label(s.powerProfile)) · 间隔 \(s.effectiveInterval.isFinite ? String(localized: "\(Int(s.effectiveInterval)) 秒") : "暂停")"))
                if s.systemBlocked {
                    LabeledContent("系统", value: String(localized: "睡眠或锁屏，暂不截图"))
                }
                LabeledContent("屏幕录制权限", value: s.screenRecordingGranted ? "已授权" : "未授权")
            } else {
                Text("正在启动…")
            }
        }
    }

    // MARK: - 抽取

    @ViewBuilder
    private var extractionSection: some View {
        Section("屏幕理解") {
            LabeledContent("模型", value: model.modelTag + (model.modelInstalled ? "" : String(localized: "（未安装）")))
            if let e = model.extractionStatus {
                LabeledContent("状态", value: label(e.state))
                if let until = e.processedUntil {
                    LabeledContent("已处理至", value: until.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("待处理窗口", value: "\(e.pendingBatches)")
                LabeledContent("累计", value: String(localized: "窗口 \(e.batchesProcessed) · 片段 \(e.segmentsWritten) · 描述帧 \(e.framesDescribed) · 兜底 \(e.fallbackBatches)"))
                    .help("处理的时间窗口、生成的活动片段、由模型描述的截图，以及模型失败时用元数据兜底的窗口数。")
                if let seconds = e.lastBatchSeconds {
                    LabeledContent("上一个窗口耗时", value: String(localized: "\(Int(seconds)) 秒"))
                }
                if let done = e.progressDone, let total = e.progressTotal {
                    LabeledContent("进度", value: String(localized: "帧 \(done + 1)/\(total)"))
                }
                if let error = e.lastError {
                    LabeledContent("上次错误", value: error)
                }
            }
        }
    }

    // MARK: - 记忆

    @ViewBuilder
    private var memorySection: some View {
        Section("记忆同步") {
            if let updated = model.lastMemoryUpdate {
                LabeledContent("文件上次修改", value: updated.formatted(date: .abbreviated, time: .standard))
            }
            if let m = model.memoryStatus {
                if let last = m.lastSyncAt {
                    LabeledContent("上次同步", value: last.formatted(date: .omitted, time: .standard))
                }
                LabeledContent("累计写入", value: String(localized: "日期 \(m.daysWritten) · 文件变更 \(m.filesChanged)"))
                if let error = m.lastError {
                    LabeledContent("上次错误", value: error)
                }
            }
        }
    }

    @ViewBuilder
    private var consolidationSection: some View {
        Section("记忆整理") {
            LabeledContent("整理方式", value: model.consolidationModelLabel)
            if let c = model.consolidationStatus {
                LabeledContent("状态", value: c.running ? String(localized: "整理中") : String(localized: "空闲"))
                LabeledContent("日终摘要已整理至", value: c.lastDailyDay ?? String(localized: "尚未整理"))
                LabeledContent("综合档案上次更新", value: c.lastGeneralAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "尚未更新"))
                LabeledContent("分区累计更新", value: "\(c.categoriesWritten)")
                if let error = c.lastError {
                    LabeledContent("上次错误", value: error)
                }
            }
            if model.consolidationModel.mode == .chatgptPlan, let g = model.chatGPTStatus {
                LabeledContent("ChatGPT", value: g.signedIn ? String(localized: "已登录 \(g.email ?? "")") + (g.planUsageGranted ? " · Using ChatGPT plan" : String(localized: " · 未授予套餐用量")) : String(localized: "未登录"))
            }
        }
    }

    // MARK: - Labels

    private func label(_ state: PerceptionState) -> String {
        switch state {
        case .stopped: String(localized: "未在记录")
        case .running: String(localized: "正在记录")
        case .paused: String(localized: "已暂停")
        case .permissionMissing: String(localized: "缺少屏幕录制权限")
        case .error: String(localized: "截图连续失败")
        }
    }

    private func label(_ profile: PowerProfile) -> String {
        switch profile {
        case .performance: String(localized: "高性能")
        case .balanced: String(localized: "平衡")
        case .saver: String(localized: "省电")
        case .paused: String(localized: "暂停")
        }
    }

    private func label(_ state: ExtractionState) -> String {
        switch state {
        case .idle: String(localized: "空闲")
        case .running: String(localized: "处理中")
        case .deferred: String(localized: "电池模式，暂缓处理")
        case .waitingForFrames: String(localized: "等待视频分段写完")
        case .modelUnavailable: String(localized: "本地模型不可用")
        case .retrying: String(localized: "出错，将重试")
        case .disabled: String(localized: "已关闭")
        }
    }
}

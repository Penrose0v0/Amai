import Combine
import SwiftUI

struct ContentView: View {
    let log: EventLog

    @State private var events: [PoCEvent] = []
    @State private var frames: [URL] = []
    @State private var interval = PoCStore.captureInterval
    @State private var confirmErase = false
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                if PoCStore.root == nil {
                    Section {
                        Label("读不到 App Group 容器。检查签名里的 App Group 是否与 Config 中一致。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                replayKitSection
                screenCaptureKitSection
                summarySection
                framesSection
                eventsSection
            }
            .navigationTitle("Amai 屏幕感知 PoC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清除", role: .destructive) { confirmErase = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: exportText, preview: SharePreview("amai-poc-events.jsonl")) {
                        Label("导出日志", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .confirmationDialog("删除全部截图与测量日志？", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    PoCStore.eraseAll()
                    reload()
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    // MARK: Sections

    private var replayKitSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isBroadcasting ? "正在广播" : "未在广播")
                        .font(.headline)
                        .foregroundStyle(isBroadcasting ? .red : .primary)
                    Text("点右侧按钮，在系统界面里开始或停止。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                BroadcastPicker().frame(width: 52, height: 52)
            }
            Picker("保存间隔", selection: $interval) {
                ForEach(PoCStore.allowedIntervals, id: \.self) { Text("\(Int($0)) 秒").tag($0) }
            }
            .onChange(of: interval) { _, value in PoCStore.captureInterval = value }
        } header: {
            Text("ReplayKit 广播扩展（iOS 18–26）")
        } footer: {
            Text("截图只保存在本机的 App Group 容器里，最多 \(PoCStore.maxFrames) 张、24 小时；不上传。")
        }
    }

    @ViewBuilder
    private var screenCaptureKitSection: some View {
        Section("ScreenCaptureKit（iOS 27）") {
            #if canImport(ScreenCaptureKit)
            if #available(iOS 27.0, *) {
                SCKControls(log: log)
            } else {
                Text("这台设备低于 iOS 27。").foregroundStyle(.secondary)
            }
            #else
            Text("模拟器不支持 ScreenCaptureKit，请在真机上运行。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    private var summarySection: some View {
        Section("最近一次读数") {
            if let stats = lastStats {
                row("收到的帧", stats.values["received"])
                row("保存 / 重复 / 失败", text: "\(int(stats.values["kept"])) / \(int(stats.values["duplicates"])) / \(int(stats.values["failures"]))")
                row("原始尺寸", text: "\(int(stats.values["width"])) × \(int(stats.values["height"]))")
                row("扩展内存 (MB)", stats.values["footprintMB"])
                row("距内存上限 (MB)", stats.values["availableMB"])
                row("电量", text: battery(stats.values["battery"]))
                row("热状态", stats.values["thermal"])
                row("读数时间", text: stats.date.formatted(date: .omitted, time: .standard))
            } else {
                Text("还没有读数。开始广播后每 30 秒记录一次。").foregroundStyle(.secondary)
            }
            row("帧中断次数（> 3 秒）", Double(events.filter { $0.kind == "frameGap" }.count))
        }
    }

    private var framesSection: some View {
        Section("最近保存的截图（共 \(frames.count) 张）") {
            if frames.isEmpty {
                Text("暂无").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(frames.suffix(12).reversed(), id: \.self) { url in
                            if let image = UIImage(contentsOfFile: url.path) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
        }
    }

    private var eventsSection: some View {
        Section("事件（最近 80 条）") {
            ForEach(events.suffix(80).reversed()) { event in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(event.kind).font(.subheadline.monospaced())
                        Spacer()
                        Text(event.date.formatted(date: .omitted, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let detail = describe(event)
                    if !detail.isEmpty {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Data

    private func reload() {
        events = EventLog.readAll()
        frames = PoCStore.frameFiles()
    }

    private var lastStats: PoCEvent? {
        events.last { $0.kind == "stats" || $0.kind == "broadcastFinished" || $0.kind == "sckStopped" }
    }

    /// 最后一条开始 / 结束记录是"开始"，且一分钟内还有读数，才算正在广播（扩展被系统直接终止时没有结束记录）。
    private var isBroadcasting: Bool {
        guard let last = events.last(where: { $0.kind == "broadcastStarted" || $0.kind == "broadcastFinished" }),
              last.kind == "broadcastStarted",
              let latest = events.last(where: { $0.process == "broadcast" })
        else { return false }
        return Date().timeIntervalSince(latest.date) < 60
    }

    private var exportText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return events.compactMap { (try? encoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
            .joined(separator: "\n")
    }

    private func describe(_ event: PoCEvent) -> String {
        var parts: [String] = []
        if let note = event.note { parts.append(note) }
        switch event.kind {
        case "frameGap":
            parts.append("\(event.values["seconds"] ?? 0) 秒")
        case "stats", "broadcastStarted", "broadcastFinished", "sckStarted", "sckStopped":
            parts.append("帧 \(int(event.values["received"])) 存 \(int(event.values["kept"])) 内存 \(event.values["footprintMB"] ?? 0)MB 电量 \(battery(event.values["battery"]))")
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ title: String, _ value: Double?) -> some View {
        row(title, text: value.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "—")
    }

    private func row(_ title: String, text: String) -> some View {
        LabeledContent(title, value: text)
    }

    private func int(_ value: Double?) -> Int { Int(value ?? 0) }

    private func battery(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }
}

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
private struct SCKControls: View {
    @State private var capture: SCKCapture

    init(log: EventLog) {
        _capture = State(initialValue: SCKCapture(log: log))
    }

    var body: some View {
        Button(capture.isRunning ? "停止" : "选择内容并开始") {
            capture.isRunning ? capture.stop() : capture.start()
        }
        if let error = capture.lastError {
            Text("上次结束：\(error)").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
#endif

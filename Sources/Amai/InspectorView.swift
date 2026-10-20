import AmaiCore
import AmaiExtraction
import SwiftUI

/// 最小检查器：按天查看活动片段、关联观察与关键帧，支持检索与删除。
struct InspectorView: View {
    let model: AppModel

    @State private var day = Date()
    @State private var query = ""
    @State private var segments: [ActivitySegment] = []
    @State private var selection: ActivitySegment.ID?
    @State private var searching = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                controls
                Divider()
                List(segments, selection: $selection) { segment in
                    SegmentRow(segment: segment, showDate: searching)
                        .tag(segment.id)
                }
                .overlay {
                    if segments.isEmpty {
                        ContentUnavailableView(
                            searching ? "没有匹配的片段" : "这一天还没有活动片段",
                            systemImage: searching ? "magnifyingglass" : "clock"
                        )
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            if let segment = segments.first(where: { $0.id == selection }) {
                SegmentDetail(model: model, segment: segment) {
                    Task { await reload() }
                }
                .id(segment.id)
            } else {
                ContentUnavailableView("选择一个活动片段", systemImage: "sidebar.left")
            }
        }
        .task(id: day) { await reload() }
        .task {
            // 抽取在后台持续进行，定期刷新列表。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !searching { await reload() }
            }
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                DatePicker("", selection: $day, displayedComponents: .date)
                    .labelsHidden()
                Spacer()
                Button("立即处理") { model.runExtractionNow() }
            }
            TextField("检索最近 7 天（标题、摘要、屏幕文字）", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await reload() } }
            ExtractionStatusLine(model: model)
        }
        .padding(10)
    }

    private func reload() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        searching = !q.isEmpty
        segments = searching ? await model.search(q, endingOn: day) : await model.segments(on: day)
        if let selection, !segments.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }
}

struct ExtractionStatusLine: View {
    let model: AppModel

    var body: some View {
        if let s = model.extractionStatus {
            Text(text(s))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func text(_ s: ExtractionStatus) -> String {
        var parts = [label(s.state)]
        if let done = s.progressDone, let total = s.progressTotal { parts.append("帧 \(done + 1)/\(total)") }
        if s.pendingBatches > 0 { parts.append("待处理窗口 \(s.pendingBatches)") }
        if let until = s.processedUntil {
            parts.append("已处理至 \(until.formatted(date: .omitted, time: .shortened))")
        }
        if let err = s.lastError { parts.append(err) }
        return parts.joined(separator: " · ")
    }

    private func label(_ state: ExtractionState) -> String {
        switch state {
        case .idle: "抽取空闲"
        case .running: "抽取中"
        case .deferred: "电源节流，稍后处理"
        case .waitingForFrames: "等待视频分段写完"
        case .modelUnavailable: "本地模型不可用"
        case .retrying: "处理失败，将重试"
        case .disabled: "抽取已关闭"
        }
    }
}

private struct SegmentRow: View {
    let segment: ActivitySegment
    let showDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(timeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                CategoryBadge(category: segment.category)
                if segment.provider.hasPrefix("fallback") || segment.confidence < 0.5 {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .help("低置信度：\(segment.provider)")
                }
            }
            Text(segment.title).font(.body)
            if !segment.summary.isEmpty {
                Text(segment.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var timeText: String {
        let range = "\(segment.timeRange.start.formatted(date: .omitted, time: .shortened))–\(segment.timeRange.end.formatted(date: .omitted, time: .shortened))"
        return showDate ? "\(segment.timeRange.start.formatted(date: .abbreviated, time: .omitted)) \(range)" : range
    }
}

private struct CategoryBadge: View {
    let category: ActivityCategory

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private var label: String {
        switch category {
        case .work: "工作"
        case .research: "研究"
        case .communication: "沟通"
        case .reading: "阅读"
        case .entertainment: "娱乐"
        case .idle: "空闲"
        case .other: "其他"
        }
    }
}

private struct SegmentDetail: View {
    let model: AppModel
    let segment: ActivitySegment
    let onDeleted: () -> Void

    @State private var observations: [AmaiCoreObservation] = []
    @State private var thumbnails: [Evidence: NSImage] = [:]
    @State private var confirmDelete = false
    @State private var enlarged: Evidence?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !segment.evidence.isEmpty { frames }
                observationList
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .confirmationDialog("删除这个活动片段及其观察？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                Task {
                    await model.deleteSegment(segment)
                    onDeleted()
                }
            }
        } message: {
            Text("原始截图不会立即删除，会在保留期结束后自动清理。")
        }
        .sheet(item: $enlarged) { evidence in
            VStack {
                if let image = thumbnails[evidence] {
                    Image(nsImage: image).resizable().scaledToFit()
                }
                Button("关闭") { enlarged = nil }.keyboardShortcut(.cancelAction)
            }
            .padding()
            .frame(minWidth: 800, minHeight: 520)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(segment.title).font(.title2.bold())
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            Text(segment.summary)
            HStack(spacing: 10) {
                CategoryBadge(category: segment.category)
                Text("\(segment.timeRange.start.formatted(date: .abbreviated, time: .standard)) – \(segment.timeRange.end.formatted(date: .omitted, time: .standard))")
                Text("置信度 \(segment.confidence, format: .number.precision(.fractionLength(2)))")
                Text(segment.provider)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !segment.apps.isEmpty {
                Text("应用：\(segment.apps.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("推断结果：由模型根据截图生成，可能有误。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var frames: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("关键帧（\(segment.evidence.count)）").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(segment.evidence, id: \.self) { evidence in
                        VStack(spacing: 2) {
                            Group {
                                if let image = thumbnails[evidence] {
                                    Image(nsImage: image).resizable().scaledToFit()
                                } else {
                                    Rectangle().fill(.quaternary)
                                        .overlay(Text("已过期").font(.caption2).foregroundStyle(.secondary))
                                }
                            }
                            .frame(height: 120)
                            .onTapGesture { if thumbnails[evidence] != nil { enlarged = evidence } }
                            Text(evidence.time.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var observationList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("观察（\(observations.count)）").font(.headline)
            ForEach(observations) { obs in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(obs.timeRange.start.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                        Text(obs.kind == .fact ? "事实" : "推断")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .background(obs.kind == .fact ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
                        Text(obs.attributes["app"] ?? "")
                            .font(.caption)
                        Text(obs.provider)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(obs.content.isEmpty ? "（无文字）" : obs.content)
                        .font(.callout)
                        .lineLimit(obs.kind == .fact ? 4 : nil)
                        .textSelection(.enabled)
                        .foregroundStyle(obs.content.isEmpty ? .secondary : .primary)
                }
                Divider()
            }
        }
    }

    private func load() async {
        observations = await model.observations(for: segment)
        for evidence in segment.evidence {
            if let image = await model.thumbnail(for: evidence) {
                thumbnails[evidence] = image
            }
        }
    }
}

extension Evidence: Identifiable {
    public var id: Self { self }
}

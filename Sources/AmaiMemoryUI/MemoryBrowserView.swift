// 只按需导入：AmaiCore 的 `Observation` 类型会与 @Observable 宏依赖的 Observation 模块同名冲突。
import enum AmaiCore.MemoryEntryKind
import AmaiMemory
import Observation
import SwiftUI

/// Amai 主窗口：日常回顾（时间线、每日总结）与长期记忆（五个分区）。
///
/// - 长期记忆：渲染对应 Markdown。用户手写的内容原样渲染，系统区块按小节列出条目，
///   每条带依据类型与来源日期（点开可看当天摘要、跳到当天时间线）；
/// - 每日总结：当天 daily 文件中的日终摘要与手写笔记；
/// - 时间线由 App 注入（需要抽取层的活动片段与关键帧），这个模块不依赖抽取层；
/// - 搜索覆盖五个分区与每日记录；文件在外部被修改时自动刷新。
///
/// 只读：不在这里修改记忆。
public struct MemoryBrowserView<Timeline: View>: View {
    let env: MemoryBrowserEnvironment
    @Bindable var controller: MemoryBrowserController
    let timeline: (Date) -> Timeline

    public init(env: MemoryBrowserEnvironment, controller: MemoryBrowserController, @ViewBuilder timeline: @escaping (Date) -> Timeline) {
        self.env = env
        self.controller = controller
        self.timeline = timeline
    }

    @State private var document: MemoryDocument?
    @State private var loadedAt: Date?

    public var body: some View {
        NavigationSplitView {
            List(selection: $controller.selection) {
                Section("日常回顾") {
                    Label("时间线", systemImage: "clock").tag(BrowserPage.timeline)
                    Label("每日总结", systemImage: "doc.text").tag(BrowserPage.dailySummary)
                }
                Section("长期记忆") {
                    ForEach(MemoryCategory.documents, id: \.self) { category in
                        Label(category.localizedName, systemImage: category.symbol).tag(BrowserPage.category(category))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            Group {
                if let hits = controller.hits {
                    SearchResultsView(env: env, query: controller.query, hits: hits)
                } else {
                    switch controller.selection {
                    case .timeline:
                        timeline(controller.day)
                    case .dailySummary:
                        DailySummaryView(env: env, day: controller.day)
                    case .category(let category):
                        if let document {
                            MemoryDocumentView(env: env, document: document)
                        } else {
                            ContentUnavailableView {
                                Label("还没有\(category.localizedName)记忆", systemImage: category.symbol)
                            } description: {
                                Text("Amai 会在整理每日记录后自动写入。你也可以自己创建 \(category.file ?? "") 并在里面书写。")
                            }
                        }
                    case nil:
                        ContentUnavailableView("在左侧选择要查看的内容", systemImage: "sidebar.left")
                    }
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        }
        .searchable(text: $controller.query, placement: .toolbar, prompt: "搜索记忆")
        .onSubmit(of: .search) { Task { await controller.search(env) } }
        .onChange(of: controller.query) { if controller.query.isEmpty { controller.hits = nil } }
        .toolbar {
            if controller.hits == nil, controller.selection?.isDaily == true {
                ToolbarItemGroup(placement: .navigation) {
                    DayNavigator(day: $controller.day)
                }
            }
            ToolbarItemGroup {
                Button {
                    if let url = currentFile { env.openFile(url) }
                } label: {
                    Label("在编辑器中打开", systemImage: "square.and.pencil")
                }
                .help("用默认的 Markdown 编辑器打开这个文件")
                .disabled(currentFile == nil || controller.hits != nil)

                Button {
                    env.reveal(currentFile)
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
                .help("在访达中显示记忆文件夹")
            }
        }
        .environment(controller)
        .task(id: controller.selection) { reload() }
        .task {
            // 用户可能在编辑器里修改文件；只比较修改时间，开销很小。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if case .category(let category) = controller.selection, modifiedAt(category) != loadedAt { reload() }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private var title: String {
        if controller.hits != nil { return "搜索结果" }
        switch controller.selection {
        case .timeline: return "时间线"
        case .dailySummary: return "每日总结"
        case .category(let c): return c.localizedName
        case nil: return "Amai"
        }
    }

    private var subtitle: String {
        guard controller.hits == nil, controller.selection?.isDaily == true else { return "" }
        return controller.day.formatted(.dateTime.year().month().day().weekday(.wide))
    }

    /// 工具栏"在编辑器中打开"对应的文件：分区文件，或每日总结所在的 daily 文件。
    private var currentFile: URL? {
        switch controller.selection {
        case .category: document?.url
        case .dailySummary: env.library.daily(on: controller.day)?.url
        default: nil
        }
    }

    private func reload() {
        guard case .category(let category) = controller.selection else { document = nil; return }
        document = env.library.document(category)
        loadedAt = document?.modifiedAt
    }

    private func modifiedAt(_ category: MemoryCategory) -> Date? {
        let url = env.library.url(for: category)
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

extension MemoryBrowserView where Timeline == NoTimelineView {
    /// 没有活动数据时（测试、预览）：时间线显示空状态。
    public init(env: MemoryBrowserEnvironment, initial: MemoryCategory = .general) {
        self.init(env: env, controller: MemoryBrowserController(selection: .category(initial))) { _ in NoTimelineView() }
    }
}

/// 没有活动数据时的时间线占位。
public struct NoTimelineView: View {
    public init() {}
    public var body: some View {
        ContentUnavailableView("没有活动数据", systemImage: "clock", description: Text("这里只能浏览记忆文件。"))
    }
}

/// 主窗口左侧的页面。
public enum BrowserPage: Hashable, Sendable {
    case timeline
    case dailySummary
    case category(MemoryCategory)

    var isDaily: Bool { self == .timeline || self == .dailySummary }
}

/// 主窗口的界面状态。由 App 持有，可以从外部切换页面、日期或发起搜索。
@MainActor
@Observable
public final class MemoryBrowserController {
    public var selection: BrowserPage?
    /// 时间线与每日总结显示的日期（当天 00:00）。
    public var day: Date
    public var query = ""
    /// 非 nil 时右侧显示搜索结果。
    public var hits: [MemoryHit]?
    /// 正在显示的来源弹窗（`条目文字|日期`）。
    public var presentedSource: String?
    public var historyExpanded = false

    public init(selection: BrowserPage? = .category(.general), day: Date = Date()) {
        self.selection = selection
        self.day = Calendar.current.startOfDay(for: day)
    }

    public func search(_ env: MemoryBrowserEnvironment) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { hits = nil; return }
        hits = await env.search(q)
    }

    public func clearSearch() {
        query = ""
        hits = nil
    }

    /// 跳到某天（YYYY-MM-DD）的时间线或每日总结。
    public func show(_ page: BrowserPage, dayName: String) {
        if let d = MemoryDirectory.day(ofDailyFile: "\(MemoryDirectory.dailyDirectory)/\(dayName).md", timeZone: .current) {
            day = d
        }
        presentedSource = nil
        clearSearch()
        selection = page
    }

    /// 回到默认页面：综合（从菜单打开主窗口时调用）；时间线与每日总结的日期回到今天。
    public func showDefault() {
        clearSearch()
        presentedSource = nil
        day = Calendar.current.startOfDay(for: Date())
        selection = .category(.general)
    }

    static func sourceKey(_ item: MemoryItem, _ day: String) -> String { "\(item.text)|\(day)" }
}

/// 日期切换：前一天、日期选择、后一天、今天。
struct DayNavigator: View {
    @Binding var day: Date

    var body: some View {
        HStack(spacing: 4) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .help("前一天")
            DatePicker("", selection: Binding(get: { day }, set: { day = Calendar.current.startOfDay(for: $0) }), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .help("后一天")
                .disabled(Calendar.current.isDateInToday(day))
            Button("今天") { day = Calendar.current.startOfDay(for: Date()) }
                .disabled(Calendar.current.isDateInToday(day))
        }
    }

    private func shift(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: day) { day = d }
    }
}

// MARK: - Daily summary

/// 每日总结：当天 daily 文件中的日终摘要与用户手写的笔记（时间线在"时间线"页查看）。
struct DailySummaryView: View {
    let env: MemoryBrowserEnvironment
    let day: Date
    @Environment(MemoryBrowserController.self) private var controller: MemoryBrowserController?

    var body: some View {
        let daily = env.library.daily(on: day)
        let digest = daily.flatMap { Consolidator.digestBlock.content(in: $0.markdown) }.flatMap { $0.isEmpty ? nil : $0 }
        let notes = daily.map { Self.notes($0.userMarkdown) } ?? ""
        if digest == nil && notes.isEmpty {
            ContentUnavailableView {
                Label("这一天还没有每日总结", systemImage: "doc.text")
            } description: {
                Text(Calendar.current.isDateInToday(day)
                     ? "Amai 会在第二天凌晨 4 点后整理今天的记录。"
                     : "这一天没有活动记录，或者还没有整理。")
            } actions: {
                Button("查看时间线") { controller?.selection = .timeline }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let digest {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Amai 的总结", systemImage: "sparkles")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            MarkdownView(digest)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("我的笔记").font(.headline)
                            MarkdownView(notes)
                        }
                    }
                    Button("查看当天时间线") { controller?.selection = .timeline }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// daily 文件中用户手写的部分：去掉一级标题与系统生成的小节标题。
    static func notes(_ userMarkdown: String) -> String {
        let generated: Set<String> = ["## 摘要", TimelineBlock.heading]
        return userMarkdown.components(separatedBy: "\n")
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("# ") && !generated.contains(t)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 记忆窗口与 App 之间的接口：只读的记忆库，以及检索、打开文件、在访达中显示三个操作。
public struct MemoryBrowserEnvironment: Sendable {
    public let library: MemoryLibrary
    public let search: @Sendable (String) async -> [MemoryHit]
    public let openFile: @MainActor @Sendable (URL) -> Void
    public let reveal: @MainActor @Sendable (URL?) -> Void

    public init(
        library: MemoryLibrary,
        search: @escaping @Sendable (String) async -> [MemoryHit],
        openFile: @escaping @MainActor @Sendable (URL) -> Void,
        reveal: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        self.library = library
        self.search = search
        self.openFile = openFile
        self.reveal = reveal
    }
}

// MARK: - Document

/// 一个分区文件的渲染（公开以便测试中单独渲染检查）。
public struct MemoryDocumentPage: View {
    let env: MemoryBrowserEnvironment
    let document: MemoryDocument

    public init(env: MemoryBrowserEnvironment, document: MemoryDocument) {
        self.env = env
        self.document = document
    }

    public var body: some View { MemoryDocumentView(env: env, document: document).content }
}

private struct MemoryDocumentView: View {
    let env: MemoryBrowserEnvironment
    let document: MemoryDocument
    @Environment(MemoryBrowserController.self) private var controller: MemoryBrowserController?
    @State private var localHistoryExpanded = false

    private var historyExpanded: Binding<Bool> {
        guard let controller else { return $localHistoryExpanded }
        return Binding(get: { controller.historyExpanded }, set: { controller.historyExpanded = $0 })
    }

    private var userMarkdown: String { Self.userContent(document) }
    private var current: [MemoryItem] { document.systemItems.filter { $0.section != MemorySchema.historySection } }
    private var history: [MemoryItem] { document.systemItems.filter { $0.section == MemorySchema.historySection } }

    var body: some View {
        ScrollView { content }
    }

    var content: some View {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !userMarkdown.isEmpty {
                    MarkdownView(userMarkdown)
                }
                if !current.isEmpty {
                    systemSection
                } else if userMarkdown.isEmpty {
                    Text("这个文件里还没有内容。")
                        .foregroundStyle(.secondary)
                }
                if !history.isEmpty {
                    // 不用 DisclosureGroup：它在 macOS 上会把内容额外缩进，与标题对不齐。
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { historyExpanded.wrappedValue.toggle() }
                        } label: {
                            Label("变更记录（\(history.count)）", systemImage: historyExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        if historyExpanded.wrappedValue {
                            ForEach(Array(history.reversed().enumerated()), id: \.offset) { _, item in
                                MemoryItemRow(env: env, item: item)
                            }
                            .padding(.leading, 20)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            // 宽窗口里正文居中，避免右侧留下大片空白。
            .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.category.localizedName).font(.largeTitle.bold())
            HStack(spacing: 6) {
                Text(document.path)
                if let modified = document.modifiedAt {
                    Text("·")
                    Text("更新于 \(modified.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// 系统区块：按小节列出条目。用浅色背景与用户手写部分区分。
    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Amai 整理的记忆", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.secondary)
                .help("由 Amai 根据每日记录自动维护。直接在文件中修改这部分会在下次整理时被覆盖，需要保留的内容请写在这部分之外。")
            ForEach(sections, id: \.self) { section in
                VStack(alignment: .leading, spacing: 8) {
                    if let section {
                        Text(section).font(.title3.bold())
                    }
                    ForEach(Array(current.filter { $0.section == section }.enumerated()), id: \.offset) { _, item in
                        MemoryItemRow(env: env, item: item)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sections: [String?] {
        var order: [String?] = []
        for item in current where !order.contains(item.section) { order.append(item.section) }
        return order
    }

    /// 用户手写部分：去掉系统生成的一级标题与系统区块标题（区块本身已被 MemoryLibrary 去掉）。
    static func userContent(_ document: MemoryDocument) -> String {
        var lines = document.userMarkdown.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].trimmingCharacters(in: .whitespaces) == "# \(MemorySchema.title(for: document.category))" {
            lines.remove(at: first)
        }
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == MemorySchema.blockHeading }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Item

private struct MemoryItemRow: View {
    let env: MemoryBrowserEnvironment
    let item: MemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(item.kind.label)
                    .help(item.kind.explanation)
                ForEach(item.sources, id: \.self) { day in
                    SourceButton(env: env, key: MemoryBrowserController.sourceKey(item, day), day: day)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// 来源日期：点开显示当天的日终摘要，可跳到当天时间线或打开当天的记录文件。
private struct SourceButton: View {
    let env: MemoryBrowserEnvironment
    let key: String
    let day: String
    @Environment(MemoryBrowserController.self) private var controller: MemoryBrowserController?
    @State private var localShowing = false

    private var showing: Binding<Bool> {
        guard let controller else { return $localShowing }
        return Binding(
            get: { controller.presentedSource == key },
            set: { controller.presentedSource = $0 ? key : (controller.presentedSource == key ? nil : controller.presentedSource) }
        )
    }

    var body: some View {
        Button(Self.short(day)) { showing.wrappedValue = true }
            .buttonStyle(.link)
            .help("查看 \(day) 的记录")
            .popover(isPresented: showing, arrowEdge: .bottom) {
                SourcePopover(env: env, day: day)
            }
    }

    static func short(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return day }
        return "\(m)月\(d)日"
    }
}

private struct SourcePopover: View {
    let env: MemoryBrowserEnvironment
    let day: String
    @Environment(MemoryBrowserController.self) private var controller: MemoryBrowserController?

    var body: some View {
        let date = MemoryDirectory.day(ofDailyFile: "\(MemoryDirectory.dailyDirectory)/\(day).md", timeZone: .current)
        let daily = date.flatMap { env.library.daily(on: $0) }
        VStack(alignment: .leading, spacing: 10) {
            Text(day).font(.headline)
            if let daily {
                if let digest = Consolidator.digestBlock.content(in: daily.markdown), !digest.isEmpty {
                    ScrollView { MarkdownView(digest) }
                        .frame(maxHeight: 260)
                } else {
                    Text("这一天还没有日终摘要。").foregroundStyle(.secondary)
                }
                HStack {
                    Button("查看当天时间线") { controller?.show(.timeline, dayName: day) }
                    Button("打开当天的记录") { env.openFile(daily.url) }
                }
            } else {
                Text("这一天的记录文件已不存在。").foregroundStyle(.secondary)
                Button("查看当天时间线") { controller?.show(.timeline, dayName: day) }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

// MARK: - Search

struct SearchResultsView: View {
    let env: MemoryBrowserEnvironment
    let query: String
    let hits: [MemoryHit]
    @Environment(MemoryBrowserController.self) private var controller: MemoryBrowserController?

    var body: some View {
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(Array(hits.enumerated()), id: \.offset) { _, hit in
                Button {
                    select(hit)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(location(hit))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Self.highlighted(Self.plain(hit.excerpt), query: query))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 检索摘录来自 Markdown 原文：去掉标题、加粗、链接、列表等标记，只留文字。
    static func plain(_ excerpt: String) -> String {
        var s = excerpt
        let rules: [(String, String)] = [
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"(^|\s)#{1,6}\s+"#, "$1"),
            (#"\*\*|__|`"#, ""),
            (#"(^|\s)[-*+]\s+"#, "$1· "),
            (#"^·\s*"#, ""),
            (#"\s{2,}"#, " "),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 命中的关键词加粗。
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return result }
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let range = result[searchStart...].range(of: q, options: .caseInsensitive) {
            result[range].inlinePresentationIntent = .stronglyEmphasized
            result[range].foregroundColor = .accentColor
            searchStart = range.upperBound
        }
        return result
    }

    private func location(_ hit: MemoryHit) -> String {
        let place: String
        switch hit.category {
        case .daily:
            place = "每日记录 · " + hit.file.dropFirst(MemoryDirectory.dailyDirectory.count + 1).replacingOccurrences(of: ".md", with: "")
        case let c?:
            place = c.localizedName
        case nil:
            place = hit.file
        }
        return hit.heading.isEmpty ? place : "\(place) · \(hit.heading)"
    }

    /// 分区命中：切换到该分区；每日记录或其他文件：用编辑器打开。
    /// 分区命中：切换到该分区；每日记录：跳到当天的时间线（命中时间线）或每日总结；其他文件：用编辑器打开。
    private func select(_ hit: MemoryHit) {
        switch hit.category {
        case .daily:
            let name = String(hit.file.dropFirst(MemoryDirectory.dailyDirectory.count + 1).dropLast(3))
            controller?.show(hit.heading == "时间线" ? .timeline : .dailySummary, dayName: name)
        case let c?:
            controller?.clearSearch()
            controller?.selection = .category(c)
        case nil:
            env.openFile(env.library.root.appendingPathComponent(hit.file))
        }
    }
}

// MARK: - Labels

extension MemoryCategory {
    var symbol: String {
        switch self {
        case .general: "person.crop.circle"
        case .work: "briefcase"
        case .health: "heart"
        case .finance: "banknote"
        case .goals: "target"
        case .daily: "calendar"
        }
    }
}

extension MemoryEntryKind {
    var label: String {
        switch self {
        case .stated: "你说过"
        case .confirmed: "你确认过"
        case .observed: "观察到"
        case .inferred: "推断"
        case .unknown: "依据未记录"
        }
    }

    var explanation: String {
        switch self {
        case .stated: "来自你自己写下的内容"
        case .confirmed: "你明确确认过这条信息"
        case .observed: "有直接的采集记录支持，例如使用了哪个应用"
        case .inferred: "Amai 根据屏幕活动推断，可能不准确"
        case .unknown: "较早整理的记忆，当时没有记录依据类型"
        }
    }
}

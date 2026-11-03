import AmaiCore
import AmaiMemory
import SwiftUI

/// 记忆窗口：浏览 Amai 整理的长期记忆（docs/memory.md §3.5）。
///
/// - 左侧五个分区，右侧渲染对应的 Markdown：用户手写的内容原样渲染，系统区块按小节列出条目，
///   每条带依据类型与来源日期（点开可看当天摘要、打开当天记录）；
/// - 搜索覆盖五个分区与每日记录；
/// - 文件在外部被修改时自动刷新（窗口打开期间每 2 秒检查一次修改时间）。
///
/// 只读：不在这里修改记忆。与活动检查器（时间线、片段）相互独立。
public struct MemoryBrowserView: View {
    let env: MemoryBrowserEnvironment

    public init(env: MemoryBrowserEnvironment, initial: MemoryCategory = .general) {
        self.env = env
        _selection = State(initialValue: initial)
    }

    @State private var selection: MemoryCategory?
    @State private var document: MemoryDocument?
    @State private var loadedAt: Date?
    @State private var query = ""
    @State private var hits: [MemoryHit]?
    @State private var searching = false

    public var body: some View {
        NavigationSplitView {
            List(MemoryCategory.documents, id: \.self, selection: $selection) { category in
                Label(category.localizedName, systemImage: category.symbol)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            Group {
                if let hits {
                    SearchResultsView(env: env, query: query, hits: hits) { category in
                        clearSearch()
                        selection = category
                    }
                } else if let category = selection {
                    if let document {
                        MemoryDocumentView(env: env, document: document)
                    } else {
                        ContentUnavailableView {
                            Label("还没有\(category.localizedName)记忆", systemImage: category.symbol)
                        } description: {
                            Text("Amai 会在整理每日记录后自动写入。你也可以自己创建 \(category.file ?? "") 并在里面书写。")
                        }
                    }
                } else {
                    ContentUnavailableView("选择一个分区", systemImage: "sidebar.left")
                }
            }
            .navigationTitle(hits != nil ? "搜索结果" : (selection?.localizedName ?? "记忆"))
        }
        .searchable(text: $query, placement: .toolbar, prompt: "搜索记忆")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { if query.isEmpty { hits = nil } }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    if let url = document?.url { env.openFile(url) }
                } label: {
                    Label("在编辑器中打开", systemImage: "square.and.pencil")
                }
                .help("用默认的 Markdown 编辑器打开这个文件")
                .disabled(document == nil || hits != nil)

                Button {
                    env.reveal(document?.url)
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
                .help("在访达中显示记忆文件夹")
            }
        }
        .task(id: selection) { reload() }
        .task {
            // 用户可能在编辑器里修改文件；只比较修改时间，开销很小。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if let category = selection, modifiedAt(category) != loadedAt { reload() }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    private func reload() {
        guard let category = selection else { document = nil; return }
        document = env.library.document(category)
        loadedAt = document?.modifiedAt
    }

    private func modifiedAt(_ category: MemoryCategory) -> Date? {
        let url = env.library.url(for: category)
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { hits = nil; return }
        searching = true
        hits = await env.search(q)
        searching = false
    }

    private func clearSearch() {
        query = ""
        hits = nil
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
                    DisclosureGroup("变更记录（\(history.count)）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(history.reversed().enumerated()), id: \.offset) { _, item in
                                MemoryItemRow(env: env, item: item)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    SourceButton(env: env, day: day)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// 来源日期：点开显示当天的日终摘要，可打开当天的记录文件。
private struct SourceButton: View {
    let env: MemoryBrowserEnvironment
    let day: String
    @State private var showing = false

    var body: some View {
        Button(Self.short(day)) { showing = true }
            .buttonStyle(.link)
            .help("查看 \(day) 的记录")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
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
                Button("打开当天的记录") { env.openFile(daily.url) }
            } else {
                Text("这一天的记录文件已不存在。").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

// MARK: - Search

private struct SearchResultsView: View {
    let env: MemoryBrowserEnvironment
    let query: String
    let hits: [MemoryHit]
    let open: (MemoryCategory) -> Void

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
                        Text(hit.excerpt)
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
    private func select(_ hit: MemoryHit) {
        if let c = hit.category, c != .daily {
            open(c)
        } else {
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

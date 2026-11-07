import AmaiCore
import Foundation

/// 外部读取记忆的授权：哪些分区可读。所有 `MemoryAPI` 调用先经过它，未授权的分区既不能读也不会出现在搜索结果中。
public struct MemoryAccess: Sendable, Equatable {
    public let categories: Set<MemoryCategory>

    public init(categories: Set<MemoryCategory>) {
        self.categories = categories
    }

    public static let all = MemoryAccess(categories: Set(MemoryCategory.allCases))

    public func allows(_ category: MemoryCategory) -> Bool { categories.contains(category) }
}

/// `config.json` 中的 `mcp` 配置（ADR-0008）。默认关闭；启用后只开放综合、工作、目标，
/// daily（时间线）、健康、财务要用户自己加入 `categories`。
public struct MCPConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var categories: [MemoryCategory]

    public static let defaultCategories: [MemoryCategory] = [.general, .work, .goals]
    public static let `default` = MCPConfiguration(enabled: false, categories: defaultCategories)

    public init(enabled: Bool, categories: [MemoryCategory]) {
        self.enabled = enabled
        self.categories = categories
    }

    public var access: MemoryAccess { MemoryAccess(categories: Set(categories)) }

    private enum CodingKeys: String, CodingKey { case enabled, categories }

    /// 缺字段补默认值；不认识的分区名忽略，不让一处拼写错误导致整个配置失效。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let names = try c.decodeIfPresent([String].self, forKey: .categories)
        categories = names.map { $0.compactMap(MemoryCategory.init(rawValue:)) } ?? Self.defaultCategories
    }
}

public enum MemoryAPIError: Error, Equatable, CustomStringConvertible {
    case notAllowed(MemoryCategory)
    case notADocument(MemoryCategory)
    case invalidDate(String)

    public var description: String {
        switch self {
        case .notAllowed(let c): "Access to the \(c.rawValue) category is not enabled. The user can add it to mcp.categories in Amai's config.json."
        case .notADocument: "daily is not a long-term memory category; use get_timeline for a day's activity."
        case .invalidDate(let s): "Invalid date \"\(s)\". Use YYYY-MM-DD, today or yesterday."
        }
    }
}

// MARK: - Results

/// 一条检索结果。`sources` 为来源日期（对应 daily 文件）；`kind` 为依据类型（观察 / 陈述 / 推断 / 确认）。
public struct MemorySearchResult: Codable, Sendable, Equatable {
    public let category: MemoryCategory
    public let file: String
    public let section: String
    public let content: String
    /// 内容对应的日期（YYYY-MM-DD）：daily 为当天，长期记忆为最近的来源日期；未知时为 nil。
    public let date: String?
    public let sources: [String]
    public let kind: MemoryEntryKind?
}

public struct MemoryEntryView: Codable, Sendable, Equatable {
    public let text: String
    public let sources: [String]
    public let kind: MemoryEntryKind
    /// 结构化字段（金额、币种、日期等），没有时为空。
    public let attributes: [String: String]
}

public struct MemorySectionView: Codable, Sendable, Equatable {
    public let name: String
    public let entries: [MemoryEntryView]
}

/// 一个长期记忆分区。`sections` 来自 Amai 整理的系统区块；`userNotes` 是用户在区块外手写的内容（原样）。
public struct CategoryMemory: Codable, Sendable, Equatable {
    public let category: MemoryCategory
    public let file: String
    public let updatedAt: Date?
    public let topic: String?
    public let sections: [MemorySectionView]
    public let userNotes: String
    /// 可用的专题（小节名），供调用方选择 `topic`。
    public let topics: [String]
}

/// 时间线中的一个活动片段。均为模型根据屏幕活动的推断。
public struct TimelineEntry: Codable, Sendable, Equatable {
    public let start: String
    public let end: String
    public let title: String
    public let summary: String
    public let confidence: Double?
    public let lowConfidence: Bool
}

public struct DayTimeline: Codable, Sendable, Equatable {
    public let date: String
    /// 当天是否有 daily 文件。
    public let exists: Bool
    public let entries: [TimelineEntry]
    /// 日终摘要（第二天凌晨整理后才有）。
    public let summary: String?
    /// 用户在系统区块外手写的内容。
    public let userNotes: String
}

// MARK: - API

/// 记忆的统一只读 API（ADR-0008）：MCP Server 与今后内置的 Eira Assistant 共用。
///
/// - 建立在 `MemoryLibrary`（读 Markdown 原文）与 `MemoryIndex`（派生的全文索引）之上，不另存任何数据；
/// - 只读：不写记忆文件，不触发同步或整理；
/// - 每个调用先按 `MemoryAccess` 检查分区授权。
public struct MemoryAPI: Sendable {
    public let library: MemoryLibrary
    public let access: MemoryAccess
    private let index: MemoryIndex?
    private let timeZone: TimeZone

    public static let maxSearchLimit = 50

    public init(root: URL, index: MemoryIndex?, access: MemoryAccess, timeZone: TimeZone = .current) {
        self.library = MemoryLibrary(root: root, index: index, timeZone: timeZone)
        self.index = index
        self.access = access
        self.timeZone = timeZone
    }

    /// 在已授权的分区中检索。长期记忆的命中展开为具体条目（带来源日期与依据），其余返回 section 摘录。
    public func search(_ query: String, limit: Int = 10) async throws -> [MemorySearchResult] {
        let limit = min(max(limit, 1), Self.maxSearchLimit)
        guard let index, !access.categories.isEmpty else { return [] }
        try await index.refresh()
        let hits = try await index.retrieve(query, categories: access.categories, limit: limit)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var documents: [MemoryCategory: MemoryDocument] = [:]
        var results: [MemorySearchResult] = []
        for hit in hits {
            guard let category = hit.category, access.allows(category) else { continue }
            let day = hit.day.map { MemoryDirectory.dayName(for: $0, timeZone: timeZone) }
            if category != .daily {
                if documents[category] == nil { documents[category] = library.document(category) }
                let items = documents[category]?.systemItems.filter { $0.text.range(of: q, options: .caseInsensitive) != nil } ?? []
                if !items.isEmpty {
                    for item in items where !results.contains(where: { $0.file == hit.file && $0.content == item.text }) {
                        results.append(MemorySearchResult(
                            category: category, file: hit.file, section: item.section ?? hit.heading,
                            content: item.text, date: item.sources.max(), sources: item.sources, kind: item.kind
                        ))
                    }
                    continue
                }
            }
            results.append(MemorySearchResult(
                category: category, file: hit.file, section: hit.heading, content: hit.excerpt,
                date: day, sources: day.map { [$0] } ?? [], kind: nil
            ))
        }
        return Array(results.prefix(limit))
    }

    /// 读取一个长期记忆分区；给出 `topic` 时只返回对应小节（任一语言的推荐小节名都可以，也接受部分匹配，如项目名）。
    public func memory(_ category: MemoryCategory, topic: String? = nil) throws -> CategoryMemory? {
        guard category != .daily else { throw MemoryAPIError.notADocument(category) }
        guard access.allows(category) else { throw MemoryAPIError.notAllowed(category) }
        guard let doc = library.document(category) else { return nil }
        let policy = CategoryPolicy.policy(for: category)
        let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        var order: [String] = []
        var grouped: [String: [MemoryEntryView]] = [:]
        for item in doc.systemItems {
            let name = item.section ?? ""
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(MemoryEntryView(
                text: item.text, sources: item.sources, kind: item.kind, attributes: item.attributes
            ))
        }
        func matches(_ name: String) -> Bool {
            guard let topic else { return true }
            if policy.localize(name) == policy.localize(topic) { return true }
            return name.range(of: topic, options: .caseInsensitive) != nil
        }
        let sections = order.filter(matches).map { MemorySectionView(name: $0, entries: grouped[$0] ?? []) }

        var notes = doc.userMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if topic != nil {
            notes = MarkdownSections.parse(doc.userMarkdown)
                .filter { !$0.heading.isEmpty && matches($0.heading) }
                .map { "## \($0.heading)\n\n\($0.content)" }
                .joined(separator: "\n\n")
        }
        return CategoryMemory(
            category: category, file: doc.path, updatedAt: doc.modifiedAt, topic: topic,
            sections: sections, userNotes: notes, topics: order.filter { !$0.isEmpty }
        )
    }

    /// 某天的活动时间线（daily 文件中的时间线区块与日终摘要）。需要 daily 授权。
    public func timeline(on date: String) throws -> DayTimeline {
        guard access.allows(.daily) else { throw MemoryAPIError.notAllowed(.daily) }
        guard let day = resolveDay(date) else { throw MemoryAPIError.invalidDate(date) }
        let name = MemoryDirectory.dayName(for: day, timeZone: timeZone)
        guard let doc = library.daily(on: day) else {
            return DayTimeline(date: name, exists: false, entries: [], summary: nil, userNotes: "")
        }
        let entries = TimelineBlock.block.content(in: doc.markdown).map(Self.parseTimeline) ?? []
        let summary = Consolidator.digestBlock.content(in: doc.markdown)?.nilIfEmpty
        return DayTimeline(
            date: name, exists: true, entries: entries, summary: summary,
            userNotes: Self.withoutHeadings(doc.userMarkdown)
        )
    }

    // MARK: - Private

    private func resolveDay(_ text: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch s {
        case "today": return calendar.startOfDay(for: Date())
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))
        default:
            let path = "\(MemoryDirectory.dailyDirectory)/\(s).md"
            guard let day = MemoryDirectory.day(ofDailyFile: path, timeZone: timeZone),
                  MemoryDirectory.dayName(for: day, timeZone: timeZone) == s
            else { return nil }
            return day
        }
    }

    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^- (\d{1,2}:\d{2})[–-](\d{1,2}:\d{2}) (.*?)\s*(?:<!--(.*?)-->)?\s*$"#
    )

    /// 解析时间线区块：`- HH:MM–HH:MM [低置信标记]标题 <!-- seg:… conf:… -->`，下一行缩进的是摘要。
    static func parseTimeline(_ body: String) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        var current: (start: String, end: String, title: String, conf: Double?, low: Bool, summary: [String])?
        func flush() {
            guard let c = current else { return }
            entries.append(TimelineEntry(
                start: c.start, end: c.end, title: c.title,
                summary: c.summary.joined(separator: " "), confidence: c.conf, lowConfidence: c.low
            ))
            current = nil
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let ns = line as NSString
            if let m = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush()
                var title = ns.substring(with: m.range(at: 3))
                var low = false
                for tag in TimelineBlock.allLowConfidenceTags where title.hasPrefix(tag) {
                    title = String(title.dropFirst(tag.count))
                    low = true
                }
                var conf: Double?
                if m.range(at: 4).location != NSNotFound {
                    let meta = ns.substring(with: m.range(at: 4))
                    if let r = meta.range(of: #"conf:([0-9.]+)"#, options: .regularExpression) {
                        conf = Double(meta[r].dropFirst(5))
                    }
                }
                current = (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)),
                           title.trimmingCharacters(in: .whitespaces), conf, low, [])
            } else if line.hasPrefix("  "), current != nil {
                let text = line.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { current?.summary.append(text) }
            }
        }
        flush()
        return entries
    }

    /// daily 中去掉系统区块后只剩一级标题与（可能为空的）小节标题时，视为没有手写内容。
    private static func withoutHeadings(_ text: String) -> String {
        let body = text.split(separator: "\n").filter { line in
            !(line.hasPrefix("# ") || line.hasPrefix("## "))
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

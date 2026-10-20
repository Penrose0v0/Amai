import AmaiCore
import Foundation
import GRDB

public enum MemoryScope: String, Sendable, CaseIterable {
    case daily
    case summary
    /// 专题文件（work/、goals/、health/、finance/ 等）。
    case topic
}

public struct MemoryHit: Sendable, Equatable {
    public let file: String
    public let heading: String
    public let excerpt: String
    /// 越小越相关（bm25）；子串匹配时为 0。
    public let score: Double
    public let day: Date?
}

/// 记忆检索（docs/memory.md §6 的 MVP 阶段）：section 粒度的全文索引 + 时间过滤。
///
/// - 增量：按文件修改时间与大小判断变化，只重建变化的文件，删除已不存在文件的索引；
/// - 用户在编辑器中修改 Markdown 后，下一次 `refresh()` 自动纳入（App 定期调用，MVP 用轮询而非文件事件）；
/// - `rebuild()` 清空后从 Markdown 全量重建，结果与增量一致。
public actor MemoryIndex {
    private let root: URL
    private let db: MemoryIndexDatabase
    private let timeZone: TimeZone
    private let log = AmaiLog.logger("memory.index")

    public init(root: URL, database: MemoryIndexDatabase, timeZone: TimeZone = .current) {
        self.root = root
        self.db = database
        self.timeZone = timeZone
    }

    public struct RefreshResult: Sendable, Equatable {
        public var indexed = 0
        public var removed = 0
        public var unchanged = 0
    }

    @discardableResult
    public func refresh() throws -> RefreshResult {
        var result = RefreshResult()
        let files = MemoryStore.markdownFiles(in: root)
        let known: [String: (Double, Int64)] = try db.writer.read { db in
            var map: [String: (Double, Int64)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT file, mtime, size FROM file_meta") {
                map[row["file"]] = (row["mtime"], row["size"])
            }
            return map
        }

        for file in files {
            let url = root.appendingPathComponent(file)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = Int64(values?.fileSize ?? 0)
            if let old = known[file], old.0 == mtime, old.1 == size {
                result.unchanged += 1
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try index(file: file, text: text, mtime: mtime, size: size)
            result.indexed += 1
        }

        let gone = Set(known.keys).subtracting(files)
        if !gone.isEmpty {
            try db.writer.write { db in
                for file in gone {
                    try db.execute(sql: "DELETE FROM section WHERE file = ?", arguments: [file])
                    try db.execute(sql: "DELETE FROM file_meta WHERE file = ?", arguments: [file])
                }
            }
            result.removed = gone.count
        }
        if result.indexed > 0 || result.removed > 0 {
            log.info("index refresh: \(result.indexed) indexed, \(result.removed) removed")
        }
        return result
    }

    @discardableResult
    public func rebuild() throws -> RefreshResult {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM section")
            try db.execute(sql: "DELETE FROM file_meta")
        }
        return try refresh()
    }

    /// 按问题检索。查询不足 3 个字符时 trigram 无法匹配，改用子串匹配。
    public func retrieve(
        _ query: String,
        scopes: Set<MemoryScope> = Set(MemoryScope.allCases),
        dayRange: ClosedRange<Date>? = nil,
        limit: Int = 10
    ) throws -> [MemoryHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, limit > 0 else { return [] }

        var filters: [String] = []
        var args: [any DatabaseValueConvertible] = []
        if scopes.count < MemoryScope.allCases.count {
            var parts: [String] = []
            if scopes.contains(.daily) { parts.append("s.file LIKE 'daily/%'") }
            if scopes.contains(.summary) { parts.append("s.file = 'summary.md'") }
            if scopes.contains(.topic) { parts.append("(s.file NOT LIKE 'daily/%' AND s.file <> 'summary.md')") }
            filters.append("(" + (parts.isEmpty ? "0" : parts.joined(separator: " OR ")) + ")")
        }
        if let dayRange {
            filters.append("s.day IS NOT NULL AND s.day >= ? AND s.day <= ?")
            args.append(dayRange.lowerBound)
            args.append(dayRange.upperBound)
        }
        let whereExtra = filters.isEmpty ? "" : " AND " + filters.joined(separator: " AND ")

        let useFTS = q.count >= 3
        return try db.writer.read { db in
            let rows: [Row]
            if useFTS {
                let pattern = FTS5Pattern(matchingPhrase: q)
                rows = try Row.fetchAll(db, sql: """
                    SELECT s.file, s.heading, s.content, s.day, bm25(section_fts) AS score
                    FROM section_fts JOIN section s ON s.id = section_fts.rowid
                    WHERE section_fts MATCH ?\(whereExtra)
                    ORDER BY score, s.day DESC LIMIT ?
                    """, arguments: StatementArguments([pattern] + args + [limit]))
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT s.file, s.heading, s.content, s.day, 0.0 AS score
                    FROM section s
                    WHERE (s.content LIKE ? ESCAPE '\\' OR s.heading LIKE ? ESCAPE '\\')\(whereExtra)
                    ORDER BY s.day DESC, s.file DESC LIMIT ?
                    """, arguments: StatementArguments([Self.likePattern(q), Self.likePattern(q)] + args + [limit]))
            }
            return rows.map { row in
                let content: String = row["content"]
                return MemoryHit(
                    file: row["file"],
                    heading: row["heading"],
                    excerpt: Self.excerpt(content, around: q),
                    score: row["score"],
                    day: row["day"]
                )
            }
        }
    }

    // MARK: - Private

    private func index(file: String, text: String, mtime: Double, size: Int64) throws {
        let sections = MarkdownSections.parse(text)
        let day = MemoryDirectory.day(ofDailyFile: file, timeZone: timeZone)
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM section WHERE file = ?", arguments: [file])
            for s in sections {
                try db.execute(
                    sql: "INSERT INTO section (file, heading, position, content, day) VALUES (?, ?, ?, ?, ?)",
                    arguments: [file, s.heading, s.position, s.content, day]
                )
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO file_meta (file, mtime, size) VALUES (?, ?, ?)",
                arguments: [file, mtime, size]
            )
        }
    }

    private static func likePattern(_ q: String) -> String {
        let escaped = q
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    /// 命中处前后各取若干字符；未定位到时取开头。
    static func excerpt(_ content: String, around query: String, radius: Int = 60) -> String {
        let flat = content.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: query, options: .caseInsensitive) else {
            return String(flat.prefix(radius * 2))
        }
        let start = flat.index(r.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}

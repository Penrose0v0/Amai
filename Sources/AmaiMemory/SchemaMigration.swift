import AmaiCore
import CryptoKit
import Foundation

/// 旧记忆目录（summary.md、work/、goals/、health/、finance/）迁移到 Memory Schema v1（ADR-0006）。
///
/// 安全约束：
/// - **不截断、不改写**：旧条目的文字、来源、依据、小节原样搬入目标文件，不做条目上限、脱敏或去标点；
///   旧文件区块外的用户内容只要不是系统骨架，就原样搬到目标文件的用户区域。
/// - **先写后验再归档**：写入目标后重读校验每条旧条目与每段用户内容都在，通过后才把旧文件
///   复制到 `.archive/schema-v1/`、校验副本哈希、再从原位置移除。任何一步失败都停止，旧文件保持原样。
/// - **幂等可续跑**：重复运行时已搬入的内容不会重复写入；中途崩溃后再次运行会从剩下的旧文件继续。
/// - **可恢复**：迁移记录保存在归档目录，含每个源文件和目标文件的 SHA-256。回滚只在目标文件
///   自迁移后**未被修改**时进行，且不删除任何文件：新文件移到回滚目录，旧文件从归档复制回原位。
public struct SchemaMigration: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let legacyDirectories = ["work", "goals", "health", "finance"]
    static let legacySummary = "summary.md"

    var archiveRoot: URL { root.appendingPathComponent("\(MemoryDirectory.archiveDirectory)/schema-v1", isDirectory: true) }
    var recordURL: URL { archiveRoot.appendingPathComponent("migration.json") }

    public struct Report: Sendable, Equatable {
        /// 本次迁移并归档的旧文件。
        public var migrated: [String] = []
        /// 本次写入（或确认已包含旧内容）的目标文件。
        public var targets: [String] = []
        public var itemsCarried = 0
        public var userFragmentsCarried = 0
    }

    public struct RollbackReport: Sendable, Equatable {
        public var restored: [String] = []
        /// 移到回滚目录的新文件（相对记忆根目录）。
        public var setAside: [String] = []
    }

    public enum MigrationError: Error, Equatable, CustomStringConvertible {
        public var description: String {
            switch self {
            case .unreadable(let f): "无法读取 \(f)"
            case .malformedBlock(let f): "\(f) 中的系统区块标记不完整"
            case .verificationFailed(let detail): "迁移校验未通过（\(detail)）"
            case .archiveFailed(let f): "归档 \(f) 失败"
            }
        }

        case unreadable(String)
        case malformedBlock(String)
        case verificationFailed(String)
        case archiveFailed(String)
    }

    public enum RollbackError: Error, Equatable, CustomStringConvertible {
        public var description: String {
            switch self {
            case .nothingToRollBack: "没有可以回滚的迁移"
            case .targetModified(let files): "迁移后这些文件已被修改，回滚会丢失更新：\(files.joined(separator: "、"))"
            case .archiveMissing(let f): "归档文件缺失：\(f)"
            case .archiveModified(let f): "归档文件已被改动：\(f)"
            case .legacyPathOccupied(let f): "原位置已有文件：\(f)"
            }
        }

        case nothingToRollBack
        /// 迁移后目标文件已被修改（整理或用户编辑）。直接回滚会丢掉这些更新，因此拒绝。
        case targetModified([String])
        case archiveMissing(String)
        case archiveModified(String)
        /// 原位置已有文件，复制回去会覆盖它。
        case legacyPathOccupied(String)
    }

    // MARK: - Record

    struct Record: Codable, Equatable {
        struct Source: Codable, Equatable {
            var path: String
            var sha256: String
            /// 相对归档根目录。
            var archivedAs: String
            var items: Int
        }
        struct Target: Codable, Equatable {
            var path: String
            /// 迁移前已存在的目标文件的副本（相对归档根目录），回滚时恢复。
            var preMigrationCopy: String?
            var sha256After: String
            var items: Int
        }
        struct Run: Codable, Equatable {
            var id = UUID()
            var date: Date
            var sources: [Source]
            var targets: [Target]
        }
        var schemaVersion = MemorySchema.version
        var runs: [Run] = []
        var rollbacks: [Date] = []
    }

    // MARK: - Migrate

    /// 记忆根目录下仍存在的旧布局 Markdown 文件（不含隐藏文件）。
    public func legacyFiles() -> [String] {
        MemoryStore.markdownFiles(in: root).filter { Self.target(forLegacy: $0) != nil }
    }

    static func target(forLegacy path: String) -> MemoryCategory? {
        if path == legacySummary { return .general }
        for dir in legacyDirectories where path.hasPrefix(dir + "/") {
            return MemoryCategory(rawValue: dir)
        }
        return nil
    }

    @discardableResult
    public func migrate(now: Date = Date()) throws -> Report {
        defer { removeEmptyLegacyDirectories() }
        let legacy = legacyFiles()
        guard !legacy.isEmpty else { return Report() }

        var report = Report()
        var run = Record.Run(date: now, sources: [], targets: [])
        let grouped = Dictionary(grouping: legacy) { Self.target(forLegacy: $0)! }

        for category in MemoryCategory.documents {
            guard let files = grouped[category]?.sorted(), let targetPath = category.file else { continue }
            var parsed: [LegacyFile] = []
            var usedSections: Set<String> = []
            for file in files {
                var legacyFile = try parse(file, category: category)
                if category != .general {
                    // 两个旧文件标题相同时用路径区分，避免两组条目合进同一小节后分不清出处。
                    if usedSections.contains(legacyFile.section) {
                        legacyFile.section = "\(legacyFile.section)（\(file)）"
                        legacyFile.items = legacyFile.items.map { var i = $0; i.section = legacyFile.section; return i }
                    }
                    usedSections.insert(legacyFile.section)
                }
                parsed.append(legacyFile)
            }

            let target = try writeTarget(targetPath, category: category, legacy: parsed, runDate: now)
            try verify(targetPath, contains: parsed)
            run.targets.append(target)
            report.targets.append(targetPath)

            // 记录先于归档落盘：归档中途崩溃时，记录里已有这些文件的去向，回滚能找回。
            var sources: [Record.Source] = []
            for f in parsed {
                sources.append(Record.Source(
                    path: f.path, sha256: f.sha256, archivedAs: archiveName(for: f), items: f.items.count
                ))
            }
            run.sources += sources
            try saveRun(run)
            for (f, s) in zip(parsed, sources) {
                try archive(f, as: s.archivedAs)
                report.migrated.append(f.path)
                report.itemsCarried += f.items.count
                report.userFragmentsCarried += f.userFragment == nil ? 0 : 1
            }
        }
        return report
    }

    struct LegacyFile {
        let path: String
        let sha256: String
        var section: String
        var items: [MemoryItem]
        /// 需要搬运的用户内容；只有系统骨架时为 nil。
        let userFragment: String?
    }

    private func parse(_ path: String, category: MemoryCategory) throws -> LegacyFile {
        let url = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw MigrationError.unreadable(path)
        }
        let block = Consolidator.memoryBlock
        let body = block.content(in: text)
        if body == nil, text.contains(block.beginPrefix) || text.contains(block.endMarker) {
            throw MigrationError.malformedBlock(path)
        }
        let userPart = block.removing(from: text)
        // 第二个区块或残留标记会被当成手写内容搬进目标文件，之后与真正的系统区块混淆，因此拒绝。
        if userPart.contains(block.beginPrefix) || userPart.contains(block.endMarker) {
            throw MigrationError.malformedBlock(path)
        }
        let title = userPart.split(separator: "\n").first { $0.hasPrefix("# ") }
            .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? Consolidator.titleFromPath(path)

        var items = MemoryItems.parse(body ?? "")
        if category == .general {
            items = items.map { var i = $0; i.section = MemorySchema.generalSection(forLegacy: i.section); return i }
        } else {
            items = items.map { var i = $0; i.section = i.section.map { "\(title) / \($0)" } ?? title; return i }
        }

        return LegacyFile(
            path: path, sha256: Self.sha256(data), section: title, items: items,
            userFragment: Self.isSkeleton(userPart) ? nil : userPart.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 只剩一级标题和旧版生成的二级标题时视为骨架。
    static func isSkeleton(_ userPart: String) -> Bool {
        var sawTitle = false
        for raw in userPart.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !sawTitle, line.hasPrefix("# ") { sawTitle = true; continue }
            if MemorySchema.legacyGeneratedHeadings.contains(line) { continue }
            return false
        }
        return true
    }

    /// 把旧条目与用户内容合入目标文件。已存在的条目（文字、依据完全相同）只合并来源，
    /// 已存在的用户内容不重复追加，因此重复运行结果不变。
    private func writeTarget(_ path: String, category: MemoryCategory, legacy: [LegacyFile], runDate: Date) throws -> Record.Target {
        let url = root.appendingPathComponent(path)
        let fm = FileManager.default
        var existing: String?
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                throw MigrationError.unreadable(path)
            }
            existing = text
        }
        let block = Consolidator.memoryBlock
        let current = existing.flatMap(block.content(in:)) ?? ""
        if existing != nil, block.content(in: existing!) == nil,
           existing!.contains(block.beginPrefix) || existing!.contains(block.endMarker) {
            throw MigrationError.malformedBlock(path)
        }

        let items = Self.mergeExact(MemoryItems.parse(current) + legacy.flatMap(\.items))
        let body = MemoryItems.render(items, sections: category == .general ? MemorySchema.generalSections : nil)
        var updated: String
        do {
            updated = try block.splice(
                body: body, into: existing, newFileTitle: MemorySchema.title(for: category),
                heading: MemorySchema.blockHeading
            )
        } catch {
            throw MigrationError.malformedBlock(path)
        }
        for f in legacy {
            guard let fragment = f.userFragment, !updated.contains(fragment) else { continue }
            if !updated.hasSuffix("\n") { updated += "\n" }
            updated += "\n## 迁移自 \(f.path)\n\n\(fragment)\n"
        }

        var preCopy: String?
        if let existing, updated != existing {
            // 迁移前就存在的目标文件（例如用户自己建的 work.md）先留副本，回滚时恢复。
            let name = "pre-migration/\(Self.stamp(runDate))/\(path)"
            try writeVerified(Data(existing.utf8), to: archiveRoot.appendingPathComponent(name))
            preCopy = name
        }
        if updated != existing {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: url, options: .atomic)
        }
        return Record.Target(
            path: path, preMigrationCopy: preCopy, sha256After: Self.sha256(Data(updated.utf8)), items: items.count
        )
    }

    /// 迁移专用合并：文字（逐字）与依据都相同才合并，来源取并集。不做规范化，保证文字原样保留。
    static func mergeExact(_ items: [MemoryItem]) -> [MemoryItem] {
        var result: [MemoryItem] = []
        var index: [String: Int] = [:]
        for item in items {
            let key = "\(item.kind.rawValue)|\(item.text)"
            if let i = index[key] {
                result[i].sources = Array(Set(result[i].sources + item.sources)).sorted()
                continue
            }
            index[key] = result.count
            result.append(item)
        }
        return result
    }

    private func verify(_ path: String, contains legacy: [LegacyFile]) throws {
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw MigrationError.verificationFailed(path)
        }
        let items = MemoryItems.parse(Consolidator.memoryBlock.content(in: text) ?? "")
        for f in legacy {
            for old in f.items {
                let found = items.contains { $0.text == old.text && $0.kind == old.kind && Set(old.sources).isSubset(of: $0.sources) }
                guard found else { throw MigrationError.verificationFailed("\(path)：缺少来自 \(f.path) 的条目") }
            }
            if let fragment = f.userFragment, !text.contains(fragment) {
                throw MigrationError.verificationFailed("\(path)：缺少来自 \(f.path) 的手写内容")
            }
        }
    }

    private func archiveName(for file: LegacyFile) -> String {
        let fm = FileManager.default
        var name = file.path
        var n = 2
        // 归档中已有同名但内容不同的文件（例如回滚后又编辑过再迁移）时换个名字，不覆盖旧归档。
        while fm.fileExists(atPath: archiveRoot.appendingPathComponent(name).path),
              (try? Data(contentsOf: archiveRoot.appendingPathComponent(name))).map(Self.sha256) != file.sha256 {
            name = "\(file.path).\(n)"
            n += 1
        }
        return name
    }

    private func archive(_ file: LegacyFile, as name: String) throws {
        let source = root.appendingPathComponent(file.path)
        let dest = archiveRoot.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: source), Self.sha256(data) == file.sha256 else {
            // 迁移期间旧文件被改动：停止，下次运行时重新合入。
            throw MigrationError.archiveFailed(file.path)
        }
        if (try? Data(contentsOf: dest)).map(Self.sha256) != file.sha256 {
            try writeVerified(data, to: dest)
        }
        try FileManager.default.removeItem(at: source)
    }

    private func writeVerified(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        guard (try? Data(contentsOf: url)).map(Self.sha256) == Self.sha256(data) else {
            throw MigrationError.archiveFailed(url.lastPathComponent)
        }
    }

    /// 只删除空目录（或只剩 Finder 生成的 .DS_Store），有任何其他文件就保留。
    private func removeEmptyLegacyDirectories() {
        let fm = FileManager.default
        for dir in Self.legacyDirectories {
            let url = root.appendingPathComponent(dir, isDirectory: true)
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            var dirs: [URL] = [url]
            var hasContent = false
            for case let item as URL in enumerator {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    dirs.append(item)
                } else if item.lastPathComponent != ".DS_Store" {
                    hasContent = true
                }
            }
            guard !hasContent else { continue }
            for d in dirs.sorted(by: { $0.path.count > $1.path.count }) {
                try? fm.removeItem(at: d.appendingPathComponent(".DS_Store"))
                try? fm.removeItem(at: d)
            }
        }
    }

    // MARK: - Status

    public struct Status: Sendable, Equatable {
        public struct Target: Sendable, Equatable {
            public let path: String
            /// 当前内容与迁移完成时的哈希一致。
            public let unchangedSinceMigration: Bool
        }
        public var legacyFiles: [String] = []
        public var runs = 0
        public var targets: [Target] = []
        /// 归档副本缺失或哈希不符的源文件。
        public var archiveProblems: [String] = []
    }

    /// 只读校验迁移记录：目标文件是否在迁移后被修改、归档副本是否完整。
    public func status() -> Status {
        let record = loadRecord()
        var status = Status()
        status.legacyFiles = legacyFiles()
        status.runs = record.runs.count
        var latest: [String: Record.Target] = [:]
        for t in record.runs.flatMap(\.targets) { latest[t.path] = t }
        status.targets = latest.values.sorted { $0.path < $1.path }.map { t in
            let current = (try? Data(contentsOf: root.appendingPathComponent(t.path))).map(Self.sha256)
            return Status.Target(path: t.path, unchangedSinceMigration: current == t.sha256After)
        }
        for s in record.runs.flatMap(\.sources) {
            let data = try? Data(contentsOf: archiveRoot.appendingPathComponent(s.archivedAs))
            if data.map(Self.sha256) != s.sha256 { status.archiveProblems.append(s.archivedAs) }
        }
        return status
    }

    // MARK: - Rollback

    /// 撤销尚未被修改过的迁移：旧文件从归档复制回原位，新文件移到 `.archive/schema-v1-rollback/<时间>/`。
    /// 任一目标文件在迁移后被改动、归档缺失或损坏、原位置已有文件时，整体拒绝，不做任何改动。
    @discardableResult
    public func rollback(now: Date = Date()) throws -> RollbackReport {
        var record = loadRecord()
        guard !record.runs.isEmpty else { throw RollbackError.nothingToRollBack }

        var latestTargets: [String: Record.Target] = [:]
        var firstTargets: [String: Record.Target] = [:]
        for run in record.runs {
            for t in run.targets {
                latestTargets[t.path] = t
                if firstTargets[t.path] == nil { firstTargets[t.path] = t }
            }
        }
        let fm = FileManager.default
        let modified = latestTargets.values.filter { t in
            (try? Data(contentsOf: root.appendingPathComponent(t.path))).map(Self.sha256) != t.sha256After
        }.map(\.path).sorted()
        guard modified.isEmpty else { throw RollbackError.targetModified(modified) }

        // 中途崩溃后续跑时，同一源文件会出现在多次运行里；按路径去重，以最后一次为准。
        var byPath: [String: Record.Source] = [:]
        for s in record.runs.flatMap(\.sources) { byPath[s.path] = s }
        let sources = byPath.values.sorted { $0.path < $1.path }
        for s in sources {
            let archived = archiveRoot.appendingPathComponent(s.archivedAs)
            guard let data = try? Data(contentsOf: archived) else { throw RollbackError.archiveMissing(s.archivedAs) }
            guard Self.sha256(data) == s.sha256 else { throw RollbackError.archiveModified(s.archivedAs) }
            guard !fm.fileExists(atPath: root.appendingPathComponent(s.path).path) else {
                throw RollbackError.legacyPathOccupied(s.path)
            }
        }
        for t in firstTargets.values {
            if let pre = t.preMigrationCopy, !fm.fileExists(atPath: archiveRoot.appendingPathComponent(pre).path) {
                throw RollbackError.archiveMissing(pre)
            }
        }

        var report = RollbackReport()
        // 先把新文件移开（不删除），再放回旧文件，避免两套布局同时存在时被整理流程读到。
        let aside = root.appendingPathComponent("\(MemoryDirectory.archiveDirectory)/schema-v1-rollback/\(Self.stamp(now))", isDirectory: true)
        for t in latestTargets.values.sorted(by: { $0.path < $1.path }) {
            let src = root.appendingPathComponent(t.path)
            let dest = aside.appendingPathComponent(t.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: src, to: dest)
            report.setAside.append("\(MemoryDirectory.archiveDirectory)/schema-v1-rollback/\(Self.stamp(now))/\(t.path)")
            if let pre = firstTargets[t.path]?.preMigrationCopy,
               let data = try? Data(contentsOf: archiveRoot.appendingPathComponent(pre)) {
                try writeVerified(data, to: src)
            }
        }
        for s in sources {
            let data = try Data(contentsOf: archiveRoot.appendingPathComponent(s.archivedAs))
            try writeVerified(data, to: root.appendingPathComponent(s.path))
            report.restored.append(s.path)
        }
        record.runs = []
        record.rollbacks.append(now)
        try saveRecord(record)
        return report
    }

    // MARK: - Persistence

    func loadRecord() -> Record {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: recordURL)).flatMap { try? decoder.decode(Record.self, from: $0) } ?? Record()
    }

    private func saveRun(_ run: Record.Run) throws {
        var record = loadRecord()
        // 同一次迁移按分区分批保存，按 id 覆盖（日期经 ISO 8601 往返会丢掉毫秒，不能用来比较）。
        if let i = record.runs.firstIndex(where: { $0.id == run.id }) {
            record.runs[i] = run
        } else {
            record.runs.append(run)
        }
        try saveRecord(record)
    }

    private func saveRecord(_ record: Record) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}

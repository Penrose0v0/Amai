import AmaiCore
import Foundation

/// Markdown 记忆的读写入口（docs/memory.md）。单进程内唯一写入者，actor 保证串行。
///
/// 写入原语：写前重读文件 → 只替换系统区块 → 内容不变则不写 → 原子写入（临时文件 + 重命名）。
/// 读不出已有文件（权限、编码错误）时拒绝写入，避免用空视图覆盖真实内容。
public actor MemoryStore {
    public let root: URL
    private let timeZone: TimeZone
    /// 记忆语言：时间线区块的说明、标题与低置信标记。只影响之后重写的内容。
    private var language: MemoryLanguage = .default
    private let log = AmaiLog.logger("memory.store")

    public enum WriteError: Error, Equatable, CustomStringConvertible {
        public var description: String {
            switch self {
            case .unreadableExisting(let f): String(localized: "无法读取已有文件 \(f)，为避免覆盖已停止写入")
            case .malformedBlock(let f): String(localized: "\(f) 中的系统区块标记不完整，为避免误删内容已停止写入")
            }
        }

        case unreadableExisting(String)
        case malformedBlock(String)
    }

    public init(root: URL, timeZone: TimeZone = .current, language: MemoryLanguage = .default) throws {
        self.root = root
        self.timeZone = timeZone
        self.language = language
        try MemoryDirectory.ensureDirectories(at: root)
    }

    public func setLanguage(_ language: MemoryLanguage) {
        self.language = language
    }

    /// 用给定片段重写某天 daily 文件的时间线区块。返回文件是否发生变化。
    /// 没有可写入的片段且文件不存在时不创建文件。
    @discardableResult
    public func writeDailyTimeline(day: Date, segments: [ActivitySegment]) throws -> Bool {
        let relative = MemoryDirectory.dailyFile(for: day, timeZone: timeZone)
        let url = root.appendingPathComponent(relative)
        let fm = FileManager.default

        let existing: String?
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                throw WriteError.unreadableExisting(relative)
            }
            existing = text
        } else {
            existing = nil
        }

        let body = TimelineBlock.render(segments, timeZone: timeZone, language: language)
        if existing == nil && body.isEmpty { return false }

        let updated: String
        do {
            updated = try TimelineBlock.splice(
                body: body,
                into: existing,
                dayTitle: MemoryDirectory.dayName(for: day, timeZone: timeZone),
                language: language
            )
        } catch {
            log.error("daily block markers malformed, refusing to write")
            throw WriteError.malformedBlock(relative)
        }
        guard updated != existing else { return false }

        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(updated.utf8).write(to: url, options: .atomic)
        return true
    }

    /// 改写某个文件中的一个系统区块（整理任务使用）。写前重读、内容不变不写、
    /// 有旧内容时先存快照，然后原子写入。返回文件是否发生变化。
    @discardableResult
    public func writeBlock(
        _ block: SystemBlock,
        body: String,
        file relativePath: String,
        newFileTitle: String,
        heading: String,
        insertBeforeHeading: String? = nil,
        snapshots: SnapshotStore?,
        task: String,
        model: String? = nil,
        itemCount: Int
    ) throws -> Bool {
        let url = root.appendingPathComponent(relativePath)
        let fm = FileManager.default
        var existing: String?
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                throw WriteError.unreadableExisting(relativePath)
            }
            existing = text
        }
        let updated: String
        do {
            updated = try block.splice(
                body: body, into: existing, newFileTitle: newFileTitle,
                heading: heading, insertBeforeHeading: insertBeforeHeading
            )
        } catch {
            throw WriteError.malformedBlock(relativePath)
        }
        guard updated != existing else { return false }
        try snapshots?.record(relativePath: relativePath, previous: existing, task: task, model: model, itemCount: itemCount)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(updated.utf8).write(to: url, options: .atomic)
        return true
    }

    /// 去掉文件中的一个系统区块（删除数据时清掉派生内容）。区块所在小节因此变空时，一并去掉该小节标题
    ///（`headings` 中的任一写法）。区块外的用户内容不变；不存快照——快照会把要删除的内容留下。返回文件是否变化。
    @discardableResult
    public func removeBlock(_ block: SystemBlock, file relativePath: String, headings: Set<String>) throws -> Bool {
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url), let existing = String(data: data, encoding: .utf8) else {
            throw WriteError.unreadableExisting(relativePath)
        }
        guard block.content(in: existing) != nil else {
            // 只有一条标记：不知道区块边界，宁可不动。
            if existing.contains(block.beginPrefix) || existing.contains(block.endMarker) {
                throw WriteError.malformedBlock(relativePath)
            }
            return false
        }
        let updated = Self.droppingEmptySections(block.removing(from: existing), headings: headings)
        guard updated != existing else { return false }
        try Data(updated.utf8).write(to: url, options: .atomic)
        return true
    }

    /// 去掉后面紧跟另一个标题（或文件结尾）、中间只有空行的指定标题行。
    static func droppingEmptySections(_ text: String, headings: Set<String>) -> String {
        var lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            guard headings.contains(lines[i].trimmingCharacters(in: .whitespaces)) else { i += 1; continue }
            var j = i + 1
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            if j == lines.count || lines[j].hasPrefix("#") {
                lines.removeSubrange(i..<j)
            } else {
                i += 1
            }
        }
        var result = lines.joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result
    }

    public func read(_ relativePath: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 记忆目录下全部 Markdown 文件（相对路径），跳过隐藏文件。
    public func markdownFiles() -> [String] {
        Self.markdownFiles(in: root)
    }

    static func markdownFiles(in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let base = root.standardizedFileURL.path
        var files: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "md" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            files.append(String(path.dropFirst(base.count).drop(while: { $0 == "/" })))
        }
        return files.sorted()
    }
}

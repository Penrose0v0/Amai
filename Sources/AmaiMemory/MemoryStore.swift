import AmaiCore
import Foundation

/// Markdown 记忆的读写入口（docs/memory.md）。单进程内唯一写入者，actor 保证串行。
///
/// 写入原语：写前重读文件 → 只替换系统区块 → 内容不变则不写 → 原子写入（临时文件 + 重命名）。
/// 读不出已有文件（权限、编码错误）时拒绝写入，避免用空视图覆盖真实内容。
public actor MemoryStore {
    public let root: URL
    private let timeZone: TimeZone
    private let log = AmaiLog.logger("memory.store")

    public enum WriteError: Error, Equatable, CustomStringConvertible {
        public var description: String {
            switch self {
            case .unreadableExisting(let f): "无法读取已有文件 \(f)，为避免覆盖已停止写入"
            case .malformedBlock(let f): "\(f) 中的系统区块标记不完整，为避免误删内容已停止写入"
            }
        }

        case unreadableExisting(String)
        case malformedBlock(String)
    }

    public init(root: URL, timeZone: TimeZone = .current) throws {
        self.root = root
        self.timeZone = timeZone
        try MemoryDirectory.ensureDirectories(at: root)
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

        let body = TimelineBlock.render(segments, timeZone: timeZone)
        if existing == nil && body.isEmpty { return false }

        let updated: String
        do {
            updated = try TimelineBlock.splice(
                body: body,
                into: existing,
                dayTitle: MemoryDirectory.dayName(for: day, timeZone: timeZone)
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

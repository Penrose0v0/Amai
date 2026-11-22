import AmaiMemory
import Foundation

/// 一次评测的工作目录。真实记忆只在 `prepare` 时被读取一次并复制进来；之后的出题、作答、评分都只用副本。
///
/// 隔离方式：
/// - 副本里的文件设为只读（0444，目录 0555）：被测管线万一尝试写记忆会直接报错，而不是悄悄改动；
/// - 索引、会话都在工作目录里新建，不打开 App 的索引、配置和会话记录；
/// - 工作目录不能位于真实记忆目录或 App 的数据目录之内，反之亦然。
public struct QAWorkspace: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var memory: URL { root.appendingPathComponent("memory", isDirectory: true) }
    public var support: URL { root.appendingPathComponent("support", isDirectory: true) }
    public var indexDatabase: URL { support.appendingPathComponent("index/memory.sqlite") }
    public var manifest: URL { root.appendingPathComponent("manifest.json") }
    public var dataset: URL { root.appendingPathComponent("dataset.json") }
    public var answers: URL { root.appendingPathComponent("answers.jsonl") }
    public var judgments: URL { root.appendingPathComponent("judgments.jsonl") }
    public var summary: URL { root.appendingPathComponent("summary.json") }
    public var records: URL { root.appendingPathComponent("records.jsonl") }
    public var report: URL { root.appendingPathComponent("report.md") }
    /// 出题模型（Claude Code）的工作目录：空目录，不让它看到仓库或记忆文件。
    public var generatorWorkdir: URL { support.appendingPathComponent("generator", isDirectory: true) }

    public enum WorkspaceError: Error, CustomStringConvertible {
        case overlaps(String)
        case alreadyPrepared
        case notPrepared
        case sourceMissing(String)
        case copyChanged

        public var description: String {
            switch self {
            case .overlaps(let detail): "工作目录与受保护的目录重叠：\(detail)"
            case .alreadyPrepared: "工作目录里已经有记忆副本；换一个新的工作目录"
            case .notPrepared: "工作目录里没有记忆副本，先运行 prepare"
            case .sourceMissing(let path): "记忆目录不存在：\(path)"
            case .copyChanged: "记忆副本在评测过程中被改动（摘要不一致）"
            }
        }
    }

    public struct Manifest: Codable, Sendable {
        public var createdAt: Date
        /// 复制的文件（相对路径）与各自的 SHA-256。
        public var files: [String: String]
        public var digest: String
        public var timeZone: String
    }

    /// 复制真实记忆（只读取，不改动源目录），并把副本设为只读。
    ///
    /// - Parameter protected: 工作目录不能与之重叠的其他目录（App 的数据目录）。
    @discardableResult
    public func prepare(from source: URL, protected: [URL] = []) throws -> Manifest {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.path) else { throw WorkspaceError.sourceMissing(source.path) }
        let resolved = root.resolvingSymlinksInPath()
        for guarded in [source] + protected.map({ $0.standardizedFileURL.resolvingSymlinksInPath() }) {
            if Self.contains(guarded, resolved) || Self.contains(resolved, guarded) {
                throw WorkspaceError.overlaps(guarded.path)
            }
        }
        guard !FileManager.default.fileExists(atPath: memory.path) else { throw WorkspaceError.alreadyPrepared }
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("index"), withIntermediateDirectories: true)

        var files: [String: String] = [:]
        for relative in Self.memoryFiles(in: source) {
            let from = source.appendingPathComponent(relative)
            let to = memory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: from)
            try data.write(to: to)
            files[relative] = QAText.sha256(data)
        }
        try setReadOnly(memory)
        let manifest = Manifest(
            createdAt: Date(), files: files, digest: Self.digest(files), timeZone: TimeZone.current.identifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: self.manifest)
        return manifest
    }

    public func loadManifest() throws -> Manifest {
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw WorkspaceError.notPrepared }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: Data(contentsOf: manifest))
    }

    /// 重新计算副本的摘要，确认与 `prepare` 时一致（副本没有被改动）。
    public func verifyCopy() throws -> String {
        let manifest = try loadManifest()
        var files: [String: String] = [:]
        for relative in Self.memoryFiles(in: memory) {
            files[relative] = QAText.sha256(try Data(contentsOf: memory.appendingPathComponent(relative)))
        }
        let digest = Self.digest(files)
        guard digest == manifest.digest else { throw WorkspaceError.copyChanged }
        return digest
    }

    /// 记忆目录中参与评测的文件：所有 Markdown，不含隐藏目录（`.archive` 是迁移前的旧文件，助手也不读它）。
    static func memoryFiles(in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        var result: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "md" {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            result.append(String(path.dropFirst(base.count + 1)))
        }
        return result.sorted()
    }

    static func digest(_ files: [String: String]) -> String {
        QAText.sha256(files.keys.sorted().map { "\($0)\t\(files[$0]!)" }.joined(separator: "\n"))
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path == parent.path || child.path.hasPrefix(p)
    }

    private func setReadOnly(_ directory: URL) throws {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var directories: [URL] = [directory]
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directories.append(url)
            } else {
                try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            }
        }
        // 目录最后设：先设目录会让里面的文件改不了权限。
        for url in directories.reversed() {
            try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        }
    }
}

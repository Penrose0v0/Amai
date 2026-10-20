import Foundation

/// 整理改写文件前的快照（参考 OpenClaw 保存改写前像）。
/// 快照文件名：`<时间戳>__<相对路径，/ 替换为 __>`；同目录 `changes.jsonl` 每次改写记一行。
public struct SnapshotStore: Sendable {
    public let root: URL
    public let keep: Int

    public init(root: URL, keep: Int = 100) {
        self.root = root
        self.keep = keep
    }

    /// 保存 `relativePath` 的旧内容（文件不存在时只记日志），并记录本次改动。
    public func record(relativePath: String, previous: String?, task: String, itemCount: Int) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = Self.stamp()
        var snapshot: String?
        if let previous {
            let name = "\(stamp)__\(relativePath.replacingOccurrences(of: "/", with: "__"))"
            try Data(previous.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
            snapshot = name
        }
        let entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "task": task,
            "file": relativePath,
            "items": itemCount,
            "snapshot": snapshot ?? NSNull(),
        ]
        var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        line.append(0x0A)
        let log = root.appendingPathComponent("changes.jsonl")
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: log, options: .atomic)
        }
        prune()
    }

    public func snapshots() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prune() {
        let all = snapshots()
        guard all.count > keep else { return }
        for url in all.prefix(all.count - keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }
}

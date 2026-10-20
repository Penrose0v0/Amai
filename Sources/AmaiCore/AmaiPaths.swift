import Foundation

/// 应用内部目录布局（docs/architecture.md §4）。记忆目录不在这里，它属于用户。
public struct AmaiPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Amai`
    public static func standard() throws -> AmaiPaths {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return AmaiPaths(root: support.appendingPathComponent("Amai", isDirectory: true))
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    /// RawSpool：截图 / 音频块，TTL 自动清理。
    public var raw: URL { root.appendingPathComponent("raw", isDirectory: true) }
    /// 抽取结果（Observation / ActivitySegment）。
    public var extracted: URL { root.appendingPathComponent("extracted", isDirectory: true) }
    /// 记忆派生索引，可删除重建。
    public var index: URL { root.appendingPathComponent("index", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    public func ensureDirectories() throws {
        for url in [root, raw, extracted, index, logs] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

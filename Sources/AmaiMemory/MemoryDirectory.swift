import Foundation

/// 记忆目录布局（docs/memory.md §2）。所有路径相对记忆根目录。
public enum MemoryDirectory {
    public static let summary = "summary.md"
    public static let dailyDirectory = "daily"

    /// MVP 自动写入的专题文件（M4 起）。health / finance 不自动写入。
    public static let autoWrittenTopics: [String] = [
        "work/research.md",
        "work/work-log.md",
        "goals/long-term.md",
        "goals/plans.md",
        "goals/decisions.md",
    ]

    public static let scaffoldOnlyTopics: [String] = [
        "health/sleep.md",
        "health/exercise.md",
        "health/nutrition.md",
        "health/medical.md",
        "finance/income.md",
        "finance/expenses.md",
        "finance/investments.md",
        "finance/assets.md",
    ]

    public static let directories: [String] = [
        "daily", "health", "work", "work/projects", "finance", "goals",
    ]

    /// `daily/YYYY-MM-DD.md`，按给定时区取日期。
    public static func dailyFile(for date: Date, timeZone: TimeZone) -> String {
        "\(dailyDirectory)/\(dayName(for: date, timeZone: timeZone)).md"
    }

    public static func dayName(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `daily/YYYY-MM-DD.md` → 当天 00:00（给定时区）。不是 daily 文件时返回 nil。
    public static func day(ofDailyFile path: String, timeZone: TimeZone) -> Date? {
        guard path.hasPrefix(dailyDirectory + "/"), path.hasSuffix(".md") else { return nil }
        let name = String(path.dropFirst(dailyDirectory.count + 1).dropLast(3))
        let parts = name.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// 默认记忆根目录（2026-10-20 用户确认）：`~/.amai/memory`，可在配置中修改。
    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".amai/memory", isDirectory: true)
    }

    /// 创建目录结构，不创建任何文件。文件在首次需要写入时才生成。
    public static func ensureDirectories(at root: URL) throws {
        for dir in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(dir, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}

/// 记忆层配置，保存在 `config.json` 的 `memory` 字段。
public struct MemoryConfiguration: Codable, Sendable, Equatable {
    /// 记忆根目录，支持 `~` 开头。
    public var root: String

    public static let `default` = MemoryConfiguration(root: "~/.amai/memory")

    public init(root: String) {
        self.root = root
    }

    public var rootURL: URL {
        let expanded = (root as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    public enum ValidationError: Error, Equatable {
        case emptyRoot
        case relativeRoot(String)
    }

    public func validate() throws {
        let trimmed = root.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ValidationError.emptyRoot }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { throw ValidationError.relativeRoot(trimmed) }
    }

    private enum CodingKeys: String, CodingKey { case root }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? Self.default.root
    }
}

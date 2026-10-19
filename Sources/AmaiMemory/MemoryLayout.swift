import Foundation

/// 记忆目录布局（docs/memory.md §2）。所有路径相对记忆根目录。
public enum MemoryLayout {
    public static let summary = "summary.md"
    public static let dailyDirectory = "daily"

    /// MVP 自动写入的专题文件。health / finance 仅保留骨架，不自动写入。
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

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `daily/YYYY-MM-DD.md`，按给定时区取日期。
    public static func dailyFile(for date: Date, timeZone: TimeZone) -> String {
        let formatter = dayFormatter.copy() as! DateFormatter
        formatter.timeZone = timeZone
        return "\(dailyDirectory)/\(formatter.string(from: date)).md"
    }

    /// 默认记忆根目录：用户可见，强调"记忆属于用户"（docs/architecture.md §4）。
    public static var defaultRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Amai/memory", isDirectory: true)
    }
}

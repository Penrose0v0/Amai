import Foundation

/// 记忆分区（Memory Schema v1，ADR-0006）。每个主要分区对应记忆根目录下的一个 Markdown 文件，
/// `daily` 对应 `daily/` 目录。分区也是今后向外部 Agent 授权读取的单位。
public enum MemoryCategory: String, Sendable, CaseIterable, Codable {
    case general
    case work
    case health
    case finance
    case goals
    case daily

    /// 单文件分区（不含 daily），按 Browser 侧栏顺序。
    public static let documents: [MemoryCategory] = [.general, .work, .health, .finance, .goals]

    /// 单文件分区的相对路径；daily 为 nil。
    public var file: String? {
        self == .daily ? nil : "\(rawValue).md"
    }

    /// 界面与提示中给用户看的名称（简体中文）。文件标题等 Markdown 内容不受影响。
    public var localizedName: String {
        switch self {
        case .general: "综合"
        case .work: "工作"
        case .health: "健康"
        case .finance: "财务"
        case .goals: "目标"
        case .daily: "每日记录"
        }
    }

    /// Markdown 文件标题与内部标识（不直接显示在界面上）。
    public var displayName: String {
        switch self {
        case .general: "General"
        case .work: "Work"
        case .health: "Health"
        case .finance: "Finance"
        case .goals: "Goals"
        case .daily: "Daily"
        }
    }

    /// 相对路径所属的分区；用户自建的其他文件不属于任何分区。
    public init?(file: String) {
        if file.hasPrefix(MemoryDirectory.dailyDirectory + "/") {
            self = .daily
            return
        }
        guard let c = MemoryCategory.documents.first(where: { $0.file == file }) else { return nil }
        self = c
    }
}

/// 记忆目录布局（docs/memory.md §2）。所有路径相对记忆根目录。
public enum MemoryDirectory {
    public static let dailyDirectory = "daily"
    /// 迁移归档等内部文件放在隐藏目录，不参与索引与整理，但保留在磁盘上供恢复。
    public static let archiveDirectory = ".archive"

    public static let directories: [String] = [dailyDirectory]

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

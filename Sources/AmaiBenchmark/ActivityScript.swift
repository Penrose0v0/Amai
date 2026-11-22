import AmaiCore
import Foundation

/// 脚本化的一段设备活动（合成数据）。感知覆盖率与端到端评测共用。
///
/// 每个活动给出应用、起止时间、屏幕内容随时间的版本，以及系统状态（锁屏、安全输入、暂停、无操作）。
/// 期望的采集结果由这些状态按文档化的规则推出（锁屏 → 不采集；暂停 / 安全输入 / 排除的应用 → 跳过占位；
/// 其余 → 采集），与被测代码无关，是 Ground Truth。
public struct ActivityScript: Codable, Sendable {
    public struct ScreenVersion: Codable, Sendable {
        /// 从活动开始算起的秒数。
        public var at: Double
        public var spec: ScreenSpec
    }

    public struct Activity: Codable, Sendable {
        public var id: String
        /// "HH:mm" 或 "HH:mm:ss"（脚本日期、脚本时区）。
        public var start: String
        public var end: String
        public var app: String
        public var bundleId: String
        /// 人工给出的期望活动类别（主观性较强，单独报告）。
        public var category: ActivityCategory?
        /// 活动的一句话描述（人读的，不参与自动评分）。
        public var description: String?
        public var screens: [ScreenVersion]
        public var locked: Bool?
        public var secureInput: Bool?
        public var paused: Bool?
        /// 无键鼠输入（距上次输入的秒数很大）。
        public var idle: Bool?
    }

    public struct Question: Codable, Sendable {
        public var id: String
        public var type: String
        public var subtype: String
        public var language: String
        public var question: String
        public var expectedAnswer: String
        public var keyPoints: [String]
        /// 答案所依据的活动。
        public var activities: [String]
        /// 用来追踪信息在各阶段是否保留的关键词（全部出现才算保留）。
        public var anchors: [String]
        public var absentTerms: [String]?
    }

    public var name: String
    public var description: String?
    public var date: String
    public var timeZone: String
    public var captureInterval: Double
    /// 绝不应出现在任何产物中的字符串：密码（只出现在被排除的应用里）与密钥（应被脱敏）。
    public var canaries: [String: String]
    public var activities: [Activity]
    public var questions: [Question]

    public static func load(_ url: URL) throws -> ActivityScript {
        try JSONDecoder().decode(ActivityScript.self, from: Data(contentsOf: url))
    }

    public var tz: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    public var day: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let parts = date.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    public func time(_ hhmmss: String) -> Date {
        let parts = hhmmss.split(separator: ":").compactMap { Double($0) }
        return day.addingTimeInterval(parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0))
    }

    public var start: Date { activities.map { time($0.start) }.min()! }
    public var end: Date { activities.map { time($0.end) }.max()! }

    public func range(_ a: Activity) -> TimeRange { TimeRange(start: time(a.start), end: time(a.end)) }

    /// 某一时刻的活动与屏幕版本（区间左闭右开）。
    public func state(at date: Date) -> (activity: Activity, version: Int, spec: ScreenSpec)? {
        guard let a = activities.first(where: { time($0.start) <= date && date < time($0.end) }) else { return nil }
        let offset = date.timeIntervalSince(time(a.start))
        let index = a.screens.lastIndex { $0.at <= offset } ?? 0
        return (a, index, a.screens[index].spec)
    }

    public enum Expected: Equatable, Sendable {
        case capture
        case skip(String)
        case blocked
    }

    /// 期望的采集结果（规则见类型说明；优先级与隐私策略文档一致：锁屏 > 暂停 > 安全输入 > 排除的应用）。
    public func expected(_ a: Activity, excludedBundleIds: Set<String>) -> Expected {
        if a.locked == true { return .blocked }
        if a.paused == true { return .skip("userPaused") }
        if a.secureInput == true { return .skip("secureInput") }
        if excludedBundleIds.contains(a.bundleId) { return .skip("excludedApp") }
        return .capture
    }
}

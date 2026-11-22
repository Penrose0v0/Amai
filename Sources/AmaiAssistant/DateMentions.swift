import Foundation

/// 从问题里认出提到的日期（"昨天""11 月 6 日""上周"），供记忆检索直接取那几天的时间线。
///
/// 日期不出现在记忆条目的正文里，靠关键词或语义都搜不到"某一天做了什么"；
/// 这类问题又很常见，所以由后端用规则解析，不依赖模型去调用工具。只认明确的写法，认不出就不取。
enum DateMentions {
    struct Result: Equatable {
        /// 明确提到的单独几天（当天 00:00），按出现顺序，最多 `maxDays` 个。
        var days: [Date] = []
        /// 提到的一段时间（"这周""过去 5 天"），起止都是当天 00:00。
        var range: ClosedRange<Date>?

        var isEmpty: Bool { days.isEmpty && range == nil }
    }

    static let maxDays = 3
    static let maxRangeDays = 14

    static func parse(_ text: String, now: Date, timeZone: TimeZone) -> Result {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: now)
        let lower = text.lowercased()
        var result = Result()
        var found: [(position: Int, day: Date)] = []

        func add(_ day: Date?, at position: Int) {
            guard let day, day <= today, !found.contains(where: { $0.day == day }) else { return }
            found.append((position, day))
        }
        func offset(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: today) }
        func matches(_ pattern: String) -> [(position: Int, groups: [String])] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let ns = lower as NSString
            return regex.matches(in: lower, range: NSRange(location: 0, length: ns.length)).map { match in
                (match.range.location, (0..<match.numberOfRanges).map {
                    match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0))
                })
            }
        }
        func date(year: Int?, month: Int, day: Int) -> Date? {
            guard (1...12).contains(month), (1...31).contains(day) else { return nil }
            let currentYear = calendar.component(.year, from: today)
            var components = DateComponents(year: year ?? currentYear, month: month, day: day)
            guard var date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
            // 没写年份而日期在将来：指的是去年。
            if year == nil, date > today {
                components.year = currentYear - 1
                guard let previous = calendar.date(from: components) else { return nil }
                date = previous
            }
            return date
        }

        // 完整日期：2026-11-06、2026/11/6、2026年11月6日。
        for match in matches(#"(\d{4})\s*[-/年.]\s*(\d{1,2})\s*[-/月.]\s*(\d{1,2})"#) {
            add(date(year: Int(match.groups[1]), month: Int(match.groups[2]) ?? 0, day: Int(match.groups[3]) ?? 0), at: match.position)
        }
        // 月日：11月6日、11 月 6 号。前面不能紧跟"年"（上一条已经处理）。
        for match in matches(#"(?<![\d年])(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?"#) {
            add(date(year: nil, month: Int(match.groups[1]) ?? 0, day: Int(match.groups[2]) ?? 0), at: match.position)
        }
        // 英文月份：November 11th、Nov 11, 2026、11 November、the 11th of November。
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let monthName = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?"#
        for match in matches(#"\b"# + monthName + #"\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s*(\d{4}))?"#) {
            guard let month = months.firstIndex(of: match.groups[1]) else { continue }
            add(date(year: Int(match.groups[3]), month: month + 1, day: Int(match.groups[2]) ?? 0), at: match.position)
        }
        for match in matches(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + monthName + #"(?:,?\s*(\d{4}))?"#) {
            guard let month = months.firstIndex(of: match.groups[2]) else { continue }
            add(date(year: Int(match.groups[3]), month: month + 1, day: Int(match.groups[1]) ?? 0), at: match.position)
        }
        // N 天前：3 天前、3天之前、3 days ago、3日前。
        for match in matches(#"(\d{1,2})\s*(?:天(?:之)?前|days?\s+ago|日前)"#) {
            if let n = Int(match.groups[1]), n > 0 { add(offset(-n), at: match.position) }
        }
        // 相对的某一天。长的写法在前（"大前天"包含"前天"）。
        let relative: [(String, Int)] = [
            ("大前天", -3), ("前天", -2), ("一昨日", -2), ("おととい", -2), ("day before yesterday", -2),
            ("昨天", -1), ("昨日", -1), ("昨晚", -1), ("yesterday", -1), ("last night", -1),
            ("今天", 0), ("今日", 0), ("今早", 0), ("今晚", 0), ("today", 0), ("this morning", 0), ("tonight", 0),
        ]
        var covered: [Range<String.Index>] = []
        for (word, days) in relative {
            var search = lower.startIndex..<lower.endIndex
            while let range = lower.range(of: word, range: search) {
                search = range.upperBound..<lower.endIndex
                if covered.contains(where: { $0.overlaps(range) }) { continue }
                covered.append(range)
                add(offset(days), at: lower.distance(from: lower.startIndex, to: range.lowerBound))
            }
        }
        // 星期几：周三、上周五、星期天。没有"上"时取最近的那一个（含今天）。
        let weekdays: [Character: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
        for match in matches(#"(上上|上|这|本)?(?:周|星期|礼拜)([一二三四五六日天])"#) {
            guard let weekday = match.groups[2].first.flatMap({ weekdays[$0] }) else { continue }
            let current = calendar.component(.weekday, from: today)
            var back = (current - weekday + 7) % 7
            if match.groups[1] == "上" || match.groups[1] == "上上" {
                // 上周的那一天：先回到本周一，再往前数。
                let sinceMonday = (current + 5) % 7
                let targetFromMonday = (weekday + 5) % 7
                back = sinceMonday + 7 - targetFromMonday + (match.groups[1] == "上上" ? 7 : 0)
            }
            add(offset(-back), at: match.position)
        }
        // 日文与英文的星期几：先週の金曜日、今週の水曜、金曜日；last Friday、this Wednesday、on Monday。
        // "上 / 先週 / last"指上一个自然周的那一天，"这 / 今週 / this"指本周的那一天，没有修饰时取最近的那一个（含今天）。
        func weekdayOffset(_ weekday: Int, _ modifier: String) -> Int {
            let current = calendar.component(.weekday, from: today)
            let sinceMonday = (current + 5) % 7
            let targetFromMonday = (weekday + 5) % 7
            switch modifier {
            case "last": return -(sinceMonday + 7 - targetFromMonday)
            case "lastlast": return -(sinceMonday + 14 - targetFromMonday)
            case "this": return targetFromMonday - sinceMonday
            default: return -((current - weekday + 7) % 7)
            }
        }
        var namedWeekday = false
        let japanese: [String: Int] = ["月": 2, "火": 3, "水": 4, "木": 5, "金": 6, "土": 7, "日": 1]
        for match in matches(#"(先々週|先週|今週)?の?([月火水木金土日])曜"#) {
            guard let weekday = japanese[match.groups[2]] else { continue }
            let modifier = ["先々週": "lastlast", "先週": "last", "今週": "this"][match.groups[1]] ?? ""
            namedWeekday = true
            add(offset(weekdayOffset(weekday, modifier)), at: match.position)
        }
        let english = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
        for match in matches(#"\b(?:(last|this|on)\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#) {
            guard let weekday = english[match.groups[2]] else { continue }
            namedWeekday = true
            add(offset(weekdayOffset(weekday, match.groups[1] == "on" ? "" : match.groups[1])), at: match.position)
        }
        if !matches(#"(?:周|星期|礼拜)[一二三四五六日天]"#).isEmpty { namedWeekday = true }
        result.days = found.sorted { $0.position < $1.position }.prefix(maxDays).map(\.day)

        // 一段时间。
        func weekStart(_ date: Date) -> Date {
            calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        }
        if let match = matches(#"(?:过去|最近|近|这|前)\s*(\d{1,2})\s*天|(?:last|past)\s+(\d{1,2})\s+days|(?:この|過去)\s*(\d{1,2})\s*日間"#).first,
           let count = match.groups.dropFirst().compactMap({ Int($0) }).first, count > 0 {
            let span = min(count, maxRangeDays)
            if let start = offset(-(span - 1)) { result.range = start...today }
        } else if !namedWeekday, ["这周", "本周", "这星期", "这个星期", "this week", "今週"].contains(where: lower.contains) {
            result.range = min(weekStart(today), today)...today
        } else if !namedWeekday, ["上周", "上星期", "上个星期", "last week", "先週"].contains(where: lower.contains),
                  let lastWeek = calendar.date(byAdding: .day, value: -7, to: weekStart(today)),
                  let end = calendar.date(byAdding: .day, value: 6, to: lastWeek) {
            result.range = lastWeek...end
        } else if ["这几天", "最近几天", "前几天", "过去几天", "past few days", "last few days", "ここ数日"].contains(where: lower.contains),
                  let start = offset(-4) {
            result.range = start...today
        }
        return result
    }
}

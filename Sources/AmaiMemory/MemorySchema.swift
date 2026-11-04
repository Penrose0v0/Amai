import AmaiCore
import Foundation

/// Memory Schema v1 的文件约定（ADR-0006）。
///
/// 每个分区文件是半结构化 Markdown：一级标题 + 用户可自由编写的内容 +
/// "## Amai 整理的记忆"下的 `amai:memory` 系统区块，区块内按 `### 小节` 分组。
/// 推荐小节只约束系统区块，不要求用户手写部分遵循。
///
/// 标题、区块标题与推荐小节随记忆语言写出；解析时三种语言的写法都认得，
/// 因此切换语言后已有条目会归到新语言的小节下，条目文字本身不翻译。
public enum MemorySchema {
    public static let version = 1

    // MARK: - 区块与文件标题

    public static let blockHeading = blockHeading(.zhHans)

    public static func blockHeading(_ lang: MemoryLanguage) -> String {
        lang.pick("## Amai 整理的记忆", "## Curated by Amai", "## Amai が整理した記憶")
    }

    public static let allBlockHeadings: Set<String> = Set(MemoryLanguage.allCases.map(blockHeading))

    public static func title(for category: MemoryCategory, language lang: MemoryLanguage = .zhHans) -> String {
        switch category {
        case .general: lang.pick("综合", "General", "総合")
        case .work: lang.pick("工作", "Work", "仕事")
        case .health: lang.pick("健康", "Health", "健康")
        case .finance: lang.pick("财务", "Finance", "財務")
        case .goals: lang.pick("目标", "Goals", "目標")
        case .daily: lang.pick("每日记录", "Daily", "日々の記録")
        }
    }

    /// 系统生成的一级标题（任一语言，以及 Schema v1 初版使用的英文名）。
    public static func isGeneratedTitle(_ title: String, for category: MemoryCategory) -> Bool {
        title == category.displayName || MemoryLanguage.allCases.contains { self.title(for: category, language: $0) == title }
    }

    // MARK: - 变更记录

    /// 系统区块中记录撤下与更新前内容的小节，不属于当前有效的记忆。
    public static let historySection = historySection(.zhHans)

    public static func historySection(_ lang: MemoryLanguage) -> String {
        lang.pick("变更记录", "Change history", "変更履歴")
    }

    public static func isHistory(_ section: String?) -> Bool {
        guard let section else { return false }
        return MemoryLanguage.allCases.contains { historySection($0) == section }
    }

    // MARK: - 推荐小节

    /// 推荐小节：稳定的键 + 三种语言的标题。
    public struct Section: Sendable, Equatable {
        public let key: String
        let names: [String]

        init(_ key: String, _ zh: String, _ en: String, _ ja: String) {
            self.key = key
            self.names = [zh, en, ja]
        }

        public func name(_ lang: MemoryLanguage) -> String { lang.pick(names[0], names[1], names[2]) }
        func matches(_ title: String) -> Bool { names.contains(title) }
    }

    public static let generalSectionList: [Section] = [
        Section("basics", "基本信息", "Basic information", "基本情報"),
        Section("education", "教育背景", "Education", "学歴"),
        Section("preferences", "个人偏好", "Preferences", "好み"),
        Section("status", "当前状态", "Current status", "現在の状況"),
        Section("work", "工作概况", "Work overview", "仕事の概要"),
        Section("health", "健康概况", "Health overview", "健康の概要"),
        Section("finance", "财务概况", "Finance overview", "財務の概要"),
        Section("goals", "目标概况", "Goals overview", "目標の概要"),
        Section("relationships", "重要关系", "Key relationships", "大切な人間関係"),
        Section("other", "其他", "Other", "その他"),
    ]
    public static let goalsSectionList: [Section] = [
        Section("long-term", "长期目标", "Long-term goals", "長期目標"),
        Section("plans", "计划", "Plans", "計画"),
        Section("done", "已完成", "Completed", "達成済み"),
        Section("decisions", "决策", "Decisions", "決定"),
    ]
    public static let healthSectionList: [Section] = [
        Section("metrics", "基本指标", "Basic metrics", "基本指標"),
        Section("concerns", "健康关注", "Health concerns", "気になること"),
        Section("exercise-diet", "运动与饮食", "Exercise and diet", "運動と食事"),
        Section("changes", "重要变化", "Notable changes", "大きな変化"),
        Section("diagnoses", "医学诊断", "Medical diagnoses", "医師の診断"),
    ]
    public static let financeSectionList: [Section] = [
        Section("income", "收入", "Income", "収入"),
        Section("expenses", "支出", "Expenses", "支出"),
        Section("assets", "资产", "Assets", "資産"),
        Section("investments", "投资", "Investments", "投資"),
        Section("decisions", "财务决策", "Financial decisions", "お金の決定"),
    ]

    /// General 系统区块的推荐小节（中文；按顺序渲染，不在其中的归入"其他"）。
    public static let generalSections = generalSections(.zhHans)

    public static func generalSections(_ lang: MemoryLanguage) -> [String] { generalSectionList.map { $0.name(lang) } }

    /// 把任一语言的推荐小节名换成目标语言；不是推荐小节（例如 Work 的项目名）时原样返回。
    public static func localizedSection(_ title: String, in list: [Section], to lang: MemoryLanguage) -> String {
        list.first { $0.matches(title) }?.name(lang) ?? title
    }

    /// 小节名对应的推荐小节键（任一语言）。
    public static func sectionKey(_ title: String?, in list: [Section]) -> String? {
        guard let title else { return nil }
        return list.first { $0.matches(title) }?.key
    }

    /// 旧 summary.md 小节 → General 小节。映射只改分组，不改条目内容。
    static let legacySummarySections: [String: String] = [
        "基本背景": "基本信息",
        "工作与研究": "工作概况",
        "习惯与偏好": "个人偏好",
        "长期目标": "目标概况",
        "重要关系": "重要关系",
        "其他": "其他",
    ]

    static func generalSection(forLegacy section: String?, language lang: MemoryLanguage = .zhHans) -> String {
        let other = localizedSection("其他", in: generalSectionList, to: lang)
        guard let section else { return other }
        if sectionKey(section, in: generalSectionList) != nil { return localizedSection(section, in: generalSectionList, to: lang) }
        return legacySummarySections[section].map { localizedSection($0, in: generalSectionList, to: lang) } ?? other
    }

    /// 旧版系统生成的骨架行：迁移时如果文件只剩这些，就没有需要搬运的用户内容。
    static let legacyGeneratedHeadings: Set<String> = Set(["## 记录", "## Amai 整理的长期记忆"]).union(allBlockHeadings)
}

import Foundation

/// Memory Schema v1 的文件约定（ADR-0006）。
///
/// 每个分区文件是半结构化 Markdown：一级标题 + 用户可自由编写的内容 +
/// "## Amai 整理的记忆"下的 `amai:memory` 系统区块，区块内按 `### 小节` 分组。
/// 推荐小节只约束系统区块，不要求用户手写部分遵循。
public enum MemorySchema {
    public static let version = 1
    public static let blockHeading = "## Amai 整理的记忆"

    public static func title(for category: MemoryCategory) -> String {
        category.displayName
    }

    /// General 系统区块的推荐小节（按顺序渲染，不在其中的归入"其他"）。
    public static let generalSections = [
        "基本信息", "教育背景", "个人偏好", "当前状态",
        "工作概况", "健康概况", "财务概况", "目标概况", "重要关系", "其他",
    ]

    /// 旧 summary.md 小节 → General 小节。映射只改分组，不改条目内容。
    static let legacySummarySections: [String: String] = [
        "基本背景": "基本信息",
        "工作与研究": "工作概况",
        "习惯与偏好": "个人偏好",
        "长期目标": "目标概况",
        "重要关系": "重要关系",
        "其他": "其他",
    ]

    static func generalSection(forLegacy section: String?) -> String {
        guard let section else { return "其他" }
        if generalSections.contains(section) { return section }
        return legacySummarySections[section] ?? "其他"
    }

    /// 旧版系统生成的骨架行：迁移时如果文件只剩这些，就没有需要搬运的用户内容。
    static let legacyGeneratedHeadings: Set<String> = ["## 记录", "## Amai 整理的长期记忆", blockHeading]
}

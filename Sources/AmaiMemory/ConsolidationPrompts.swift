import AmaiCore
import Foundation

// MARK: - Prompts

enum Prompts {
    static let digestSystem = """
    你在为用户整理一天的电脑活动记录。下面是当天的依据清单：用户本人写下的内容（S）、采集元数据（F）和屏幕活动的模型描述（I）。
    请输出 JSON，包含三部分：
    1. summary：2 到 3 句中文，概括这一天主要做了什么。
    2. highlights：3 到 5 条要点，每条一句话，写具体的项目、文档、事情，不要写泛泛的"处理了一些工作"。
    3. routes：逐一判断四个长期记忆分区今天是否可能有值得更新的新信息（新事实、进展、变化、决策、过时信息需要撤下），给出 update（true / false）和简短 reason：
       - work：研究、项目进展、工作决策、未解决的问题；
       - goals：长期目标、计划、计划或决策的变化、已完成的目标；
       - health：用户本人的睡眠、运动、饮食、身体状况、就医；
       - finance：用户本人的收入、支出、资产、投资、财务决策。
       路由只决定是否进一步整理，不会直接写入记忆。只要今天的记录中有可能相关的内容就填 true；明确没有相关内容才填 false。
       不要只看关键词：用户在笔记里提到的计划、身体状况或花销，即使用词不典型，也要判断进去。
    规则：用户写下的内容优先于系统推断；只依据记录，不要编造；不写密码、密钥、验证码等敏感信息。
    只输出 JSON。
    """

    static func digestUser(day: String, stats: Consolidator.DayStats, ledger: EvidenceLedger) -> String {
        """
        日期：\(day)
        统计（代码计算）：活跃 \(stats.activeMinutes) 分钟；\(stats.byCategory.map { "\(Consolidator.categoryLabel($0.0)) \($0.1) 分钟" }.joined(separator: "，"))
        依据清单：
        \(ledger.render())
        """
    }

    static func categorySystem(_ policy: CategoryPolicy) -> String {
        let name = policy.category.displayName
        let sections = policy.sections.map { "推荐小节（section 只能取这些）：\($0.joined(separator: "、"))。" }
            ?? "按项目分组：已有项目用 project 填项目 ID；新项目填 new:项目名。"
        let extra = policy.category == .work ? "\n- rename_project：项目改名，project 填 ID，text 填新名称（只在项目确实改名时使用）。" : ""
        return """
        你在维护用户的长期记忆分区 \(name)（\(policy.category.rawValue).md）。根据给出的依据，提出对已有条目的修改。
        准确性优先：用户不会检查或纠正这些记忆。证据不足时宁可不写；不要编造；推断不能写成确定事实。

        \(sections)
        \(policy.guidance)

        可用操作：
        - add：新增一条。text 为一句中文，evidence 填支持它的依据编号。
        - update：修改条目 #n（有了新进展、需要更正或补充）。text 为修改后的完整内容，evidence 填支持新内容的依据，reason 写原因。
        - retire：撤下条目 #n（已过时、已被新的可靠信息取代、或已不再成立）。evidence 填依据，reason 必填。
        - merge：合并重复的条目，items 填编号列表，text 为合并后的内容，不能加入新信息。\(extra)

        依据规则（系统会核对，违反的操作会被丢弃）：
        - 每个 add / update / retire 都必须引用依据编号。系统根据被引用依据的来源决定这条记忆是用户陈述、观察还是推断，你无法改变它。
        - 引用用户写下的内容（S、U）时，条目尽量沿用原话，不要加"用户表示""用户自述"之类的前缀或改写；加入原话里没有的推测会让条目被记为推断。
        - 采集元数据（F）只能支持"某时段使用了某应用"这类事实。
        - 已有条目标注了依据类型。不要用推断去修改或撤下 stated、observed 的条目；如果有同样可靠的新依据与之冲突，用 update 并写清原因。
        - 新信息与已有条目重复时不要新增，必要时 update 已有条目。
        - 一天之内的琐事、一次性事件不要记录。
        - 用户手写在分区文件里的内容（U）已经在文件中，不要重复新增。
        - 没有需要修改的内容时返回 {"operations": []}。

        字段：每个操作都必须给出全部字段，不用的填空字符串或空数组。\(policy.requiresSelf ? "\n本分区的 add / update 必须填 subject：self（用户本人的数据）、third_party（他人的）或 unclear（无法确定）。只有 self 会被写入。" : "")
        输出 JSON：{"operations":[{"op":"add","item":"","items":[],"section":"","project":"","text":"…","evidence":["S1"],"subject":"","amount":"","currency":"","date":"","date_type":"","reason":""}]}
        只输出 JSON。
        """
    }

    static func categoryUser(
        day: String, ledger: EvidenceLedger, items: [MemoryItem], history: [MemoryItem],
        projects: [String: [String: String]]?
    ) -> String {
        var parts = ["今天：\(day)", "", "依据清单：", ledger.render(), ""]
        if let projects {
            parts.append("已有项目：")
            if projects.isEmpty { parts.append("（无）") }
            for (name, meta) in projects.sorted(by: { $0.key < $1.key }) {
                let aliases = meta["aka"].map { "，曾用名：" + CategoryUpdater.aliases($0).joined(separator: "、") } ?? ""
                parts.append("- \(meta["project"] ?? "?") \(name)\(aliases)")
            }
            parts.append("")
        }
        parts.append("已有条目：")
        if items.isEmpty { parts.append("（无）") }
        for (i, item) in items.enumerated() {
            let section = item.section.map { "[\($0)] " } ?? ""
            let attrs = item.attributes.isEmpty ? "" : "；" + item.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            parts.append("#\(i + 1) \(section)\(item.text)（\(item.kind.rawValue)；来源 \(item.sources.joined(separator: ","))\(attrs)）")
        }
        if !history.isEmpty {
            parts.append("")
            parts.append("最近的变更记录（只读，供判断变化）：")
            for h in history.suffix(10) { parts.append("- \(h.text)") }
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Output schemas

/// 整理任务的输出 Schema。所有字段必填、不允许额外字段，
/// 同时满足 Anthropic `output_config.format` 与 OpenAI strict `json_schema` 的要求。
enum Schemas {
    private static let route = #"{"type":"object","properties":{"update":{"type":"boolean"},"reason":{"type":"string"}},"required":["update","reason"],"additionalProperties":false}"#

    static let digest = OutputSchema(name: "daily_digest", json: #"""
    {"type":"object","properties":{"summary":{"type":"string"},"highlights":{"type":"array","items":{"type":"string"}},"routes":{"type":"object","properties":{"work":\#(route),"goals":\#(route),"health":\#(route),"finance":\#(route)},"required":["work","goals","health","finance"],"additionalProperties":false}},"required":["summary","highlights","routes"],"additionalProperties":false}
    """#)

    private static let stringFields = ["op", "item", "section", "project", "text", "subject", "amount", "currency", "date", "date_type", "reason"]

    static let operations = OutputSchema(name: "memory_operations", json: {
        var props = stringFields.map { "\"\($0)\":{\"type\":\"string\"}" }
        props.append(#""items":{"type":"array","items":{"type":"string"}}"#)
        props.append(#""evidence":{"type":"array","items":{"type":"string"}}"#)
        let required = (stringFields + ["items", "evidence"]).map { "\"\($0)\"" }.joined(separator: ",")
        let op = "{\"type\":\"object\",\"properties\":{\(props.joined(separator: ","))},\"required\":[\(required)],\"additionalProperties\":false}"
        return "{\"type\":\"object\",\"properties\":{\"operations\":{\"type\":\"array\",\"items\":\(op)}},\"required\":[\"operations\"],\"additionalProperties\":false}"
    }())
}

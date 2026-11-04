import AmaiCore
import Foundation

// MARK: - Prompts

/// 整理提示词，按记忆语言整份切换（中文为原始版本）。JSON 字段名、依据编号与操作名不随语言变化。
enum Prompts {
    /// 默认（中文）版本，测试据此识别任务。
    static let digestSystem = digestSystem(.zhHans)

    static func digestSystem(_ lang: MemoryLanguage) -> String {
        lang.pick(
            """
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
            """,
            """
            You are organizing the user's computer activity for one day. Below is the day's evidence list: what the user wrote (S), capture metadata (F) and model descriptions of screen activity (I).
            Output JSON with three parts:
            1. summary: 2 to 3 English sentences on what the day was mainly about.
            2. highlights: 3 to 5 points, one sentence each, naming concrete projects, documents and things; avoid vague points like "handled some work".
            3. routes: for each of the four long-term memory categories, decide whether today may contain new information worth updating (new facts, progress, changes, decisions, or outdated information to retire). Give update (true / false) and a short reason:
               - work: research, project progress, work decisions, open questions;
               - goals: long-term goals, plans, changes to plans or decisions, completed goals;
               - health: the user's own sleep, exercise, diet, physical condition, medical visits;
               - finance: the user's own income, spending, assets, investments, financial decisions.
               Routing only decides whether to consolidate further; it never writes memory directly. Answer true whenever today's records may be relevant; answer false only when clearly nothing is.
               Do not rely on keywords alone: plans, health or spending mentioned in the user's notes count even if worded unusually.
            Rules: what the user wrote takes priority over system inferences; use only the records and do not invent anything; never include passwords, keys, verification codes or other sensitive information.
            Output only JSON.
            """,
            """
            ユーザーの 1 日分のパソコン活動を整理しています。以下はその日の根拠リストです：ユーザー本人が書いた内容（S）、記録メタデータ（F）、画面活動のモデルによる説明（I）。
            次の 3 つを含む JSON を出力してください：
            1. summary：その日に主に何をしたかを日本語 2〜3 文でまとめる。
            2. highlights：要点を 3〜5 個、各 1 文で。具体的なプロジェクト、文書、出来事を書き、「いくつかの作業をした」のような曖昧な書き方をしない。
            3. routes：4 つの長期記憶の分野それぞれについて、今日更新に値する新しい情報（新しい事実、進捗、変化、決定、取り下げるべき古い情報）がありそうかを判断し、update（true / false）と短い reason を付ける：
               - work：研究、プロジェクトの進捗、仕事上の決定、未解決の課題
               - goals：長期目標、計画、計画や決定の変更、達成した目標
               - health：ユーザー本人の睡眠、運動、食事、体調、受診
               - finance：ユーザー本人の収入、支出、資産、投資、お金に関する決定
               ルーティングはさらに整理するかを決めるだけで、記憶に直接書き込むことはない。今日の記録に関係しそうな内容があれば true、明らかに無関係なときだけ false にする。
               キーワードだけで判断しない：メモに書かれた計画、体調、出費は、言い回しが典型的でなくても含める。
            ルール：ユーザーが書いた内容はシステムの推測より優先する。記録だけに基づき、作り話をしない。パスワード、鍵、認証コードなどの機密情報は書かない。
            JSON だけを出力する。
            """
        )
    }

    static func digestUser(day: String, stats: Consolidator.DayStats, ledger: EvidenceLedger, language lang: MemoryLanguage = .zhHans) -> String {
        let cats = stats.byCategory.map {
            "\(Consolidator.categoryLabel($0.0, lang)) \($0.1)" + lang.pick(" 分钟", " min", " 分")
        }.joined(separator: lang.pick("，", ", ", "、"))
        return lang.pick(
            "日期：\(day)\n统计（代码计算）：活跃 \(stats.activeMinutes) 分钟；\(cats)\n依据清单：\n\(ledger.render(lang))",
            "Date: \(day)\nStatistics (computed): active \(stats.activeMinutes) min; \(cats)\nEvidence list:\n\(ledger.render(lang))",
            "日付：\(day)\n統計（コード計算）：アクティブ \(stats.activeMinutes) 分；\(cats)\n根拠リスト：\n\(ledger.render(lang))"
        )
    }

    static func categorySystem(_ policy: CategoryPolicy) -> String {
        let lang = policy.language
        let name = MemorySchema.title(for: policy.category, language: lang)
        let file = "\(policy.category.rawValue).md"
        let sections = policy.sections.map {
            lang.pick("推荐小节（section 只能取这些）：\($0.joined(separator: "、"))。",
                      "Recommended sections (section must be one of these): \($0.joined(separator: ", ")).",
                      "推奨セクション（section はこの中から選ぶ）：\($0.joined(separator: "、"))。")
        } ?? lang.pick("按项目分组：已有项目用 project 填项目 ID；新项目填 new:项目名。",
                       "Grouped by project: for an existing project put its ID in project; for a new project use new:Project name.",
                       "プロジェクトごとにまとめる：既存のプロジェクトは project にプロジェクト ID、新しいプロジェクトは new:プロジェクト名。")
        let extra = policy.category == .work
            ? lang.pick("\n- rename_project：项目改名，project 填 ID，text 填新名称（只在项目确实改名时使用）。",
                        "\n- rename_project: rename a project; put the ID in project and the new name in text (only when the project was really renamed).",
                        "\n- rename_project：プロジェクト名の変更。project に ID、text に新しい名前（本当に名前が変わったときだけ）。")
            : ""
        let subject = policy.requiresSelf
            ? lang.pick("\n本分区的 add / update 必须填 subject：self（用户本人的数据）、third_party（他人的）或 unclear（无法确定）。只有 self 会被写入。",
                        "\nIn this category, add / update must set subject: self (the user's own data), third_party (someone else's) or unclear (cannot tell). Only self is written.",
                        "\nこの分野の add / update では subject を必ず指定する：self（ユーザー本人のデータ）、third_party（他人のもの）、unclear（判断できない）。書き込まれるのは self だけ。")
            : ""
        let format = #"{"operations":[{"op":"add","item":"","items":[],"section":"","project":"","text":"…","evidence":["S1"],"subject":"","amount":"","currency":"","date":"","date_type":"","reason":""}]}"#
        return lang.pick(
            """
            你在维护用户的长期记忆分区 \(name)（\(file)）。根据给出的依据，提出对已有条目的修改。
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

            字段：每个操作都必须给出全部字段，不用的填空字符串或空数组。\(subject)
            输出 JSON：\(format)
            只输出 JSON。
            """,
            """
            You maintain the user's long-term memory category \(name) (\(file)). Based on the evidence given, propose changes to the existing entries.
            Accuracy first: the user will not review or correct these memories. When evidence is insufficient, write nothing; never invent; never write an inference as a confirmed fact.

            \(sections)
            \(policy.guidance)

            Available operations:
            - add: add an entry. text is one English sentence; evidence lists the IDs that support it.
            - update: change entry #n (new progress, a correction or an addition). text is the full new content, evidence supports the new content, reason explains why.
            - retire: retire entry #n (outdated, superseded by newer reliable information, or no longer true). evidence is required; reason is required.
            - merge: merge duplicate entries; items lists the entry numbers, text is the merged content and must not add new information.\(extra)

            Evidence rules (the system checks them; violating operations are discarded):
            - Every add / update / retire must cite evidence IDs. The system decides from the cited sources whether the memory is a user statement, an observation or an inference; you cannot change that.
            - When citing what the user wrote (S, U), keep close to their own words; do not add prefixes like "the user said" or rephrase. Adding speculation that is not in their words makes the entry count as an inference.
            - Capture metadata (F) can only support facts such as "used a certain app during a certain period".
            - Existing entries show their basis. Never use an inference to change or retire a stated or observed entry; if equally reliable new evidence conflicts with it, use update and explain why.
            - Do not add information that duplicates an existing entry; update the existing entry if needed.
            - Do not record trivial or one-off events within a single day.
            - Content the user wrote in the category file (U) is already there; do not add it again.
            - If nothing needs to change, return {"operations": []}.

            Fields: every operation must include all fields; use an empty string or empty array for unused ones.\(subject)
            Output JSON: \(format)
            Output only JSON.
            """,
            """
            あなたはユーザーの長期記憶の分野「\(name)」（\(file)）を管理しています。与えられた根拠に基づいて、既存の項目への変更を提案してください。
            正確さを最優先：ユーザーはこれらの記憶を確認・修正しない。根拠が不十分なら書かない。作り話をしない。推測を確定した事実として書かない。

            \(sections)
            \(policy.guidance)

            使える操作：
            - add：項目を追加する。text は日本語 1 文、evidence は裏付けとなる根拠番号。
            - update：項目 #n を変更する（進捗、訂正、補足）。text は変更後の全文、evidence は新しい内容の根拠、reason は理由。
            - retire：項目 #n を取り下げる（古くなった、新しい確かな情報に置き換わった、もう成り立たない）。evidence と reason は必須。
            - merge：重複した項目をまとめる。items に番号の一覧、text にまとめた内容。新しい情報を加えてはいけない。\(extra)

            根拠のルール（システムが確認し、違反した操作は破棄される）：
            - add / update / retire には必ず根拠番号を付ける。この記憶がユーザーの発言、観察、推測のどれにあたるかは、引用された根拠の出どころからシステムが決める。あなたには変えられない。
            - ユーザーが書いた内容（S、U）を引用するときは、できるだけ本人の言葉のままにし、「ユーザーによると」のような前置きや言い換えをしない。元の言葉にない推測を加えると推測として扱われる。
            - 記録メタデータ（F）が裏付けられるのは「ある時間帯にあるアプリを使った」という事実だけ。
            - 既存の項目には根拠の種類が付いている。stated や observed の項目を推測で変更・取り下げしない。同じくらい確かな新しい根拠と矛盾する場合は update を使い、理由を書く。
            - 既存の項目と重複する情報は追加しない。必要なら既存の項目を update する。
            - 1 日の中の細かな出来事や一度きりの出来事は記録しない。
            - ユーザーが分野のファイルに手書きした内容（U）はすでにファイルにあるので、重ねて追加しない。
            - 変更が不要なら {"operations": []} を返す。

            フィールド：どの操作にもすべてのフィールドを入れる。使わないものは空文字列か空配列にする。\(subject)
            出力する JSON：\(format)
            JSON だけを出力する。
            """
        )
    }

    static func categoryUser(
        day: String, ledger: EvidenceLedger, items: [MemoryItem], history: [MemoryItem],
        projects: [String: [String: String]]?, language lang: MemoryLanguage = .zhHans
    ) -> String {
        let none = lang.pick("（无）", "(none)", "（なし）")
        var parts = [lang.pick("今天：\(day)", "Today: \(day)", "今日：\(day)"), "", lang.pick("依据清单：", "Evidence list:", "根拠リスト："), ledger.render(lang), ""]
        if let projects {
            parts.append(lang.pick("已有项目：", "Existing projects:", "既存のプロジェクト："))
            if projects.isEmpty { parts.append(none) }
            for (name, meta) in projects.sorted(by: { $0.key < $1.key }) {
                let aliases = meta["aka"].map {
                    lang.pick("，曾用名：", ", formerly: ", "、旧名：") + CategoryUpdater.aliases($0).joined(separator: lang.pick("、", ", ", "、"))
                } ?? ""
                parts.append("- \(meta["project"] ?? "?") \(name)\(aliases)")
            }
            parts.append("")
        }
        parts.append(lang.pick("已有条目：", "Existing entries:", "既存の項目："))
        if items.isEmpty { parts.append(none) }
        for (i, item) in items.enumerated() {
            let section = item.section.map { "[\($0)] " } ?? ""
            let attrs = item.attributes.isEmpty ? "" : "; " + item.attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let sources = item.sources.joined(separator: ",")
            parts.append("#\(i + 1) \(section)\(item.text)" + lang.pick(
                "（\(item.kind.rawValue)；来源 \(sources)\(attrs)）", " (\(item.kind.rawValue); sources \(sources)\(attrs))", "（\(item.kind.rawValue)；出典 \(sources)\(attrs)）"
            ))
        }
        if !history.isEmpty {
            parts.append("")
            parts.append(lang.pick("最近的变更记录（只读，供判断变化）：", "Recent change history (read-only, for judging changes):", "最近の変更履歴（参照のみ、変化の判断用）："))
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

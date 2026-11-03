import AmaiCore
import CryptoKit
import Foundation

/// 每个分区的整理策略（ADR-0006 阶段 2）。
struct CategoryPolicy: Sendable {
    let category: MemoryCategory
    /// 推荐小节；nil 表示按项目分组（Work）。
    let sections: [String]?
    /// 改写条目内容时把旧内容记入"变更记录"。撤下条目总是记录。
    let historyOnUpdate: Bool
    /// 是否接受只有推断依据的条目。Health / Finance 不接受：屏幕上的推断无法确认是用户本人的数据。
    let allowsInferred: Bool
    /// 是否要求标明数据主体为用户本人。
    let requiresSelf: Bool
    /// 提示词中的分区规则。
    let guidance: String

    static let historySection = MemorySchema.historySection
    /// 变更记录最多保留的条数；更早的记录仍在快照中。
    static let historyLimit = 100

    static func policy(for category: MemoryCategory) -> CategoryPolicy {
        switch category {
        case .work:
            CategoryPolicy(
                category: .work, sections: nil, historyOnUpdate: false, allowsInferred: true, requiresSelf: false,
                guidance: """
                - 按项目或研究方向组织。已有项目用 project 字段填项目 ID（如 p-1a2b3c）；只有确实是新的持续项目时才填 new:项目名。
                - 只记录有长期价值的研究方向、项目进展、重要决策（写成"〔决策〕…"）和未解决问题（写成"〔待解决〕…"）；琐碎操作不要记录。
                - 进展有新进度时 update 原条目，而不是新增一条近似的条目。
                """
            )
        case .goals:
            CategoryPolicy(
                category: .goals, sections: ["长期目标", "计划", "已完成", "决策"],
                historyOnUpdate: true, allowsInferred: true, requiresSelf: false,
                guidance: """
                - 长期目标：用户想达成的长期方向。计划：具体打算与时间点。已完成：有依据表明已经做完的事。决策：重要选择及原因。
                - 区分目标、实际行动、已完成与未完成：没有完成的依据就不要写进"已完成"。
                - 计划或决策变化时用 update，reason 写清变化原因；系统会自动保留变化前的内容。
                - 推断出的目标要写成"似乎打算…"，不要写成用户确定的目标。
                """
            )
        case .health:
            CategoryPolicy(
                category: .health, sections: ["基本指标", "健康关注", "运动与饮食", "重要变化", "医学诊断"],
                historyOnUpdate: true, allowsInferred: false, requiresSelf: true,
                guidance: """
                - 只记录用户本人的健康信息。屏幕上出现的他人信息、新闻、科普文章、商品介绍都不是用户的数据：subject 填 third_party，系统会丢弃。无法确定是谁的，subject 填 unclear。
                - 健康关注写成"关注 / 担心 X"，不要写成"患有 X"。
                - "医学诊断"只记录用户明确说过的、由医生给出的诊断；不要根据症状、搜索或阅读内容推断诊断。
                - 区分用户自述（例如"我昨晚只睡了 4 小时"）与医学结论。
                """
            )
        case .finance:
            CategoryPolicy(
                category: .finance, sections: ["收入", "支出", "资产", "投资", "财务决策"],
                historyOnUpdate: true, allowsInferred: false, requiresSelf: true,
                guidance: """
                - 只记录用户本人的财务信息。屏幕上的商品价格、他人账户、新闻里的金额都不是用户的数据：subject 填 third_party。
                - 涉及金额时必须填 amount（数字）、currency（ISO 代码，如 JPY、CNY、USD）、date（YYYY-MM-DD）与 date_type：
                  transaction 表示交易发生日，as_of 表示余额 / 持仓等状态的截至日。缺任何一项系统都会丢弃该条目。
                - 记录日期由系统根据依据自动记录，不要把记录日期当作交易日期。
                """
            )
        case .general, .daily:
            CategoryPolicy(
                category: .general, sections: MemorySchema.generalSections,
                historyOnUpdate: true, allowsInferred: true, requiresSelf: false,
                guidance: """
                - 综合档案：对用户的整体理解，而不是各分区内容的副本。每个方面用一两条概括最重要、最稳定的信息。
                - 从各分区条目中归纳：跨多天反复出现、或由用户本人陈述的信息优先；一次性事件、细节进展不写。
                - 姓名、生日、邮箱、住址等基本信息只能来自用户陈述（U 或依据类型为 stated 的条目），没有就不写。
                - 推测出的习惯与偏好要写成"似乎""经常"。
                - 引用依据时填所依据的分区条目编号（M…）或摘要（D…）。
                """
            )
        }
    }
}

/// 模型返回的一个整理操作。所有字段都是字符串 / 数组（结构化输出要求全部必填），空值表示未使用。
struct MemoryOperation: Decodable, Sendable, Equatable {
    var op: String
    var item: String = ""
    var items: [String] = []
    var section: String = ""
    var project: String = ""
    var text: String = ""
    var evidence: [String] = []
    var subject: String = ""
    var amount: String = ""
    var currency: String = ""
    var date: String = ""
    var dateType: String = ""
    var reason: String = ""

    enum CodingKeys: String, CodingKey {
        case op, item, items, section, project, text, evidence, subject, amount, currency, date, reason
        case dateType = "date_type"
    }

    init(op: String, item: String = "", items: [String] = [], section: String = "", project: String = "", text: String = "",
         evidence: [String] = [], subject: String = "", amount: String = "", currency: String = "", date: String = "",
         dateType: String = "", reason: String = "") {
        self.op = op; self.item = item; self.items = items; self.section = section; self.project = project
        self.text = text; self.evidence = evidence; self.subject = subject; self.amount = amount
        self.currency = currency; self.date = date; self.dateType = dateType; self.reason = reason
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil)?.trimmingCharacters(in: .whitespaces) ?? "" }
        func list(_ k: CodingKeys) -> [String] {
            if let l = try? c.decodeIfPresent([String].self, forKey: k) { return l }
            if let s = try? c.decodeIfPresent(String.self, forKey: k), !s.isEmpty { return [s] }
            return []
        }
        op = str(.op).lowercased()
        item = str(.item); items = list(.items); section = str(.section); project = str(.project)
        text = str(.text); evidence = list(.evidence); subject = str(.subject).lowercased()
        amount = str(.amount); currency = str(.currency).uppercased(); date = str(.date)
        dateType = str(.dateType).lowercased(); reason = str(.reason)
    }
}

/// 一次分区整理的结果。
struct CategoryUpdateResult: Sendable, Equatable {
    var items: [MemoryItem]
    var sectionMeta: [String: [String: String]]
    var applied: [String] = []
    var rejected: [String] = []
    var changed: Bool { !applied.isEmpty }
    /// 撤下 / 合并造成的条目减少超过一半，整批拒绝。
    var lossGuardTripped = false
}

/// 把模型给出的操作应用到分区条目上。所有规则都在代码里：
/// 依据类型由引用推导（模型自称无效）、不得以弱依据覆盖或撤下强依据的条目、变化留痕、
/// 分区专属校验（主体、诊断措辞、金额要素）、防大量丢失。
struct CategoryUpdater {
    let policy: CategoryPolicy
    let ledger: EvidenceLedger
    let day: String
    var maxItemsPerSection = 40
    var maxNewProjects = 3
    var minRetainedFraction = 0.5

    /// 已有条目（不含变更记录）按顺序编号为 #1、#2…，与提示词中的编号一致。
    static func split(_ all: [MemoryItem]) -> (items: [MemoryItem], history: [MemoryItem]) {
        (all.filter { $0.section != CategoryPolicy.historySection }, all.filter { $0.section == CategoryPolicy.historySection })
    }

    func apply(_ operations: [MemoryOperation], to all: [MemoryItem], sectionMeta: [String: [String: String]]) -> CategoryUpdateResult {
        let (original, history) = Self.split(all)
        var slots: [MemoryItem?] = original
        var appended: [MemoryItem] = []
        var newHistory = history
        var meta = policy.sections == nil ? Self.ensureProjectIDs(original, meta: sectionMeta) : sectionMeta
        var result = CategoryUpdateResult(items: all, sectionMeta: meta)
        var removed = 0
        var newProjects = 0

        func index(_ ref: String) -> Int? {
            let digits = ref.filter(\.isNumber)
            guard let n = Int(digits), n >= 1, n <= slots.count, slots[n - 1] != nil else { return nil }
            return n - 1
        }
        func reject(_ op: MemoryOperation, _ why: String) {
            result.rejected.append("\(op.op) \(op.item.isEmpty ? op.text.prefix(30) : Substring(op.item))：\(why)")
        }
        func record(_ text: String, kind: MemoryEntryKind, sources: [String]) {
            newHistory.append(MemoryItem(text: text, sources: Array(Set(sources + [day])).filter(MemoryItems.isDate).sorted(), section: CategoryPolicy.historySection, kind: kind))
        }
        func count(in section: String) -> Int {
            (slots.compactMap { $0 } + appended).filter { $0.section == section }.count
        }

        for op in operations {
            switch op.op {
            case "add":
                let section: String
                if policy.sections == nil {
                    guard let resolved = resolveProject(op, meta: &meta, newProjects: &newProjects) else {
                        reject(op, "项目无法识别或今日新建项目已达上限"); continue
                    }
                    section = resolved
                } else {
                    guard let s = validSection(op.section) else { reject(op, "小节不在推荐结构中"); continue }
                    section = s
                }
                guard let candidate = candidate(op, section: section, reject: reject) else { continue }
                if let dup = (slots.compactMap { $0 } + appended).firstIndex(where: {
                    MemoryItems.normalize($0.text) == MemoryItems.normalize(candidate.text) && $0.kind == candidate.kind
                }) {
                    // 已有同一条：只合并来源，不新增。
                    let all = slots.compactMap { $0 } + appended
                    let target = all[dup]
                    if let i = slots.firstIndex(where: { $0 == target }) {
                        slots[i]?.sources = Array(Set(target.sources + candidate.sources)).sorted()
                    } else if let i = appended.firstIndex(of: target) {
                        appended[i].sources = Array(Set(target.sources + candidate.sources)).sorted()
                    }
                    result.applied.append("add(合并来源)")
                    continue
                }
                guard count(in: section) < maxItemsPerSection else { reject(op, "小节条目已达上限"); continue }
                appended.append(candidate)
                result.applied.append("add")

            case "update":
                guard let i = index(op.item), let old = slots[i] else { reject(op, "条目编号无效"); continue }
                guard var candidate = candidate(op, section: old.section ?? "", reject: reject) else { continue }
                guard candidate.kind.rank >= old.kind.rank else {
                    reject(op, "新依据（\(candidate.kind.rawValue)）弱于已有条目（\(old.kind.rawValue)），不覆盖"); continue
                }
                candidate.sources = Array(Set(old.sources + candidate.sources)).sorted()
                candidate.attributes = old.attributes.merging(candidate.attributes) { _, new in new }
                if policy.historyOnUpdate, MemoryItems.normalize(old.text) != MemoryItems.normalize(candidate.text) {
                    record("\(day) 更新：「\(old.text)」→「\(candidate.text)」" + (op.reason.isEmpty ? "" : "（\(Self.clean(op.reason))）"),
                           kind: candidate.kind, sources: candidate.sources)
                }
                slots[i] = candidate
                result.applied.append("update")

            case "retire":
                guard let i = index(op.item), let old = slots[i] else { reject(op, "条目编号无效"); continue }
                guard !op.reason.isEmpty else { reject(op, "撤下需要说明原因"); continue }
                guard old.kind != .confirmed else { reject(op, "用户确认过的条目不由整理撤下"); continue }
                guard let d = ledger.derive(text: Self.clean(op.reason), citing: op.evidence) else {
                    reject(op, "撤下没有可采纳的依据"); continue
                }
                // 推断可以撤下推断；观察到或用户陈述的事实只能由同等或更强的依据撤下。
                guard d.kind.rank >= old.kind.rank || old.kind.rank <= MemoryEntryKind.inferred.rank else {
                    reject(op, "依据（\(d.kind.rawValue)）弱于已有条目（\(old.kind.rawValue)），不撤下"); continue
                }
                record("\(day) 撤下：「\(old.text)」（\(Self.clean(op.reason))）", kind: d.kind, sources: old.sources + d.sources)
                slots[i] = nil
                removed += 1
                result.applied.append("retire")

            case "merge":
                let ids = op.items.compactMap(index)
                guard Set(ids).count >= 2, Set(ids).count == op.items.count else { reject(op, "合并需要至少两个有效编号"); continue }
                let group = Array(Set(ids)).sorted().compactMap { slots[$0] }
                guard Set(group.map(\.kind)).count == 1, Set(group.map { $0.section ?? "" }).count == 1 else {
                    reject(op, "只合并同一小节、依据类型相同的条目"); continue
                }
                let text = Self.clean(op.text)
                // 合并结果不能夹带被合并条目里没有的新内容。
                guard !text.isEmpty, EvidenceLedger.coverage(of: text, in: group.map(\.text).joined(separator: " ")) >= 0.6 else {
                    reject(op, "合并后的文字超出原条目内容"); continue
                }
                var attributes: [String: String] = [:]
                for g in group { attributes.merge(g.attributes) { old, _ in old } }
                let merged = MemoryItem(
                    text: text, sources: Array(Set(group.flatMap(\.sources))).sorted(),
                    section: group[0].section, kind: group[0].kind, attributes: attributes
                )
                let sorted = Array(Set(ids)).sorted()
                slots[sorted[0]] = merged
                for j in sorted.dropFirst() { slots[j] = nil }
                removed += sorted.count - 1
                result.applied.append("merge")

            case "rename_project":
                guard policy.sections == nil, let name = Consolidator.projectName(op.text),
                      let oldName = meta.first(where: { $0.value["project"] == op.project })?.key
                else { reject(op, "项目改名无效"); continue }
                guard oldName != name, meta[name] == nil else { reject(op, "新名称与已有项目重复"); continue }
                var m = meta.removeValue(forKey: oldName) ?? [:]
                m["aka"] = Self.joinAliases((m["aka"].map(Self.aliases) ?? []) + [oldName])
                meta[name] = m
                for i in slots.indices where slots[i]?.section == oldName { slots[i]?.section = name }
                for i in appended.indices where appended[i].section == oldName { appended[i].section = name }
                result.applied.append("rename_project")

            default:
                reject(op, "未知操作")
            }
        }

        if original.count >= 4, Double(original.count - removed) < Double(original.count) * minRetainedFraction {
            return CategoryUpdateResult(
                items: all, sectionMeta: sectionMeta, applied: [],
                rejected: result.rejected + ["一次撤下 / 合并 \(removed) 条，超过已有条目的一半，整批拒绝"],
                lossGuardTripped: true
            )
        }
        let kept = MemoryItems.merge(slots.compactMap { $0 } + appended)
        result.items = kept + Array(newHistory.suffix(CategoryPolicy.historyLimit))
        // 已无条目的项目不保留元数据（项目 ID 随小节消失，变更记录里仍有它的内容）。
        let live = Set(kept.compactMap(\.section))
        result.sectionMeta = meta.filter { live.contains($0.key) }
        if result.items == all && result.sectionMeta == sectionMeta { result.applied = [] }
        return result
    }

    // MARK: - Candidate

    /// 由一个 add / update 操作构造候选条目，并做依据与分区校验。
    private func candidate(_ op: MemoryOperation, section: String, reject: (MemoryOperation, String) -> Void) -> MemoryItem? {
        var text = Self.clean(op.text)
        guard !text.isEmpty else { reject(op, "空内容"); return nil }
        guard let d = ledger.derive(text: text, citing: op.evidence) else { reject(op, "没有可采纳的依据"); return nil }
        guard policy.allowsInferred || d.kind.rank >= MemoryEntryKind.observed.rank else {
            reject(op, "该分区不接受只有推断依据的条目"); return nil
        }
        if policy.requiresSelf, op.subject != "self" {
            reject(op, "不是用户本人的数据（subject=\(op.subject.isEmpty ? "未填" : op.subject)）"); return nil
        }
        var attributes: [String: String] = [:]
        switch policy.category {
        case .health:
            if section == "医学诊断" {
                guard d.kind == .stated else { reject(op, "医学诊断只接受用户本人陈述"); return nil }
            } else if Self.diagnosisPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                reject(op, "诊断性措辞只能出现在「医学诊断」"); return nil
            }
        case .finance:
            let hasAmount = !op.amount.isEmpty || Self.moneyPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            if hasAmount {
                guard let amount = Self.amount(op.amount), Self.isCurrency(op.currency), MemoryItems.isDate(op.date),
                      op.dateType == "transaction" || op.dateType == "as_of"
                else { reject(op, "金额缺少数值、币种、日期或日期类型"); return nil }
                attributes = ["amount": amount, "cur": op.currency, op.dateType == "transaction" ? "txn" : "asof": op.date]
                let label = op.dateType == "transaction" ? "交易日" : "截至"
                if !text.contains(op.date) { text += "（\(label) \(op.date)）" }
                if !text.uppercased().contains(op.currency) { text += "〔\(amount) \(op.currency)〕" }
            }
        default:
            break
        }
        return MemoryItem(text: text, sources: d.sources, section: section, kind: d.kind, attributes: attributes)
    }

    private func validSection(_ raw: String) -> String? {
        guard let sections = policy.sections else { return nil }
        let s = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#")))
        return sections.contains(s) ? s : nil
    }

    // MARK: - Work projects

    /// 给没有 ID 的项目补稳定 ID（由名字确定性生成，迁移来的小节第一次整理时获得 ID）。
    static func ensureProjectIDs(_ items: [MemoryItem], meta: [String: [String: String]]) -> [String: [String: String]] {
        var meta = meta
        var used = Set(meta.values.compactMap { $0["project"] })
        for name in items.compactMap(\.section) where meta[name]?["project"] == nil {
            let id = uniqueID(for: name, used: used)
            used.insert(id)
            meta[name, default: [:]]["project"] = id
        }
        return meta
    }

    static func uniqueID(for name: String, used: Set<String>) -> String {
        let hex = SHA256.hash(data: Data(MemoryItems.normalize(name).utf8)).map { String(format: "%02x", $0) }.joined()
        var id = "p-" + hex.prefix(6)
        var n = 2
        while used.contains(id) { id = "p-\(hex.prefix(6))\(n)"; n += 1 }
        return id
    }

    /// 解析 add 操作的项目：ID 精确匹配；`new:名称` 或纯名称先与已有名称、别名比对，
    /// 命中则并入已有项目，否则在当日上限内新建。
    private func resolveProject(_ op: MemoryOperation, meta: inout [String: [String: String]], newProjects: inout Int) -> String? {
        let raw = op.project.isEmpty ? op.section : op.project
        if let name = meta.first(where: { $0.value["project"] == raw })?.key { return name }
        let candidateName = raw.hasPrefix("new:") ? String(raw.dropFirst(4)) : raw
        guard let name = Consolidator.projectName(candidateName), !name.hasPrefix("p-") else { return nil }
        if let existing = Self.matchProject(name, meta: meta) { return existing }
        guard newProjects < maxNewProjects else { return nil }
        newProjects += 1
        meta[name] = ["project": Self.uniqueID(for: name, used: Set(meta.values.compactMap { $0["project"] }))]
        return name
    }

    /// 规范化后相等，或一方是另一方的前缀且较短的一方至少 4 个字符（"Amai" ↔ "Amai 项目进展"）。
    static func matchProject(_ name: String, meta: [String: [String: String]]) -> String? {
        let n = MemoryItems.normalize(name)
        guard !n.isEmpty else { return nil }
        for (existing, m) in meta.sorted(by: { $0.key < $1.key }) {
            for candidate in [existing] + (m["aka"].map(aliases) ?? []) {
                let c = MemoryItems.normalize(candidate)
                if c == n { return existing }
                let (short, long) = c.count < n.count ? (c, n) : (n, c)
                if short.count >= 4, long.hasPrefix(short) { return existing }
            }
        }
        return nil
    }

    static func aliases(_ raw: String) -> [String] { raw.split(separator: "|").map(String.init).filter { !$0.isEmpty } }
    static func joinAliases(_ list: [String]) -> String {
        var seen: [String] = []
        for a in list where !seen.contains(a) { seen.append(a.replacingOccurrences(of: "|", with: "/")) }
        return seen.joined(separator: "|")
    }

    // MARK: - Domain checks

    static let diagnosisPattern = try! NSRegularExpression(pattern: "确诊|诊断为|诊断出|被诊断|患有|罹患|得了.{0,6}(病|症|炎|癌)")
    static let moneyPattern = try! NSRegularExpression(
        pattern: #"\d[\d,，.]*\s*(万|千|亿)?\s*(元|円|日元|美元|人民币|欧元|英镑|块|JPY|CNY|USD|EUR|GBP)|[¥￥$€£]\s*\d"#,
        options: [.caseInsensitive]
    )

    static func amount(_ raw: String) -> String? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
        guard !cleaned.isEmpty, Double(cleaned) != nil else { return nil }
        return cleaned
    }

    static func isCurrency(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    static func clean(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .trimmingCharacters(in: .whitespaces)
        let text = flat.hasPrefix("- ") ? String(flat.dropFirst(2)) : flat
        return SecretRedactor.redact(String(text.prefix(MemoryItems.maxTextLength))).text
    }
}

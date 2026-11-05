import AmaiCore
import Foundation
import Testing
@testable import AmaiMemory

@Suite("Memory language")
struct MemoryLanguageTests {
    @Test("after switching to English, new and changed content is English; old entries keep their text under English headings")
    func switchToEnglish() async throws {
        let f = try ConsolidatorTests.Fixture()
        defer { f.cleanup() }
        await f.store.setLanguage(.en)
        await f.consolidator.setLanguage(.en)
        try f.write("goals.md", """
        # 目标

        ## Amai 整理的记忆

        <!-- amai:memory:begin · x -->
        ### 计划
        - 年底前完成 Amai MVP <!-- src:2026-10-10 kind:stated -->
        ### 变更记录
        - 2026-10-01 撤下：「学 Rust」（不再需要） <!-- src:2026-10-01 kind:stated -->
        <!-- amai:memory:end -->
        """)
        try await f.seedDay(notes: "Plan to submit the paper to UIST next April")
        f.model.digest = Responses.digest(routes: ["goals"])
        f.model.operations[.goals] = Responses.ops([
            ["op": "add", "section": "Plans", "text": "Plan to submit the paper to UIST next April", "evidence": ["S1"]],
            ["op": "retire", "item": "#1", "evidence": ["S1"], "reason": "Plan to submit the paper to UIST next April"],
        ])
        _ = try await f.consolidator.consolidateDay(f.day)

        // 提示词整份使用英文。
        #expect(f.model.systems.first == Prompts.digestSystem(.en))
        #expect(f.model.systems.contains { $0.hasPrefix("You maintain the user's long-term memory category Goals (goals.md)") })
        #expect(f.model.lastDigestPrompt.contains("Evidence list:"))
        #expect(f.model.lastDigestPrompt.contains("frontmost apps: Xcode"))

        let goals = try f.read("goals.md")
        #expect(goals.contains("### Plans\n- Plan to submit the paper to UIST next April <!-- src:2026-10-19 kind:stated -->"))
        #expect(goals.contains("### Change history"))
        // 旧记录与旧条目文字不翻译；新记录用英文。
        #expect(goals.contains("- 2026-10-01 撤下：「学 Rust」（不再需要）"))
        #expect(goals.contains(#"- 2026-10-19 Retired: "年底前完成 Amai MVP" (Plan to submit the paper to UIST next April)"#))
        #expect(!goals.contains("### 计划") && !goals.contains("### 变更记录"))
        #expect(goals.contains("amai:memory:begin · Maintained by Amai"))
        // 用户区与已有的区块标题不改。
        #expect(goals.hasPrefix("# 目标\n\n## Amai 整理的记忆\n"))

        let daily = try f.read("daily/2026-10-19.md")
        #expect(daily.contains("## Summary\n\n<!-- amai:digest:begin · Generated daily by Amai"))
        #expect(daily.contains("Active 1 h 30 min (work 1 h 0 min · research 30 min), 03:00–04:30."))
        #expect(daily.contains("## Timeline\n"))
        #expect(daily.firstRange(of: "## Summary")!.lowerBound < daily.firstRange(of: "## Timeline")!.lowerBound)
    }

    @Test("a new category file is created in the memory language")
    func newFileInJapanese() async throws {
        let f = try ConsolidatorTests.Fixture()
        defer { f.cleanup() }
        await f.consolidator.setLanguage(.ja)
        try await f.seedDay(notes: "11 月の家賃 85000 円を払った")
        f.model.digest = Responses.digest(routes: ["finance"])
        f.model.operations[.finance] = Responses.ops([
            ["op": "add", "section": "支出", "text": "11 月の家賃 85000 円を払った", "evidence": ["S1"], "subject": "self",
             "amount": "85000", "currency": "JPY", "date": "2026-10-19", "date_type": "transaction"],
        ])
        _ = try await f.consolidator.consolidateDay(f.day)
        let finance = try f.read("finance.md")
        #expect(finance.hasPrefix("# 財務\n\n## Amai が整理した記憶\n\n<!-- amai:memory:begin · Amai が日々の記録から"))
        // 中文的小节名也被接受，写出时换成日文。
        #expect(finance.contains("### 支出\n- 11 月の家賃 85000 円を払った（取引日 2026-10-19）〔85000 JPY〕"))
    }

    @Test("section names in any language map to the current language; unknown names are kept")
    func sections() {
        let policy = CategoryPolicy.policy(for: .health, language: .en)
        #expect(policy.sections == ["Basic metrics", "Health concerns", "Exercise and diet", "Notable changes", "Medical diagnoses"])
        #expect(policy.localize("健康关注") == "Health concerns")
        #expect(policy.localize("気になること") == "Health concerns")
        #expect(policy.localize("变更記録") == "变更記録")
        #expect(policy.localize("変更履歴") == "Change history")
        #expect(MemorySchema.isHistory("Change history") && MemorySchema.isHistory("变更记录"))
        #expect(MemorySchema.generalSection(forLegacy: "工作与研究", language: .ja) == "仕事の概要")
        #expect(MemorySchema.isGeneratedTitle("General", for: .general) && MemorySchema.isGeneratedTitle("総合", for: .general))
    }

    @Test("the low-confidence tag follows the language and is recognised in any language")
    func timeline() {
        let low = segment(0, 600, "Reading something", confidence: 0.3)
        #expect(TimelineBlock.render([low], timeZone: utc, language: .en).contains("[low confidence] Reading something"))
        let daily = "# d\n\n## Timeline\n\n<!-- amai:timeline:begin · x -->\n- 03:00–03:10 [low confidence] Reading something <!-- seg:A -->\n- 04:00–04:30 Writing code <!-- seg:B -->\n<!-- amai:timeline:end -->\n"
        let ledger = EvidenceLedger.forDay(day: "2026-10-19", daily: daily, segments: [], observations: [], timeZone: utc, language: .en)
        #expect(ledger.entries.map(\.text) == ["04:00–04:30 Writing code"])
        #expect(TimelineBlock.heading(in: daily) == "## Timeline")
    }

    @Test("English and Japanese diagnosis wording is kept out of non-diagnosis sections")
    func diagnosisWording() {
        for text in ["Diagnosed with mild anemia", "軽い貧血と診断された"] {
            #expect(CategoryUpdater.diagnosisPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
        }
        #expect(CategoryUpdater.moneyPattern.firstMatch(in: "paid 300 dollars", range: NSRange(location: 0, length: 16)) != nil)
    }

    @Test("the initial memory language follows the system once; a saved value is kept")
    func initialLanguage() throws {
        #expect(MemoryLanguage.initial(preferredLanguages: ["ja-JP", "en-US"]) == .ja)
        #expect(MemoryLanguage.initial(preferredLanguages: ["en-GB"]) == .en)
        #expect(MemoryLanguage.initial(preferredLanguages: ["zh-Hans-JP", "ja-JP"]) == .zhHans)
        #expect(MemoryLanguage.initial(preferredLanguages: ["fr-FR"]) == .zhHans)
        #expect(MemoryLanguage.initial(preferredLanguages: []) == .zhHans)

        let missing = try JSONDecoder().decode(MemoryConfiguration.self, from: Data(#"{"root":"~/m"}"#.utf8))
        #expect(!missing.languageIsExplicit && missing.language == .zhHans)
        let saved = try JSONDecoder().decode(MemoryConfiguration.self, from: Data(#"{"root":"~/m","language":"en"}"#.utf8))
        #expect(saved.languageIsExplicit && saved.language == .en)
        var changed = missing
        changed.language = .ja
        #expect(changed.languageIsExplicit)
        // 写回配置后再读，就不再是"未设置"。
        let roundTrip = try JSONDecoder().decode(MemoryConfiguration.self, from: JSONEncoder().encode(changed))
        #expect(roundTrip.languageIsExplicit && roundTrip.language == .ja)
    }
}

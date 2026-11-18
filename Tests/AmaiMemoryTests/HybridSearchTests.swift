import AmaiCore
import Foundation
import os
import Testing
@testable import AmaiMemory

/// 按"概念"生成向量的假模型：文字里出现某个概念的任何一种说法，对应的维度就是 1。
/// 这样"锻炼"与"跑步"虽然没有一个字相同，向量却接近——用来模拟语义检索，不需要真实的模型。
final class ConceptEmbedder: TextEmbedder, @unchecked Sendable {
    static let concepts: [[String]] = [
        ["锻炼", "跑步", "健身", "运动", "exercise"],
        ["睡", "休息", "失眠"],
        ["花", "钱", "元", "买", "cost"],
        ["论文", "投稿", "paper"],
        ["同步", "sync"],
    ]

    let identifier: String
    let similarityRange: ClosedRange<Float> = 0.1...0.9
    var isAvailable = true
    var fails = false
    var delay: Duration?
    private let counter = OSAllocatedUnfairLock(initialState: [String]())

    init(identifier: String = "fake:concepts") {
        self.identifier = identifier
    }

    /// 被要求计算向量的段落（不含问题）。
    var embeddedPassages: [String] { counter.withLock { $0 } }

    func embed(_ texts: [String], kind: TextEmbeddingKind) async throws -> [[Float]] {
        if let delay { try await Task.sleep(for: delay) }
        if fails { throw CancellationError() }
        if kind == .passage { counter.withLock { $0 += texts } }
        return texts.map { text in
            var vector = Self.concepts.map { words in words.contains { text.lowercased().contains($0) } ? Float(1) : 0 }
            // 没有命中任何概念的文字给一个固定的"无关"方向，避免零向量。
            vector.append(vector.allSatisfy { $0 == 0 } ? 1 : 0)
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return vector.map { $0 / norm }
        }
    }
}

private func isoDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Suite("Memory search text")
struct MemorySearchTextTests {
    @Test("index terms: lowercased words, Han bigrams, katakana runs")
    func indexTerms() {
        #expect(MemoryTerms.indexTerms("Lumen 的同步功能") == ["lumen", "的同", "同步", "步功", "功能"])
        #expect(MemoryTerms.indexTerms("买了 4K 显示器，花费 3200 元") == ["买了", "4k", "显示", "示器", "花费", "3200", "元"])
        #expect(MemoryTerms.indexTerms("ミーティングで報告") == ["ミーティング", "で", "報告"])
        #expect(MemoryTerms.indexTerms("ＡＢＣ　sqlite-vec ﾐｰﾃｨﾝｸﾞ") == ["abc", "sqlite", "vec", "ミーティング"])
    }

    @Test("query terms drop question words and particles but never come back empty for a real word")
    func queryTerms() {
        #expect(MemoryTerms.queryTerms("我的论文投到哪里了？") == ["论文", "文投"])
        #expect(MemoryTerms.queryTerms("显示器多少钱") == ["显示", "示器"])
        #expect(MemoryTerms.queryTerms("What did I report at the lab meeting?") == ["report", "lab", "meeting"])
        #expect(MemoryTerms.queryTerms("钱") == ["钱"])
        #expect(MemoryTerms.queryTerms("歯医者に行った？") == ["歯医", "医者", "行"])
        #expect(MemoryTerms.queryTerms("同步 同步 SYNC sync") == ["同步", "sync"])
        #expect(MemoryTerms.queryTerms("这是什么？").isEmpty)
    }

    @Test("chunks: one per bullet with its continuation lines, sub-headings become the chunk heading")
    func chunks() {
        let content = """
        ### Lumen
        - 放弃 CloudKit，改用自建同步服务
        - 修复时间戳比较错误
        补充：只影响离线合并
        ### Orbit
        - 搭建数据标注工具
        """
        let chunks = MemoryChunker.chunks(heading: "Amai 整理的记忆", content: content, startingAt: 3)
        #expect(chunks.map(\.heading) == ["Lumen", "Lumen", "Orbit"])
        #expect(chunks.map(\.content) == ["- 放弃 CloudKit，改用自建同步服务", "- 修复时间戳比较错误\n补充：只影响离线合并", "- 搭建数据标注工具"])
        #expect(chunks.map(\.position) == [3, 4, 5])

        // 没有列表的长段落按大小切开，每块不超过上限。
        let long = String(repeating: "这是一段很长的没有换行的手写笔记。", count: 60)
        let parts = MemoryChunker.chunks(heading: "笔记", content: long, startingAt: 0)
        #expect(parts.count > 1 && parts.allSatisfy { MemoryChunker.estimatedTokens($0.content) <= MemoryChunker.maxTokens })
        #expect(parts.map(\.content).joined() == long)
    }

    @Test("BM25 ranks map to 0…1 the way OpenClaw's bm25RankToScore does")
    func bm25() {
        #expect(MemoryIndex.score(bm25: -3) == 0.75)
        #expect(MemoryIndex.score(bm25: 0) == 1)
        #expect(MemoryIndex.score(bm25: .infinity) == 0.001)
        #expect(MemoryIndex.score(bm25: -9) > MemoryIndex.score(bm25: -1))
    }
}

@Suite("Hybrid memory search")
struct HybridSearchTests {
    struct Fixture {
        let root: URL
        let index: MemoryIndex
        let now = isoDate("2026-11-11T12:00:00Z")

        init() throws {
            root = try tempDir()
            try MemoryDirectory.ensureDirectories(at: root)
            index = MemoryIndex(root: root, database: try MemoryIndexDatabase.inMemory(), timeZone: utc)
            try write("work.md", "# Work\n\n## Amai 整理的记忆\n\n### Lumen\n- 放弃 CloudKit，改用自建同步服务 <!-- src:2026-11-06 -->\n### 论文\n- 论文投到了 CHI 2027 <!-- src:2026-11-10 -->\n")
            try write("health.md", "# Health\n\n## 运动\n\n- 每周在健身房跑步三次\n\n## 睡眠\n\n- 通常凌晨一点睡\n")
            try write("finance.md", "# Finance\n\n## 支出\n\n- 买显示器花了 3200 元\n")
            try write("daily/2026-11-10.md", "# 2026-11-10\n\n## 时间线\n\n- 10:00–11:30 提交 CHI 论文 <!-- seg:a conf:0.9 -->\n  在投稿系统里上传了终稿。\n- 14:00–15:00 回复邮件\n")
        }

        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        var options: MemorySearchOptions {
            var options = MemorySearchOptions()
            options.now = now
            return options
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("keyword search answers a natural-language question (the old phrase match could not)")
    func keywordOnly() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.index.refresh()
        // 旧的检索把整个问题当成一个短语去匹配，这样的问句一条也找不到。
        #expect(try await f.index.retrieve("我的论文投到哪里了").isEmpty)
        let hits = try await f.index.search("我的论文投到哪里了？", options: f.options)
        #expect(hits.first?.content == "- 论文投到了 CHI 2027")
        #expect(hits.first?.heading == "论文" && hits.first?.category == .work)
        #expect(hits.allSatisfy { $0.vectorScore == nil && $0.keywordScore != nil })
        // 注释（来源标记、片段 ID）不进入检索内容。
        #expect(hits.allSatisfy { !$0.content.contains("<!--") })
        // 措辞完全不同的问题，关键词无能为力。
        #expect(try await f.index.search("我最近锻炼了吗", options: f.options).isEmpty)
        #expect(try await f.index.search("这是什么？", options: f.options).isEmpty)
    }

    @Test("with vectors a paraphrased question finds the entry; hits on both legs rank above single-leg hits")
    func hybrid() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let embedder = ConceptEmbedder()
        try await f.index.refresh()
        #expect(try await f.index.embedPending(using: embedder) == 7)
        #expect(try await f.index.embeddingStatus(model: embedder.identifier) == .init(chunks: 7, embedded: 7))

        let exercise = try await f.index.search("我最近锻炼了吗", embedder: embedder, options: f.options)
        #expect(exercise.first?.content == "- 每周在健身房跑步三次")
        #expect(exercise.first?.keywordScore == nil && (exercise.first?.vectorScore ?? 0) > 0.9)

        let paper = try await f.index.search("论文投到哪里了", embedder: embedder, options: f.options)
        #expect(paper.first?.content == "- 论文投到了 CHI 2027")
        let both = try #require(paper.first)
        #expect(both.keywordScore != nil && both.vectorScore != nil)
        // 时间线里"提交 CHI 论文"只在语义上相关（没有共同的词组），排在后面但也被找到。
        #expect(paper.contains { $0.category == .daily && $0.content.contains("提交 CHI 论文") })
        #expect(paper.allSatisfy { $0.score <= both.score })

        // 分区过滤对两路都生效。
        var restricted = f.options
        restricted.categories = [.work, .daily]
        #expect(try await f.index.search("我最近锻炼了吗", embedder: embedder, options: restricted).isEmpty)
    }

    @Test("without a usable embedder the search falls back to keywords")
    func fallback() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let embedder = ConceptEmbedder()
        try await f.index.refresh()
        try await f.index.embedPending(using: embedder)

        embedder.isAvailable = false
        #expect(try await f.index.search("我最近锻炼了吗", embedder: embedder, options: f.options).isEmpty)
        #expect(try await f.index.search("论文投到哪里了", embedder: embedder, options: f.options).first?.vectorScore == nil)

        embedder.isAvailable = true
        embedder.fails = true
        #expect(try await f.index.search("论文投到哪里了", embedder: embedder, options: f.options).first?.content == "- 论文投到了 CHI 2027")

        // 问题的向量迟迟不来（模型在加载或在让路）：到时间就只用关键词，不让用户等。
        embedder.fails = false
        embedder.delay = .seconds(5)
        var options = f.options
        options.embeddingTimeout = 0.1
        let started = Date()
        let hits = try await f.index.search("论文投到哪里了", embedder: embedder, options: options)
        #expect(hits.first?.vectorScore == nil && Date().timeIntervalSince(started) < 2)

        // 索引里还没有向量（刚下载模型）：同样只用关键词。
        let fresh = try Fixture()
        defer { fresh.cleanup() }
        try await fresh.index.refresh()
        embedder.delay = nil
        #expect(try await fresh.index.search("论文投到哪里了", embedder: embedder, options: fresh.options).first?.vectorScore == nil)
    }

    @Test("vectors are computed once per content: edits re-embed only what changed, deletions are pruned")
    func embeddingCache() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let embedder = ConceptEmbedder()
        try await f.index.refresh()
        try await f.index.embedPending(using: embedder)
        #expect(embedder.embeddedPassages.count == 7)
        #expect(try await f.index.embedPending(using: embedder) == 0)

        // 给一个文件加一条：只有新的这一条需要计算。
        try f.write("health.md", "# Health\n\n## 运动\n\n- 每周在健身房跑步三次\n- 周末去爬山\n\n## 睡眠\n\n- 通常凌晨一点睡\n")
        try await f.index.refresh()
        #expect(try await f.index.embedPending(using: embedder) == 1)
        #expect(embedder.embeddedPassages.last == "运动\n- 周末去爬山")

        // 删掉文件：它的块和向量都清掉。
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("finance.md"))
        try await f.index.refresh()
        try await f.index.embedPending(using: embedder)
        #expect(try await f.index.embeddingStatus(model: embedder.identifier) == .init(chunks: 7, embedded: 7))

        // 换模型：旧模型的向量不参与比较，全部重新计算。
        let other = ConceptEmbedder(identifier: "fake:other")
        #expect(try await f.index.embeddingStatus(model: other.identifier).embedded == 0)
        #expect(try await f.index.embedPending(using: other) == 7)
        #expect(try await f.index.embeddingStatus(model: embedder.identifier).embedded == 0)

        // 全量重建后块还在、向量按内容哈希接上，不需要重算。
        try await f.index.rebuild()
        #expect(try await f.index.embedPending(using: other) == 0)
        #expect(try await f.index.embeddingStatus(model: other.identifier) == .init(chunks: 7, embedded: 7))
    }

    @Test("near-duplicate timeline entries are spread out; among equals the newer day comes first")
    func diversityAndRecency() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        for day in ["2026-09-01", "2026-11-08", "2026-11-09"] {
            try f.write("daily/\(day).md", "# \(day)\n\n## 时间线\n\n- 09:00–10:00 调试 Lumen 的同步冲突\n- 10:00–11:00 调试 Lumen 的同步冲突\n")
        }
        try await f.index.refresh()
        var options = f.options
        options.maxResults = 3
        let hits = try await f.index.search("Lumen 同步冲突", options: options)
        let days = hits.compactMap { $0.day.map { MemoryDirectory.dayName(for: $0, timeZone: utc) } }
        // 同分的内容里，近的日子排前面；时间只影响先后，两个月前的那天没有被排除。
        #expect(days.first == "2026-11-09")
        var all = options
        all.maxResults = 10
        let everything = try await f.index.search("Lumen 同步冲突", options: all)
        #expect(everything.contains { $0.day.map { MemoryDirectory.dayName(for: $0, timeZone: utc) } == "2026-09-01" })
        #expect(MemoryIndex.decay(day: isoDate("2026-09-01T00:00:00Z"), options: options) >= options.decayFloor)
        #expect(MemoryIndex.decay(day: nil, options: options) == 1)
    }
}

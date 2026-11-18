import AmaiCore
import Foundation
import Testing
@testable import AmaiInference

/// 用真实的向量模型验证语义检索的基本质量（跨语言、同义改写），并打印相似度分布供校准。
/// 与 MLX integration 一样默认跳过（需要 mlx.metallib 与已下载的模型）：
///
///   AMAI_MLX_INTEGRATION=1 swift test --filter EmbedderIntegration
///
/// 模型不在本地时，设 AMAI_EMBED_DOWNLOAD=1 先下载（约 470 MB，只连接 Hugging Face）。
@Suite("Embedder integration", .enabled(if: ProcessInfo.processInfo.environment["AMAI_MLX_INTEGRATION"] == "1"), .serialized)
struct EmbedderIntegrationTests {
    static let documents = [
        "修复了 Lumen 同步功能在离线重连后重复上传的问题，并补充了单元测试",
        "和导师讨论论文第三章的实验设计，决定增加消融实验",
        "晚上去健身房跑步 5 公里，之后做了拉伸",
        "更新官网首页文案和截图，准备下周发布",
        "购买了一台新的显示器，花费 3200 元",
        "阅读关于向量数据库和混合检索的文章",
        "Reviewed the pull request for the payment service refactor",
        "睡眠不足，只睡了五个小时，下午很困",
        "制定第四季度目标：完成 MVP 并邀请十位内测用户",
        "東京大学の研究室ミーティングで進捗を報告した",
    ]
    /// 问题 → 应当排第一的文档下标。措辞刻意与文档不重合，关键词检索帮不上忙。
    static let queries: [(String, Int)] = [
        ("我最近锻炼了吗", 2), ("买东西花了多少钱", 4), ("那个重复上传的 bug 修好了没", 0), ("和老师聊了什么", 1),
        ("semantic search reading", 5), ("昨晚休息得怎么样", 7), ("这个季度的计划是什么", 8), ("ゼミでの発表", 9),
        ("code review 支付", 6), ("网站改版进度", 3),
    ]

    @Test("multilingual retrieval ranks the paraphrased match first")
    func retrieval() async throws {
        let embedder = MLXTextEmbedder(modelTag: ProcessInfo.processInfo.environment["AMAI_EMBED_MODEL"] ?? MLXTextEmbedder.defaultModelTag)
        if !embedder.isAvailable, ProcessInfo.processInfo.environment["AMAI_EMBED_DOWNLOAD"] == "1" {
            for try await _ in LocalModelDownloader.download(tag: embedder.modelTag) {}
        }
        try #require(embedder.isAvailable)

        var started = Date()
        let documents = try await embedder.embed(Self.documents, kind: .passage)
        print("embedder: load + \(documents.count) passages in \(Int(Date().timeIntervalSince(started) * 1000)) ms, dim \(documents[0].count)")
        started = Date()
        let queries = try await embedder.embed(Self.queries.map(\.0), kind: .query)
        print("embedder: \(queries.count) queries in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        started = Date()
        _ = try await embedder.embed([Self.queries[0].0], kind: .query)
        print("embedder: 1 query warm in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        func cosine(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        var correct = 0
        var relevant: [Float] = []
        var unrelated: [Float] = []
        for (index, (text, expected)) in Self.queries.enumerated() {
            let scores = documents.map { cosine(queries[index], $0) }
            let best = scores.indices.max { scores[$0] < scores[$1] }!
            if best == expected { correct += 1 }
            relevant.append(scores[expected])
            unrelated += scores.enumerated().filter { $0.offset != expected }.map(\.element)
            print("embedder: \(text) → \(best) (expected \(expected)) \(scores.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        }
        unrelated.sort()
        print("embedder: relevant min \(relevant.min()!) mean \(relevant.reduce(0, +) / Float(relevant.count)); unrelated median \(unrelated[unrelated.count / 2]) p90 \(unrelated[unrelated.count * 9 / 10]) max \(unrelated.last!)")
        #expect(correct >= 8)
        #expect(abs(cosine(documents[0], documents[0]) - 1) < 0.01)
        await embedder.unload()
    }
}

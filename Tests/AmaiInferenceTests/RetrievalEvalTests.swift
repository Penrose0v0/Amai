import AmaiCore
import AmaiMemory
import Foundation
import Testing
@testable import AmaiInference

/// 记忆检索的质量评测：在一份合成的记忆库上比较"纯关键词"与"关键词 + 向量"两种方式。
/// 需要真实的向量模型，默认跳过：
///
///   AMAI_MLX_INTEGRATION=1 swift test --filter RetrievalEval
///
/// 数据全部是合成的（45 天的每日记录加五个长期记忆文件，约 400 个块）。
@Suite("Retrieval eval", .enabled(if: ProcessInfo.processInfo.environment["AMAI_MLX_INTEGRATION"] == "1"), .serialized)
struct RetrievalEvalTests {
    /// 只出现一次的事件（日期偏移，内容）。内容里方括号中的编号是评判用的标记，不参与检索的词很短，影响可以忽略。
    static let events: [(Int, String, String)] = [
        (3, "E01", "修复 Lumen 离线重连后重复上传附件的问题，补了三个单元测试"),
        (5, "E02", "和导师讨论论文第三章的实验设计，决定增加两组消融实验"),
        (6, "E03", "买了一台 27 寸 4K 显示器，花了 3200 元"),
        (8, "E04", "去牙科诊所洗牙，医生建议半年后复查智齿"),
        (9, "E05", "给 Orbit 标注工具加上批量导入 COCO 格式数据集的功能"),
        (11, "E06", "订了 12 月去京都的机票和三晚的旅馆"),
        (12, "E07", "把实验室官网首页改成响应式布局，手机上不再横向滚动"),
        (14, "E08", "读完 Raft 共识算法的论文，整理了领导者选举的笔记"),
        (15, "E09", "续订了 iCloud 2TB 套餐，每月 68 元"),
        (17, "E10", "参加组会，汇报多模态检索基线的结果，准确率提升 4 个点"),
        (18, "E11", "连续三天只睡了五个小时左右，下午明显犯困"),
        (20, "E12", "把后端从 Python 迁移到 Go，接口响应时间降了一半"),
        (22, "E13", "和房东确认明年房租上涨到每月 5800 元"),
        (23, "E14", "给妈妈过生日，订了一家粤菜馆的包间"),
        (25, "E15", "面试了一位申请实习的本科生，考了动态规划"),
        (27, "E16", "体检结果出来，血脂略高，医生让少吃油炸食品"),
        (28, "E17", "在 GitHub 上给 GRDB 提了一个关于 FTS5 分词器的 issue"),
        (30, "E18", "把毕业论文的开题报告初稿发给了导师"),
        (33, "E19", "MacBook 电池健康度降到 79%，预约了天才吧更换"),
        (36, "E20", "学做了一次红烧牛腩，炖了两个小时"),
        (38, "E21", "决定 Lumen 不用 CloudKit，改为自建同步服务，因为要支持 Android"),
        (40, "E22", "报名了明年三月的东京马拉松"),
        (41, "E23", "调研了 sqlite-vec 和 FAISS，记了一页对比"),
        (43, "E24", "退订了很少看的视频会员，每年省下 258 元"),
    ]
    /// 反复出现的日常。
    static let routines = [
        "写 Lumen 的同步模块代码，调试冲突合并逻辑",
        "在 VS Code 里改 Orbit 标注工具的前端界面",
        "阅读 arXiv 上关于多模态模型的新论文",
        "晚上在健身房跑步 5 公里，然后拉伸",
        "回复邮件和 Slack 消息",
        "在 B 站看技术分享视频",
        "整理本周的待办事项和进度",
        "和同学在微信上讨论课程作业",
        "浏览 Hacker News 和技术博客",
        "做午饭，顺便听播客",
        "用 Figma 调整官网的配色和排版",
        "跑实验并在表格里记录结果",
    ]
    /// （问题，应当找到的事件编号，类型）
    static let queries: [(String, String, String)] = [
        ("重复上传的问题修好了吗", "E01", "keyword"), ("显示器多少钱", "E03", "keyword"),
        ("Raft 论文的笔记", "E08", "keyword"), ("iCloud 套餐每月多少钱", "E09", "keyword"),
        ("后端迁移到 Go 的效果", "E12", "keyword"), ("东京马拉松", "E22", "keyword"),
        ("sqlite-vec 和 FAISS 的对比", "E23", "keyword"), ("开题报告发给谁了", "E18", "keyword"),
        ("我最近看牙医了吗", "E04", "paraphrase"), ("年底的旅行安排", "E06", "paraphrase"),
        ("网站在手机上的显示问题解决了没", "E07", "paraphrase"), ("最近休息得怎么样", "E11", "paraphrase"),
        ("明年住房的开销会变吗", "E13", "paraphrase"), ("家人的庆祝活动", "E14", "paraphrase"),
        ("招人的事情有什么进展", "E15", "paraphrase"), ("我的健康检查有什么需要注意的", "E16", "paraphrase"),
        ("笔记本电脑要送修吗", "E19", "paraphrase"), ("最近下厨做了什么菜", "E20", "paraphrase"),
        ("为什么不用苹果的云服务做同步", "E21", "paraphrase"), ("取消了哪些订阅", "E24", "paraphrase"),
        ("和老师聊了论文的什么内容", "E02", "paraphrase"), ("给开源项目反馈过什么问题", "E17", "paraphrase"),
        ("what did I report at the lab meeting", "E10", "cross-lingual"), ("dataset import feature for the labeling tool", "E05", "cross-lingual"),
        ("how much did the monitor cost", "E03", "cross-lingual"), ("歯医者に行った？", "E04", "cross-lingual"),
    ]
    /// 与记忆无关的问题：理想情况下什么都不返回。
    static let unrelated = [
        "把这句话翻译成英文", "Swift 里 actor 和 class 有什么区别", "写一首关于秋天的诗", "解释一下这段代码的意思",
        "What is the capital of France", "帮我润色这封邮件", "1 加 1 等于几", "这个单词是什么意思",
    ]

    static let now = ISO8601DateFormatter().date(from: "2026-11-18T03:00:00Z")!
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!

    static func makeCorpus(at root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("daily"), withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var seed: UInt64 = 42
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for offset in 1...45 {
            let day = calendar.date(byAdding: .day, value: -offset, to: now)!
            let name = MemoryDirectory.dayName(for: day, timeZone: timeZone)
            var entries = (0..<6).map { _ in routines[random(routines.count)] }
            for event in events where event.0 == offset { entries.insert("\(event.2)〔\(event.1)〕", at: random(entries.count)) }
            var lines = ["# \(name)", "", "## 时间线", ""]
            for (index, entry) in entries.enumerated() {
                lines.append("- \(String(format: "%02d", 9 + index)):00–\(String(format: "%02d", 10 + index)):00 \(entry) <!-- seg:\(index) conf:0.80 -->")
            }
            try lines.joined(separator: "\n").write(to: root.appendingPathComponent("daily/\(name).md"), atomically: true, encoding: .utf8)
        }
        let documents: [String: String] = [
            "work.md": "# Work\n\n## Amai 整理的记忆\n\n### Lumen\n- 笔记应用，正在开发离线同步\n- 〔待解决〕导出时附件路径如何处理\n### Orbit\n- 数据标注工具，前端用 React\n### 实验室官网\n- 负责改版首页与成员列表\n",
            "general.md": "# General\n\n## 背景\n\n- 博士二年级，研究方向是多模态检索\n- 住在东京，习惯晚上工作\n\n## 偏好\n\n- 写代码用 VS Code，偏好深色主题\n- 喜欢粤菜和日料\n",
            "health.md": "# Health\n\n## 运动\n\n- 每周跑步三次，每次约 5 公里\n\n## 睡眠\n\n- 通常凌晨一点睡，八点起\n",
            "finance.md": "# Finance\n\n## 固定支出\n\n- 房租每月 5500 元\n- 手机套餐每月 99 元\n",
            "goals.md": "# Goals\n\n## 长期目标\n\n- 明年六月前完成博士论文开题\n- 年内发布 Lumen 的第一个公开版本\n",
        ]
        for (file, text) in documents {
            try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    @Test("hybrid search beats keyword-only on paraphrased and cross-lingual questions")
    func compare() async throws {
        let embedder = MLXTextEmbedder(modelTag: ProcessInfo.processInfo.environment["AMAI_EMBED_MODEL"] ?? MLXTextEmbedder.defaultModelTag)
        try #require(embedder.isAvailable)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amai-retrieval-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeCorpus(at: root)
        let index = MemoryIndex(root: root, database: try .inMemory(), timeZone: Self.timeZone)
        var started = Date()
        try await index.refresh()
        print("eval: indexed in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        started = Date()
        let embedded = try await index.embedPending(using: embedder)
        print("eval: embedded \(embedded) chunks in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        var options = MemorySearchOptions()
        options.now = Self.now
        var summary: [String: [String: (hit1: Int, hit6: Int, total: Int)]] = [:]
        var latency: [String: [Double]] = [:]
        for (mode, model) in [("keyword", nil), ("hybrid", embedder)] as [(String, MLXTextEmbedder?)] {
            for (question, marker, kind) in Self.queries {
                let started = Date()
                let hits = try await index.search(question, embedder: model, options: options)
                latency[mode, default: []].append(Date().timeIntervalSince(started) * 1000)
                let rank = hits.firstIndex { $0.content.contains(marker) }
                var entry = summary[mode, default: [:]][kind] ?? (0, 0, 0)
                entry.total += 1
                if rank == 0 { entry.hit1 += 1 }
                if rank != nil { entry.hit6 += 1 }
                summary[mode, default: [:]][kind] = entry
                if rank == nil || ProcessInfo.processInfo.environment["AMAI_EVAL_VERBOSE"] == "1" {
                    var wide = options
                    wide.minScore = 0
                    wide.maxResults = 400
                    wide.mmrLambda = 1
                    let all = try await index.search(question, embedder: model, options: wide)
                    func describe(_ hit: MemoryChunkHit?) -> String {
                        guard let hit else { return "-" }
                        return String(format: "s=%.2f v=%.2f k=%.2f", hit.score, hit.vectorScore ?? -1, hit.keywordScore ?? -1)
                    }
                    let position = all.firstIndex { $0.content.contains(marker) }
                    print("eval: [\(mode)] \(rank == nil ? "miss" : "hit@\(rank!)"): \(question) → target rank \(position.map(String.init) ?? "none") \(describe(position.map { all[$0] })); top \(describe(all.first)) \(all.first.map { String($0.content.prefix(24)) } ?? "")")
                }
            }
            var noise = 0
            for question in Self.unrelated {
                let hits = try await index.search(question, embedder: model, options: options)
                noise += hits.count
                if !hits.isEmpty { print("eval: [\(mode)] noise: \(question) → \(hits.count) e.g. \(String(format: "%.2f", hits[0].score)) \(hits[0].content.prefix(30))") }
            }
            for (kind, entry) in summary[mode]!.sorted(by: { $0.key < $1.key }) {
                print("eval: [\(mode)] \(kind): top1 \(entry.hit1)/\(entry.total), top6 \(entry.hit6)/\(entry.total)")
            }
            let sorted = latency[mode]!.sorted()
            print("eval: [\(mode)] unrelated questions returned \(noise) chunks in total (\(Self.unrelated.count) questions); latency median \(Int(sorted[sorted.count / 2])) ms, max \(Int(sorted.last!)) ms")
        }
        func total(_ mode: String) -> Int { summary[mode]!.values.reduce(0) { $0 + $1.hit6 } }
        #expect(total("hybrid") > total("keyword"))
        #expect(total("hybrid") >= Self.queries.count * 9 / 10)
        await embedder.unload()
    }
}

import AmaiAssistant
import AmaiCloud
import AmaiCore
import AmaiExtraction
import AmaiMemory
import AmaiQAEval
import Foundation

// amai-memory qa-eval：真实记忆问答评测（docs/qa-eval.md）。
//
//   qa-eval prepare  --workdir <目录> [--memory <真实记忆目录>]   复制真实记忆为只读副本（只读取源目录一次，不写）
//   qa-eval generate --workdir <目录> [--claude <路径>] [--model opus] [--count 100] [--seed N]
//   qa-eval run      --workdir <目录> [--answer-model <标签>]      本地模型经 AssistantSession 作答
//   qa-eval judge    --workdir <目录> [--judge <标签>]             独立的本地 Judge
//   qa-eval report   --workdir <目录>
//   qa-eval retrieval / gt-sheet / gt-import  检索的独立评测与人工 GT 标注（docs/qa-eval.md「检索评测」）
//
// 终端输出不含任何记忆正文：只有计数、比例与耗时。正文只写进工作目录里的文件。

enum QAEvalCommand {
    static let usage = """
    用法：
      amai-memory qa-eval prepare  --workdir <目录> [--memory <记忆目录>]
      amai-memory qa-eval generate --workdir <目录> [--claude <claude 路径>] [--model opus] [--count 100] [--seed N]
      amai-memory qa-eval run      --workdir <目录> [--answer-model <本地模型标签>]
      amai-memory qa-eval judge    --workdir <目录> [--judge <本地纯文本模型标签>]
      amai-memory qa-eval report   --workdir <目录>
      amai-memory qa-eval retrieval --workdir <目录> [--gt human|provisional] [--baseline <优化前的 runs.jsonl>]
                                    只评测检索，不调用回答模型；给出 --baseline 时在同一份 GT 上对比
      amai-memory qa-eval gt-sheet  --workdir <目录> [--all]                    生成人工标注检索 GT 的本地网页（默认约 30 道的固定子集）
      amai-memory qa-eval gt-import --workdir <目录> --file <导出的 JSON> [--annotator <名字>]
    工作目录必须在仓库、真实记忆目录与 App 数据目录之外。run / judge 需要可执行文件旁有 mlx.metallib。
    """

    static let defaultJudge = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Amai", isDirectory: true)

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main(_ arguments: [String]) async -> Int32 {
        var args = arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let value = args[i + 1]
            args.removeSubrange(i...(i + 1))
            return value
        }
        func path(_ text: String) -> URL { URL(fileURLWithPath: (text as NSString).expandingTildeInPath) }
        guard let sub = args.first, let workdir = option("--workdir") else {
            print(usage)
            return 1
        }
        let workspace = QAWorkspace(root: path(workdir))
        do {
            switch sub {
            case "prepare":
                let source = option("--memory").map(path) ?? MemoryDirectory.defaultRootURL
                let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                let manifest = try workspace.prepare(from: source, protected: [appSupport, repo])
                print("已复制 \(manifest.files.count) 个记忆文件到只读副本；摘要 \(manifest.digest.prefix(16))")
            case "generate":
                try await generate(
                    workspace, claude: option("--claude"), model: option("--model") ?? ClaudeCodeClient.defaultModel,
                    count: option("--count").flatMap(Int.init) ?? 100,
                    seed: option("--seed").flatMap(UInt64.init) ?? 20_261_119
                )
            case "run":
                try await run(workspace, answerModel: option("--answer-model"))
            case "judge":
                try await judge(workspace, tag: option("--judge") ?? defaultJudge)
            case "report":
                try report(workspace)
            case "retrieval":
                try await retrieval(workspace, gt: option("--gt"), baseline: option("--baseline").map(path))
            case "gt-sheet":
                try await gtSheet(workspace, all: args.contains("--all"))
            case "gt-import":
                guard let file = option("--file") else { print(usage); return 1 }
                try gtImport(workspace, file: path(file), annotator: option("--annotator"))
            default:
                print(usage)
                return 1
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
            return 2
        }
    }

    // MARK: - generate

    struct ClaudeQuestionModel: QAQuestionModel {
        let client: ClaudeCodeClient
        var identifier: String { client.identifier }
        var sendsDataOffDevice: Bool { true }

        func generate(system: String, user: String, schemaJSON: String) async throws -> String {
            try await client.generate(CloudRequest(
                system: system, user: user, maxTokens: 8000, schemaName: "qa_questions", schemaJSON: schemaJSON
            )).text
        }
    }

    static func generate(_ workspace: QAWorkspace, claude: String?, model: String, count: Int, seed: UInt64) async throws {
        guard !FileManager.default.fileExists(atPath: workspace.dataset.path) else {
            throw Failure("dataset.json 已存在；题目一旦生成就不再改动。要重新出题请换一个工作目录")
        }
        let manifest = try workspace.loadManifest()
        let timeZone = TimeZone(identifier: manifest.timeZone) ?? .current
        guard let executable = ClaudeCodeLocator.locate(configured: claude) else { throw Failure("找不到 claude 可执行文件，用 --claude 指定") }
        let catalog = try EvidenceCatalog.build(root: workspace.memory, timeZone: timeZone)
        var planner = QAPlanner(catalog: catalog, now: manifest.createdAt, timeZone: timeZone, seed: seed)
        let slots = planner.plan(.scaled(to: count))
        print("证据条目 \(catalog.units.count) 条，有记录的日期 \(catalog.days.count) 天；计划 \(slots.count) 个槽位、\(slots.reduce(0) { $0 + $1.turns }) 道题")
        let generator = QAGenerator(
            catalog: catalog,
            model: ClaudeQuestionModel(client: ClaudeCodeClient(
                executable: executable, model: model, workingDirectory: workspace.generatorWorkdir, timeout: 600
            )),
            now: manifest.createdAt, timeZone: timeZone
        )
        let output = await generator.run(slots, planner: &planner) { print($0) }
        let referenced = Set(output.items.flatMap { $0.evidence + $0.context })
        let dataset = QADataset(
            createdAt: Date(), now: manifest.createdAt, timeZone: timeZone.identifier, memoryDigest: manifest.digest,
            seed: seed, evidence: catalog.units.filter { referenced.contains($0.id) }, items: output.items,
            egress: output.egress, unfilledSlots: output.unfilled.count
        )
        try encoder().encode(dataset).write(to: workspace.dataset)
        let byType = Dictionary(grouping: output.items, by: \.type.rawValue).mapValues(\.count)
        print("已生成 \(output.items.count) 道题：" + byType.keys.sorted().map { "\($0) \(byType[$0]!)" }.joined(separator: "，"))
        print("未能出题的槽位 \(output.unfilled.count) 个；被拒绝的草稿：" + output.rejections.keys.sorted().map { "\($0) \(output.rejections[$0]!)" }.joined(separator: "，"))
        let e = output.egress
        print("发往 \(e.generator)：\(e.calls) 次调用，证据 \(e.evidenceUnitsSent)/\(e.evidenceUnitsTotal) 条，\(e.charactersSent) 字符，脱敏 \(e.redactions) 处")
    }

    // MARK: - run

    struct RunInfo: Codable {
        var answerer: String
        var embedder: String
        var embedderAvailable: Bool
        var language: String
        var categories: [String]
        var embeddedChunks: Int
        var indexMs: Int
        var modelLoadMs: Int
        var startedAt: Date
        var finishedAt: Date?
        var copyVerified: Bool
    }

    /// 只读地取 App 配置里的助手模型、可读分区与记忆语言。不写配置。
    static func appAssistantSettings() -> (tag: String?, cloud: Bool, categories: [MemoryCategory], language: MemoryLanguage) {
        let url = appSupport.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, false, [.general, .work, .goals, .daily], .default)
        }
        let assistant = root["assistant"] as? [String: Any] ?? [:]
        let agent = assistant["agent"] as? [String: Any]
        let mode = (agent?["source"] as? [String: Any])?["mode"] as? String ?? "local"
        let categories = (assistant["memoryCategories"] as? [String])?.compactMap(MemoryCategory.init(rawValue:))
            ?? [.general, .work, .goals, .daily]
        let language = ((root["memory"] as? [String: Any])?["language"] as? String).flatMap(MemoryLanguage.init(rawValue:)) ?? .default
        return (agent?["localModelTag"] as? String, mode != "local", categories, language)
    }

    static func run(_ workspace: QAWorkspace, answerModel: String?) async throws {
        let dataset = try loadDataset(workspace)
        guard try workspace.verifyCopy() == dataset.memoryDigest else { throw Failure("记忆副本与出题时不是同一份") }
        let settings = appAssistantSettings()
        if answerModel == nil, settings.cloud {
            throw Failure("App 的助手当前使用云端模型；评测不会把真实记忆发往云端。用 --answer-model 指定本地模型")
        }
        guard let tag = answerModel ?? settings.tag else { throw Failure("App 没有配置助手模型，用 --answer-model 指定") }
        guard LocalInferenceBackend.isInstalled(tag: tag) else { throw Failure("本地模型未下载：\(tag)") }

        let languageName = switch settings.language {
        case .zhHans: "Chinese"
        case .en: "English"
        case .ja: "Japanese"
        }
        let indexStarted = Date()
        let index = MemoryIndex(root: workspace.memory, database: try MemoryIndexDatabase(path: workspace.indexDatabase.path))
        try await index.refresh()
        let embedder = MLXTextEmbedder()
        var embedded = 0
        if embedder.isAvailable {
            while true {
                let n = try await index.embedPending(using: embedder)
                embedded += n
                if n == 0 { break }
            }
        }
        let model = MLXChatModel(modelTag: tag)
        let loadStarted = Date()
        await model.prepare(ChatRequest(system: "warm up", messages: []))
        var info = RunInfo(
            answerer: model.identifier, embedder: embedder.isAvailable ? embedder.identifier : "none (keyword only)",
            embedderAvailable: embedder.isAvailable, language: languageName, categories: settings.categories.map(\.rawValue),
            embeddedChunks: embedded, indexMs: Int(loadStarted.timeIntervalSince(indexStarted) * 1000),
            modelLoadMs: Int(Date().timeIntervalSince(loadStarted) * 1000), startedAt: Date(), finishedAt: nil, copyVerified: false
        )
        print("索引完成（向量 \(embedded) 块，\(info.indexMs) ms）；模型 \(model.identifier) 加载 \(info.modelLoadMs) ms；可读分区 \(info.categories.joined(separator: ","))")

        let api = MemoryAPI(
            root: workspace.memory, index: index, access: MemoryAccess(categories: Set(settings.categories)),
            embedder: embedder.isAvailable ? embedder : nil
        )
        let session = AssistantSession(
            model: model, memory: api, live: nil, builder: ContextBuilder(language: languageName),
            clock: QAFixedClock(date: dataset.now)
        )
        let done = Set(try loadLines(QAAnswer.self, workspace.answers).map(\.item))
        let runner = QARunner(dataset: dataset, session: session, stats: {
            let stats = await model.prefixStats.chat
            return (stats.promptTokens, stats.cachedTokens)
        })
        try await runner.run(skipping: done, record: { try append($0, to: workspace.answers) }, log: { print($0) })
        info.finishedAt = Date()
        info.copyVerified = (try? workspace.verifyCopy()) == dataset.memoryDigest
        try encoder().encode(info).write(to: workspace.root.appendingPathComponent("run-info.json"))
        await MLXModelProvider(modelTag: tag).unload(reason: "qa eval finished")
        print("作答完成；记忆副本未被改动：\(info.copyVerified)")
    }

    // MARK: - judge

    static func judge(_ workspace: QAWorkspace, tag: String) async throws {
        let dataset = try loadDataset(workspace)
        let answers = Dictionary(try loadLines(QAAnswer.self, workspace.answers).map { ($0.item, $0) }, uniquingKeysWith: { _, b in b })
        let model = MLXTextChatModel(modelTag: tag)
        guard model.isInstalled else { throw Failure("Judge 模型未下载：\(tag)") }
        let done = Set(try loadLines(QAJudgment.self, workspace.judgments).map(\.item))
        let judge = QAJudge(model: model)
        var count = 0
        for conversation in dataset.conversations {
            var previous: [(question: String, answer: String)] = []
            var shown = ""
            for item in conversation {
                guard let answer = answers[item.id] else { continue }
                shown += (shown.isEmpty ? "" : "\n") + answer.memoryShown
                defer { previous.append((item.question, answer.answer)) }
                guard !done.contains(item.id), answer.error == nil else { continue }
                let judgment = await judge.judge(
                    item: item, evidence: dataset.evidence(item.evidence), context: dataset.evidence(item.context),
                    previous: previous, memoryShown: shown, answer: answer.answer
                )
                try append(judgment, to: workspace.judgments)
                count += 1
                if count % 10 == 0 { print("已判定 \(count) 道") }
            }
        }
        await model.unload()
        try encoder().encode(["judge": model.identifier, "rubric": QARubric.id]).write(to: workspace.root.appendingPathComponent("judge-info.json"))
        print("判定完成：本次 \(count) 道；评分规则 \(QARubric.id)")
    }

    // MARK: - report

    static func report(_ workspace: QAWorkspace) throws {
        let dataset = try loadDataset(workspace)
        let answers = try loadLines(QAAnswer.self, workspace.answers)
        let judgments = try loadLines(QAJudgment.self, workspace.judgments)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = (try? Data(contentsOf: workspace.root.appendingPathComponent("run-info.json")))
            .flatMap { try? decoder.decode(RunInfo.self, from: $0) }
        var notes: [String] = []
        if let info {
            notes.append("回答语言设置 \(info.language)；可读分区 \(info.categories.joined(separator: ", "))；向量块 \(info.embeddedChunks)；模型加载 \(info.modelLoadMs) ms（不计入延迟）")
            notes.append("记忆副本在作答后校验未被改动：\(info.copyVerified ? "是" : "否")")
        }
        notes.append("延迟在评测机器上测得；评测期间日常运行的 Amai（后台抽取、整理）可能同时占用 GPU，会抬高延迟。")
        let records = QAReport.records(dataset: dataset, answers: answers, judgments: judgments)
        let summary = QAReport.summary(
            dataset: dataset, records: records, answerer: info?.answerer ?? "?",
            judge: judgments.first?.judge ?? "?", embedder: info?.embedder ?? "?", notes: notes
        )
        try encoder().encode(summary).write(to: workspace.summary)
        let lines = try records.map { String(decoding: try lineEncoder().encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: workspace.records, atomically: true, encoding: .utf8)
        try QAReport.markdown(summary: summary, records: records, dataset: dataset).write(to: workspace.report, atomically: true, encoding: .utf8)
        print(QAReport.metricsMarkdown(summary))
        print("\n逐题记录：\(workspace.records.path)\n失败案例：\(workspace.report.path)\n汇总：\(workspace.summary.path)")
    }

    // MARK: - retrieval

    static func retrievalDirectory(_ workspace: QAWorkspace) -> URL {
        workspace.root.appendingPathComponent("retrieval", isDirectory: true)
    }

    /// 跑一遍三种检索（不调用回答模型），结果写到 retrieval/runs.jsonl。
    static func retrievalRuns(_ workspace: QAWorkspace) async throws -> (runs: [QARetrievalRun], embedder: String, catalog: EvidenceCatalog) {
        let dataset = try loadDataset(workspace)
        guard try workspace.verifyCopy() == dataset.memoryDigest else { throw Failure("记忆副本与出题时不是同一份") }
        let manifest = try workspace.loadManifest()
        let timeZone = TimeZone(identifier: manifest.timeZone) ?? .current
        let catalog = try EvidenceCatalog.build(root: workspace.memory, timeZone: timeZone)
        let settings = appAssistantSettings()
        let languageName = switch settings.language {
        case .zhHans: "Chinese"
        case .en: "English"
        case .ja: "Japanese"
        }
        let index = MemoryIndex(root: workspace.memory, database: try MemoryIndexDatabase(path: workspace.indexDatabase.path))
        try await index.refresh()
        let embedder = MLXTextEmbedder()
        if embedder.isAvailable {
            while try await index.embedPending(using: embedder) > 0 {}
        }
        let access = MemoryAccess(categories: Set(settings.categories))
        let runner = QARetrievalRunner(
            dataset: dataset, matcher: QAUnitMatcher(catalog.units),
            hybrid: MemoryAPI(root: workspace.memory, index: index, access: access, embedder: embedder.isAvailable ? embedder : nil),
            keyword: MemoryAPI(root: workspace.memory, index: index, access: access, embedder: nil),
            builder: ContextBuilder(language: languageName)
        )
        let runs = try await runner.run { print($0) }
        let directory = retrievalDirectory(workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = try runs.map { String(decoding: try lineEncoder().encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("runs.jsonl"), atomically: true, encoding: .utf8)
        guard try workspace.verifyCopy() == dataset.memoryDigest else { throw Failure("记忆副本在检索过程中被改动") }
        return (runs, embedder.isAvailable ? embedder.identifier : "none (keyword only)", catalog)
    }

    static func retrieval(_ workspace: QAWorkspace, gt choice: String?, baseline: URL?) async throws {
        let dataset = try loadDataset(workspace)
        let directory = retrievalDirectory(workspace)
        let gtURL = directory.appendingPathComponent("gt.json")
        let gt: QAGroundTruth
        switch choice {
        case "human", nil where FileManager.default.fileExists(atPath: gtURL.path):
            guard FileManager.default.fileExists(atPath: gtURL.path) else { throw Failure("还没有人工标注的 GT：先 gt-sheet 标注，再 gt-import") }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            gt = try decoder.decode(QAGroundTruth.self, from: Data(contentsOf: gtURL))
        case "provisional", nil:
            print("注意：没有人工标注的 GT，使用临时 GT（出题时的种子证据，未经人工确认；追问题不计入）")
            gt = QAGroundTruth.provisional(dataset)
        default:
            throw Failure("--gt 只能是 human 或 provisional")
        }
        guard gt.memoryDigest == dataset.memoryDigest else { throw Failure("GT 对应的记忆副本与数据集不一致") }
        let (runs, embedder, catalog) = try await retrievalRuns(workspace)
        let notes = [
            "检索在评测机器上运行；日常运行的 Amai 同时在做后台推理时会抬高延迟。",
            "pipeline 经 AssistantSession 调用，模型换成不回答的占位实现；hybrid / keyword 直接调用 MemoryAPI.search（取 50 条）。正式检索逻辑没有改动。",
        ]
        let (summary, _, misses) = QARetrievalReport.evaluate(dataset: dataset, gt: gt, runs: runs, embedder: embedder, notes: notes)
        let suffix = gt.source == .human ? "" : "-provisional"
        try encoder().encode(summary).write(to: directory.appendingPathComponent("summary\(suffix).json"))
        try QARetrievalReport.markdown(summary: summary, misses: misses, runs: runs, catalog: catalog)
            .write(to: directory.appendingPathComponent("report\(suffix).md"), atomically: true, encoding: .utf8)
        print(QARetrievalReport.metricsMarkdown(summary))
        if let baseline {
            let before = try loadLines(QARetrievalRun.self, baseline)
            let previous = QARetrievalReport.evaluate(dataset: dataset, gt: gt, runs: before, embedder: embedder, notes: notes)
            let comparison = QARetrievalReport.comparisonMarkdown(before: previous.summary, after: summary)
            try encoder().encode(previous.summary).write(to: directory.appendingPathComponent("summary-baseline\(suffix).json"))
            try ("# 优化前后对比\n\n- 标准证据：" + (gt.source == .human ? "人工标注" : "临时 GT（仅用于诊断）") + "\n\n" + comparison + "\n")
                .write(to: directory.appendingPathComponent("comparison\(suffix).md"), atomically: true, encoding: .utf8)
            try QARetrievalReport.markdown(summary: previous.summary, misses: previous.misses, runs: before, catalog: catalog)
                .write(to: directory.appendingPathComponent("report-baseline\(suffix).md"), atomically: true, encoding: .utf8)
            print("\n## 优化前后对比\n\n" + comparison)
        }
        print("\n失败案例：\(directory.appendingPathComponent("report\(suffix).md").path)\n汇总：\(directory.appendingPathComponent("summary\(suffix).json").path)")
    }

    /// 标注子集固定在 retrieval/gt-subset.json：第一次生成后不再改动，优化前后都在这一组题上比较。
    static func gtSubset(_ workspace: QAWorkspace, dataset: QADataset) throws -> [String] {
        let url = retrievalDirectory(workspace).appendingPathComponent("gt-subset.json")
        if let data = try? Data(contentsOf: url), let ids = try? JSONDecoder().decode([String].self, from: data) { return ids }
        let ids = QAGroundTruthSheet.subset(dataset, seed: dataset.seed)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder().encode(ids).write(to: url)
        return ids
    }

    static func gtSheet(_ workspace: QAWorkspace, all: Bool) async throws {
        let dataset = try loadDataset(workspace)
        var (runs, _, catalog) = try await retrievalRuns(workspace)
        // 优化前的结果也并进候选池：任何一边找到的记录都能被标注，对比才公平。
        let baseline = retrievalDirectory(workspace).appendingPathComponent("runs-baseline.jsonl")
        let before = try loadLines(QARetrievalRun.self, baseline)
        runs += before
        let only = all ? nil : try gtSubset(workspace, dataset: dataset)
        let url = retrievalDirectory(workspace).appendingPathComponent(all ? "gt-annotate-all.html" : "gt-annotate.html")
        try QAGroundTruthSheet.html(dataset: dataset, runs: runs, catalog: catalog, only: only).write(to: url, atomically: true, encoding: .utf8)
        let items = dataset.items.filter { $0.isAnswerable && (only?.contains($0.id) ?? true) }
        let sizes = items.map { QAGroundTruthSheet.candidates(for: $0, dataset: dataset, runs: runs, catalog: catalog).count }
        let types = Dictionary(grouping: items, by: { "\($0.type.rawValue)/\($0.subtype)" }).mapValues(\.count)
        print("标注网页：\(url.path)")
        print("候选池合并了\(before.isEmpty ? "当前" : "优化前与当前")的检索结果")
        print("待标注 \(items.count) 道（" + types.keys.sorted().map { "\($0) \(types[$0]!)" }.joined(separator: "，") + "）；每题候选 平均 \(sizes.reduce(0, +) / max(sizes.count, 1)) 条，最多 \(sizes.max() ?? 0) 条")
    }

    static func gtImport(_ workspace: QAWorkspace, file: URL, annotator: String?) throws {
        let dataset = try loadDataset(workspace)
        let manifest = try workspace.loadManifest()
        let catalog = try EvidenceCatalog.build(root: workspace.memory, timeZone: TimeZone(identifier: manifest.timeZone) ?? .current)
        let subsetURL = retrievalDirectory(workspace).appendingPathComponent("gt-subset.json")
        let scope = (try? Data(contentsOf: subsetURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }.map(Set.init)
        let (gt, incomplete) = try QAGroundTruth.importAnnotations(
            Data(contentsOf: file), dataset: dataset, catalog: catalog, annotator: annotator, scope: scope
        )
        let directory = retrievalDirectory(workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder().encode(gt).write(to: directory.appendingPathComponent("gt.json"))
        let excluded = gt.items.values.filter { $0.excluded != nil }.count
        print("已导入：标注 \(gt.items.count - excluded) 道，排除 \(excluded) 道，未完成 \(incomplete.count) 道\(incomplete.isEmpty ? "" : "（" + incomplete.joined(separator: ", ") + "）")")
    }

    // MARK: - Files

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func lineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func loadDataset(_ workspace: QAWorkspace) throws -> QADataset {
        guard FileManager.default.fileExists(atPath: workspace.dataset.path) else { throw Failure("没有 dataset.json，先运行 generate") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QADataset.self, from: Data(contentsOf: workspace.dataset))
    }

    static func loadLines<T: Decodable>(_ type: T.Type, _ url: URL) throws -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try text.split(separator: "\n").map { try decoder.decode(T.self, from: Data($0.utf8)) }
    }

    static func append<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try lineEncoder().encode(value)
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }
}

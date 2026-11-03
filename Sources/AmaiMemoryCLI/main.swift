import AmaiCloud
import AmaiCore
import AmaiMemory
import AmaiMemoryEval
import Foundation

// 开发用记忆检索命令行（docs/roadmap.md M3）。只读 Markdown 与派生索引，不触碰采集与抽取数据。
//
//   amai-memory search <查询> [--category general|work|health|finance|goals|daily] [--limit N]
//   amai-memory reindex                     增量刷新索引
//   amai-memory rebuild                     清空后全量重建
//   amai-memory migrate [--status|--rollback]  Schema v1 迁移、查看迁移记录、回滚（ADR-0006）
//   amai-memory eval <场景.json> --claude <claude 路径> [--model opus] [--output 目录]
//                                           用 Claude 订阅（本机 Claude Code）跑记忆整理评测；只用合成数据与临时目录
//
// 选项：--memory <目录>（默认 ~/.amai/memory）  --index <sqlite>（默认 App 使用的索引）

let usage = """
用法：
  amai-memory search <查询> [--category general|work|health|finance|goals|daily] [--limit N]
  amai-memory reindex
  amai-memory rebuild
  amai-memory migrate [--status|--rollback]
选项：--memory <记忆目录>  --index <索引文件>
"""

var args = Array(CommandLine.arguments.dropFirst())

@MainActor
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

let memoryRoot = option("--memory").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? MemoryDirectory.defaultRootURL
let indexPath = option("--index").map { ($0 as NSString).expandingTildeInPath }
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Amai/index/memory.sqlite").path
let category = option("--category").flatMap(MemoryCategory.init(rawValue:))
let limit = option("--limit").flatMap(Int.init) ?? 10

guard let command = args.first else {
    print(usage)
    exit(1)
}

/// Claude Code 客户端适配为记忆层的模型接口（与 App 中的 CloudLanguageModel 相同，先脱敏再发送）。
struct EvalCloudModel: MemoryLanguageModel {
    let client: ClaudeCodeClient
    var identifier: String { client.identifier }

    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
        try await client.generate(CloudRequest(
            system: SecretRedactor.redact(system).text, user: SecretRedactor.redact(user).text,
            maxTokens: maxTokens, schemaName: schema?.name, schemaJSON: schema?.json
        )).text
    }
}

if command == "eval" {
    let claude = option("--claude")
    let modelName = option("--model") ?? ClaudeCodeClient.defaultModel
    let only = option("--only")
    let output = URL(fileURLWithPath: option("--output") ?? "eval/memory/results", isDirectory: true)
    guard args.count >= 2, let claude else { print(usage); exit(1) }
    let workdir = FileManager.default.temporaryDirectory.appendingPathComponent("amai-eval-claude", isDirectory: true)
    let model = EvalCloudModel(client: ClaudeCodeClient(
        executable: URL(fileURLWithPath: (claude as NSString).expandingTildeInPath), model: modelName, workingDirectory: workdir
    ))
    do {
        var scenarios = try MemoryEvaluation.load(URL(fileURLWithPath: args[1]))
        if let only { scenarios = scenarios.filter { only.split(separator: ",").map(String.init).contains($0.name) } }
        let summary = await MemoryEvaluation.run(scenarios, model: model)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data(summary.report().utf8).write(to: output.appendingPathComponent("report.md"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary.results).write(to: output.appendingPathComponent("report.json"))
        print(summary.report())
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
        exit(2)
    }
}

if command == "migrate" {
    // 迁移只操作 Markdown 与归档目录，不需要索引。运行前请先退出 Amai，避免与整理同时写文件。
    let migration = SchemaMigration(root: memoryRoot)
    do {
        if args.contains("--status") {
            let status = migration.status()
            print("待迁移的旧文件：\(status.legacyFiles.isEmpty ? "无" : status.legacyFiles.joined(separator: "、"))")
            print("迁移记录：\(status.runs) 次")
            for t in status.targets {
                print("  \(t.path)：\(t.unchangedSinceMigration ? "迁移后未修改，可回滚" : "迁移后已修改")")
            }
            for a in status.archiveProblems { print("  ⚠︎ 归档异常：\(a)") }
        } else if args.contains("--rollback") {
            let r = try migration.rollback()
            print("已恢复 \(r.restored.count) 个旧文件；新文件已移到：")
            r.setAside.forEach { print("  \($0)") }
            print("注意：新版 Amai 下次启动会再次迁移。回滚用于配合旧版 Amai 使用。")
        } else {
            let r = try migration.migrate()
            print(r.migrated.isEmpty ? "没有需要迁移的旧文件" : "已迁移 \(r.migrated.count) 个文件、\(r.itemsCarried) 条记忆 → \(r.targets.joined(separator: "、"))")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
        exit(2)
    }
}

do {
    let index = MemoryIndex(root: memoryRoot, database: try MemoryIndexDatabase(path: indexPath))
    switch command {
    case "search":
        let query = args.dropFirst().joined(separator: " ")
        guard !query.isEmpty else { print(usage); exit(1) }
        try await index.refresh()
        let hits = try await index.retrieve(
            query, categories: category.map { [$0] }, limit: limit
        )
        if hits.isEmpty { print("没有匹配的内容") }
        for hit in hits {
            let where_ = hit.heading.isEmpty ? hit.file : "\(hit.file) › \(hit.heading)"
            print("• \(where_)\n  \(hit.excerpt)\n")
        }
    case "reindex":
        let r = try await index.refresh()
        print("已索引 \(r.indexed) 个文件，移除 \(r.removed) 个，未变化 \(r.unchanged) 个")
    case "rebuild":
        let r = try await index.rebuild()
        print("全量重建完成，索引 \(r.indexed) 个文件")
    default:
        print(usage)
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
    exit(2)
}

import AmaiMemory
import Foundation

// 开发用记忆检索命令行（docs/roadmap.md M3）。只读 Markdown 与派生索引，不触碰采集与抽取数据。
//
//   amai-memory search <查询> [--scope daily|summary|topic] [--limit N]
//   amai-memory reindex                     增量刷新索引
//   amai-memory rebuild                     清空后全量重建
//
// 选项：--memory <目录>（默认 ~/.amai/memory）  --index <sqlite>（默认 App 使用的索引）

let usage = """
用法：
  amai-memory search <查询> [--scope daily|summary|topic] [--limit N]
  amai-memory reindex
  amai-memory rebuild
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
let scope = option("--scope").flatMap(MemoryScope.init(rawValue:))
let limit = option("--limit").flatMap(Int.init) ?? 10

guard let command = args.first else {
    print(usage)
    exit(1)
}

do {
    let index = MemoryIndex(root: memoryRoot, database: try MemoryIndexDatabase(path: indexPath))
    switch command {
    case "search":
        let query = args.dropFirst().joined(separator: " ")
        guard !query.isEmpty else { print(usage); exit(1) }
        try await index.refresh()
        let hits = try await index.retrieve(
            query, scopes: scope.map { [$0] } ?? Set(MemoryScope.allCases), limit: limit
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

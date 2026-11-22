import AmaiBenchmark
import AmaiInference
import Foundation

// amai-bench：统一 Quality Benchmark（docs/benchmark.md）。开发用，不随 App 发布。
//
//   amai-bench run [--suites perception,memory,retrieval,qa,e2e,real|all|offline] [--label 名字] [--repeat N]
//                  [--output eval/benchmark/runs] [--no-models]
//                  [--vision 标签] [--memory-model 标签] [--answer-model 标签] [--judge 标签] [--embedder 标签|none]
//                  [--qa-workdir <qa-eval 工作目录>]
//   amai-bench compare <基线 result.json 或目录> <新版 result.json 或目录> [--threshold 0.02] [--output 对比.md]
//   amai-bench report <result.json 或目录>      重新生成 report.md
//
// 全部模型都是本机 MLX 模型；Benchmark 不把任何数据发往外部服务。合成数据之外，只读取 --qa-workdir 里的汇总计数。

let usage = """
用法：
  amai-bench run [--suites perception,memory,retrieval,qa,e2e,real|all|offline] [--label 名字] [--repeat N]
                 [--output eval/benchmark/runs] [--no-models]
                 [--vision 标签] [--memory-model 标签] [--answer-model 标签] [--judge 标签] [--embedder 标签|none]
                 [--qa-workdir <qa-eval 工作目录>]
  amai-bench compare <基线> <新版> [--threshold 0.02] [--output 对比.md]
  amai-bench report <result.json 或目录>
  offline = perception,memory,retrieval（不需要生成模型；memory 只跑时间线检查，retrieval 有向量模型时用它）
需要可执行文件旁有 mlx.metallib（swift build 后从 .build/release 或 .build/debug 运行）。
"""

var args = Array(CommandLine.arguments.dropFirst())

@MainActor
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

@MainActor
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func path(_ text: String) -> URL { URL(fileURLWithPath: (text as NSString).expandingTildeInPath) }

/// 只读地取 App 配置里的助手本地模型（与 amai-memory qa-eval 相同的读取方式）。不写配置。
func appAssistantModel() -> String? {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Amai/config.json")
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let agent = (root["assistant"] as? [String: Any])?["agent"] as? [String: Any] else { return nil }
    return agent["localModelTag"] as? String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("错误：\(message)\n".utf8))
    exit(2)
}

guard let command = args.first else {
    print(usage)
    exit(1)
}
args.removeFirst()

switch command {
case "run":
    let suitesArg = option("--suites") ?? "all"
    let suites: [String] = switch suitesArg {
    case "all": BenchmarkRunner.allSuites
    case "offline": ["perception", "memory", "retrieval"]
    default: suitesArg.split(separator: ",").map(String.init)
    }
    let unknown = suites.filter { !BenchmarkRunner.allSuites.contains($0) }
    guard unknown.isEmpty else { fail("未知的组：\(unknown.joined(separator: ", "))") }
    let label = option("--label") ?? "local"
    let repeats = option("--repeat").flatMap(Int.init) ?? 1
    let output = path(option("--output") ?? "eval/benchmark/runs")
    let qaWorkdir = option("--qa-workdir").map(path)
    let noModels = flag("--no-models")
    let embedderArg = option("--embedder")
    var models = BenchmarkModels(
        vision: option("--vision") ?? LocalInferenceBackend.defaultModelTag,
        memory: option("--memory-model") ?? LocalInferenceBackend.defaultModelTag,
        answer: option("--answer-model") ?? appAssistantModel() ?? LocalInferenceBackend.defaultModelTag,
        judge: option("--judge") ?? "mlx-community/Qwen2.5-7B-Instruct-4bit",
        embedder: embedderArg == "none" ? nil : (embedderArg ?? MLXTextEmbedder.defaultModelTag)
    )
    if noModels { models = BenchmarkModels(embedder: models.embedder) }
    let checked = models.installedOnly()
    for m in checked.missing { print("注意：模型未下载，相关部分将跳过：\(m)") }
    guard args.isEmpty else { fail("无法识别的参数：\(args.joined(separator: " "))\n\(usage)") }

    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyyMMdd-HHmmss"
    let safeLabel = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
    let runDirectory = output.appendingPathComponent("\(stamp.string(from: Date()))-\(safeLabel)", isDirectory: true)
    let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("eval/benchmark/fixtures", isDirectory: true)
    guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("synthetic-qa.json").path) else {
        fail("找不到 eval/benchmark/fixtures：请在仓库根目录运行")
    }
    let ctx = BenchmarkContext(
        fixtures: fixtures, runDirectory: runDirectory, models: checked.models, qaWorkdir: qaWorkdir,
        log: { line in print("  \(line)"); fflush(stdout) }
    )
    print("→ \(runDirectory.path)")
    do {
        let run = try await BenchmarkRunner.run(
            suites: suites, context: ctx, label: label, repeats: repeats,
            options: ["suites": suites.joined(separator: ","), "missingModels": checked.missing.joined(separator: ",")]
        )
        print("")
        print(BenchmarkReport.markdown(run))
        print("结果：\(runDirectory.appendingPathComponent("result.json").path)\n报告：\(runDirectory.appendingPathComponent("report.md").path)")
        exit(run.suites.contains { $0.status == .failed } ? 3 : 0)
    } catch {
        fail("\(error)")
    }

case "compare":
    let threshold = option("--threshold").flatMap(Double.init) ?? 0.02
    let output = option("--output").map(path)
    guard args.count == 2 else { print(usage); exit(1) }
    do {
        let base = try BenchmarkRunner.load(path(args[0]))
        let new = try BenchmarkRunner.load(path(args[1]))
        let comparisons = BenchmarkComparison.compare(base: base, new: new, ratioThreshold: threshold)
        let markdown = BenchmarkReport.comparisonMarkdown(base: base, new: new, comparisons: comparisons)
        if let output { try markdown.write(to: output, atomically: true, encoding: .utf8) }
        print(markdown)
        exit(comparisons.contains { $0.verdict == .regressed } ? 4 : 0)
    } catch {
        fail("\(error)")
    }

case "report":
    guard args.count == 1 else { print(usage); exit(1) }
    do {
        let url = path(args[0])
        let run = try BenchmarkRunner.load(url)
        let directory = url.pathExtension == "json" ? url.deletingLastPathComponent() : url
        try BenchmarkRunner.write(run, to: directory)
        print(BenchmarkReport.markdown(run))
    } catch {
        fail("\(error)")
    }

default:
    print(usage)
    exit(1)
}

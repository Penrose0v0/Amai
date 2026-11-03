import enum AmaiCore.AmaiLog
import AmaiMemory
import AmaiMemoryEval
import Foundation

/// `--memory-eval` 启动参数的实现：运行评测，把报告写到输出目录（report.md / report.json）。
enum MemoryEvalCommand {
    static func run(scenarios: URL, output: URL, model: any MemoryLanguageModel) async {
        let log = AmaiLog.logger("memory.eval")
        do {
            let list = try MemoryEvaluation.load(scenarios)
            log.info("memory eval started: \(list.count) scenarios with \(model.identifier, privacy: .public)")
            let summary = await MemoryEvaluation.run(list, model: model)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(summary.report().utf8).write(to: output.appendingPathComponent("report.md"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary.results).write(to: output.appendingPathComponent("report.json"))
            log.info("memory eval finished: \(output.path, privacy: .public)")
        } catch {
            log.error("memory eval failed: \(String(describing: error), privacy: .public)")
            try? Data("评测失败：\(error)\n".utf8).write(to: output.appendingPathComponent("report.md"))
        }
    }
}

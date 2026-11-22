import Foundation

/// 按顺序运行各组，汇总为一次 `BenchmarkRun`，写出 result.json 与 report.md。
public enum BenchmarkRunner {
    public static let allSuites = [PerceptionSuite.id, MemorySuite.id, RetrievalSuite.id, QASuite.id, EndToEndSuite.id, RealDataImport.id]

    public static func run(
        suites: [String], context ctx: BenchmarkContext, label: String, repeats: Int, options: [String: String]
    ) async throws -> BenchmarkRun {
        let started = Date()
        let git = gitState()
        var run = BenchmarkRun(
            runId: ctx.runDirectory.lastPathComponent, label: label, startedAt: started, gitCommit: git.commit, gitDirty: git.dirty,
            machine: machine(), repeats: repeats, options: options.merging(ctx.models.description.mapKeys { "model.\($0)" }) { a, _ in a }
        )
        defer { ctx.cleanup() }
        for id in allSuites where suites.contains(id) {
            // 导入的真实数据不重复运行；其余各组按要求重复。
            let times = id == RealDataImport.id ? 1 : max(1, repeats)
            var results: [SuiteResult] = []
            for i in 0..<times {
                if times > 1 { ctx.log("── \(id) 第 \(i + 1)/\(times) 次") }
                let r = await runSuite(id, ctx)
                results.append(r)
                if r.status == .skipped { break }
            }
            let merged = BenchmarkAggregation.merge(results)
            ctx.log("✓ \(merged.title)：\(merged.status.rawValue)\(merged.reason.map { "（\($0)）" } ?? "")，\(Int(merged.seconds)) 秒")
            run.suites.append(merged)
            // 每组结束都写一次：长时间运行中途中断也保留已完成的部分。
            try write(run, to: ctx.runDirectory)
        }
        run.finishedAt = Date()
        try write(run, to: ctx.runDirectory)
        return run
    }

    static func runSuite(_ id: String, _ ctx: BenchmarkContext) async -> SuiteResult {
        switch id {
        case PerceptionSuite.id: await PerceptionSuite.run(ctx)
        case MemorySuite.id: await MemorySuite.run(ctx)
        case RetrievalSuite.id: await RetrievalSuite.run(ctx)
        case QASuite.id: await QASuite.run(ctx)
        case EndToEndSuite.id: await EndToEndSuite.run(ctx)
        case RealDataImport.id: RealDataImport.run(ctx)
        default: .skipped(id, id, reason: "未知的组")
        }
    }

    public static func write(_ run: BenchmarkRun, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try BenchmarkFiles.encoder().encode(run).write(to: directory.appendingPathComponent("result.json"))
        try BenchmarkReport.markdown(run).write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }

    public static func load(_ path: URL) throws -> BenchmarkRun {
        var url = path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            url = url.appendingPathComponent("result.json")
        }
        return try BenchmarkFiles.decoder().decode(BenchmarkRun.self, from: Data(contentsOf: url))
    }

    static func gitState() -> (commit: String?, dirty: Bool?) {
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let commit = git(["rev-parse", "--short=12", "HEAD"])
        let status = git(["status", "--porcelain", "--untracked-files=no"])
        return (commit, status.map { !$0.isEmpty })
    }

    static func machine() -> String {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(sysctl("machdep.cpu.brand_string") ?? sysctl("hw.model") ?? "Mac") · \(memory) GB · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

extension Dictionary {
    func mapKeys<K: Hashable>(_ f: (Key) -> K) -> [K: Value] {
        Dictionary<K, Value>(uniqueKeysWithValues: map { (f($0.key), $0.value) })
    }
}

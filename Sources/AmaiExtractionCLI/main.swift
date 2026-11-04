import AmaiCore
import AmaiExtraction
import AmaiPerception
import Darwin
import Foundation

// 开发用抽取评测命令行：在一段已录制的原始帧上用指定的本地模型重跑抽取，比较模型的速度、内存与切分结果。
//
//   amai-extraction eval --from <yyyy-MM-ddTHH:mm> --to <yyyy-MM-ddTHH:mm> --model <模型标签> [--output 目录] [--raw 目录]
//
// - 只读原始缓冲（默认 App 的 raw/），不追加、不清理；抽取结果写到输出目录，不碰 App 的 extracted/ 与记忆。
// - metrics.json 只含耗时、内存与计数，不含屏幕内容；segments.md 是片段列表，供本人检查质量。
// - 需要二进制旁有 mlx.metallib。运行时最好暂停 Amai 的记录，避免与 App 的抽取争用资源。

let usage = """
用法：
  amai-extraction eval --from <yyyy-MM-ddTHH:mm> --to <yyyy-MM-ddTHH:mm> --model <模型标签> [--output 目录] [--raw 目录]
"""

var args = Array(CommandLine.arguments.dropFirst())

@MainActor
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

/// 固定在评测时段结束时刻的时钟：时段之后的帧不会被读入，时段内的窗口都视为已就绪。
struct FixedClock: AmaiClock {
    let date: Date
    func now() -> Date { date }
    func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// 进程物理内存占用（与活动监视器的"内存"一致，包含 Metal 在统一内存中的分配）。
func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

actor PeakSampler {
    private(set) var peak: UInt64 = 0
    func sample() { peak = max(peak, physicalFootprint()) }
}

struct Metrics: Codable {
    var model: String
    var from: Date
    var to: Date
    var totalSeconds: Double
    /// 第一个窗口的耗时，含模型加载。
    var firstBatchSeconds: Double?
    var batchSeconds: [Double]
    var batches: Int
    var framesDescribed: Int
    var fallbackBatches: Int
    var segments: Int
    var ruleSegments: Int
    var lowConfidenceSegments: Int
    var segmentMinutes: [Double]
    var peakFootprintMB: Int
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

@MainActor
func runEval() async throws {
    let parser = DateFormatter()
    parser.calendar = Calendar(identifier: .gregorian)
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
    guard let from = option("--from").flatMap(parser.date(from:)),
          let to = option("--to").flatMap(parser.date(from:)), to > from,
          let tag = option("--model")
    else { print(usage); exit(1) }
    let raw = try option("--raw").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        ?? AmaiPaths.standard().raw
    let name = tag.split(separator: "/").last.map(String.init) ?? tag
    let output = URL(fileURLWithPath: option("--output") ?? "eval/extraction/\(name)", isDirectory: true)

    guard LocalInferenceBackend.isInstalled(tag: tag) else {
        FileHandle.standardError.write(Data("错误：模型未安装：\(tag)\n".utf8))
        exit(2)
    }
    let fm = FileManager.default
    try? fm.removeItem(at: output.appendingPathComponent("extracted"))
    let store = try ExtractionStore(root: output.appendingPathComponent("extracted", isDirectory: true))
    try await store.saveState(.init(processedUntil: from))
    // 只读：不调用 append / purge / erase。容量上限只影响写入，这里给足以免误报。
    let spool = try RawSpool(root: raw, limits: RawSpoolLimits.default)
    let model = MLXModelProvider(modelTag: tag)
    var options = ExtractionPipeline.Options()
    options.maxBatchesPerRun = 1
    let pipeline = ExtractionPipeline(
        dependencies: .init(reader: SpoolReader(spool: spool), model: model, ocr: VisionTextRecognizer(), store: store, clock: FixedClock(date: to)),
        options: options
    )

    let sampler = PeakSampler()
    let sampling = Task {
        while !Task.isCancelled {
            await sampler.sample()
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    print("→ \(tag)：\(parser.string(from: from)) – \(parser.string(from: to))")
    let started = Date()
    var batchSeconds: [Double] = []
    while true {
        let done = await pipeline.runOnce(force: true)
        let status = await pipeline.status
        if done == 0 {
            if let error = status.lastError { print("  停止：\(status.state.rawValue) · \(error)") }
            break
        }
        if let s = status.lastBatchSeconds { batchSeconds.append(s) }
        print("  窗口 \(status.batchesProcessed)：\(Int(status.lastBatchSeconds ?? 0)) 秒，剩余 \(status.pendingBatches)")
    }
    let total = Date().timeIntervalSince(started)
    sampling.cancel()
    await sampler.sample()
    let status = await pipeline.status

    var segments: [ActivitySegment] = []
    var day = Calendar.current.startOfDay(for: from)
    while day <= to {
        segments += await store.segments(on: day).filter { $0.timeRange.start < to && $0.timeRange.end > from }
        day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
    }
    segments.sort { $0.timeRange.start < $1.timeRange.start }
    let modelSegments = segments.filter { !$0.provider.hasPrefix("rule:") }

    let metrics = Metrics(
        model: tag, from: from, to: to,
        totalSeconds: total,
        firstBatchSeconds: batchSeconds.first,
        batchSeconds: batchSeconds,
        batches: status.batchesProcessed,
        framesDescribed: status.framesDescribed,
        fallbackBatches: status.fallbackBatches,
        segments: modelSegments.count,
        ruleSegments: segments.count - modelSegments.count,
        lowConfidenceSegments: modelSegments.filter { $0.provider.hasPrefix("fallback") || $0.confidence < 0.5 }.count,
        segmentMinutes: modelSegments.map { ($0.timeRange.duration / 60 * 10).rounded() / 10 },
        peakFootprintMB: Int(await sampler.peak / 1_048_576)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(metrics).write(to: output.appendingPathComponent("metrics.json"))

    let time = DateFormatter()
    time.dateFormat = "HH:mm"
    var md = "# \(tag)\n\n\(parser.string(from: from)) – \(parser.string(from: to))\n\n"
    for s in segments {
        md += "- \(time.string(from: s.timeRange.start))–\(time.string(from: s.timeRange.end)) [\(s.category.rawValue)] **\(s.title)**"
        md += " (conf \(String(format: "%.2f", s.confidence)), \(s.provider))\n"
        if !s.summary.isEmpty { md += "  \(s.summary)\n" }
    }
    try Data(md.utf8).write(to: output.appendingPathComponent("segments.md"))

    let steady = Array(batchSeconds.dropFirst())
    print("""
    ✓ 共 \(Int(total)) 秒 · 窗口 \(metrics.batches)（兜底 \(metrics.fallbackBatches)）· 描述帧 \(metrics.framesDescribed)
      首个窗口 \(Int(metrics.firstBatchSeconds ?? 0)) 秒（含加载）· 其余窗口中位数 \(Int(median(steady) ?? 0)) 秒
      片段 \(metrics.segments)（规则 \(metrics.ruleSegments)，低置信度 \(metrics.lowConfidenceSegments)）· 片段时长中位数 \(String(format: "%.1f", median(metrics.segmentMinutes) ?? 0)) 分
      峰值内存 \(metrics.peakFootprintMB) MB
      → \(output.path)
    """)
}

guard args.first == "eval" else {
    print(usage)
    exit(1)
}
do {
    try await runEval()
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
    exit(2)
}

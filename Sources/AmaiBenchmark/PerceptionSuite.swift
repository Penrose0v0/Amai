import AmaiCore
import AmaiPerception
import CoreGraphics
import Foundation

/// 感知层：采集覆盖率、隐私跳过、画面去重、OCR 准确率。全部是合成数据，不需要模型（OCR 用本机 Apple Vision）。
public enum PerceptionSuite {
    public static let id = "perception"

    public static func run(_ ctx: BenchmarkContext) async -> SuiteResult {
        let started = Date()
        var result = SuiteResult(id: id, title: "感知")
        do {
            let scriptURL = ctx.fixture("activity-day.json")
            let script = try ActivityScript.load(scriptURL)
            result.datasets.append(ctx.dataset("activity-day", scriptURL))
            let root = ctx.scratch("perception-capture")
            defer { try? FileManager.default.removeItem(at: root) }
            ctx.log("感知：按脚本模拟采集 \(script.activities.count) 个活动")
            let trace = try await SimulatedCapture.run(script, root: root)
            result.metrics += coverageMetrics(trace, script: script)
            result.metrics += streamDedupMetrics(trace)

            ctx.log("感知：画面去重（成对标注）")
            let ocr = VisionTextRecognizer()
            let pairs = await pairwiseDedup(ocr: ocr)
            result.metrics += pairs.metrics
            result.notes += pairs.notes

            let samplesURL = ctx.fixture("ocr-samples.json")
            let samples = try JSONDecoder().decode([OCRSample].self, from: Data(contentsOf: samplesURL))
            result.datasets.append(ctx.dataset("ocr-samples", samplesURL))
            ctx.log("感知：OCR \(samples.count) 个样本 × 2 条路径")
            let o = try await ocrMetrics(samples, ocr: ocr, scratch: ctx.scratch("perception-ocr"))
            result.metrics += o.metrics
            result.notes += o.notes
            try ctx.writeDetail("perception-ocr.json", o.detail)
            result.details.append("details/perception-ocr.json")
            result.models["ocr"] = "apple-vision (VNRecognizeTextRequest .accurate)"
            result.notes.append("合成画面没有图片、阴影与复杂背景，OCR 与去重结果偏乐观，应视为上界。")
        } catch {
            result.status = .failed
            result.reason = "\(error)"
        }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    // MARK: - Coverage

    static func coverageMetrics(_ trace: CaptureTrace, script: ActivityScript) -> [Metric] {
        let capturable = trace.ticks.filter { $0.expected == .capture }
        let captured = capturable.filter { $0.outcome == "captured" }
        let shouldNot = trace.ticks.filter { $0.expected != .capture }
        let leaked = shouldNot.filter { $0.outcome == "captured" }
        let skipExpected = trace.ticks.filter { if case .skip = $0.expected { return true } else { return false } }
        let skipCorrect = skipExpected.filter { tick in
            if case .skip(let reason) = tick.expected { return tick.outcome == "skipped:\(reason)" }
            return false
        }
        let blockedExpected = trace.ticks.filter { $0.expected == .blocked }
        let blockedCorrect = blockedExpected.filter { $0.outcome == "blocked" }

        // 状态覆盖：每个"可采集"的屏幕版本（活动 × 内容版本）是否至少被采到一帧。
        // 时长不足一个采集间隔的版本（例如一闪而过的通知）单独统计：定时截图本来就可能错过它们。
        var long: (hit: Int, total: Int) = (0, 0)
        var short: (hit: Int, total: Int) = (0, 0)
        var firstCaptureDelay: [Double] = []
        for a in script.activities where script.expected(a, excludedBundleIds: ExclusionListPolicy.defaultExcludedBundleIds) == .capture {
            let r = script.range(a)
            for (v, version) in a.screens.enumerated() {
                let start = r.start.addingTimeInterval(version.at)
                let end = v + 1 < a.screens.count ? r.start.addingTimeInterval(a.screens[v + 1].at) : r.end
                let hits = trace.ticks.filter { $0.activity == a.id && $0.version == v && $0.outcome == "captured" }
                if end.timeIntervalSince(start) >= script.captureInterval {
                    long.total += 1
                    if !hits.isEmpty { long.hit += 1 }
                } else {
                    short.total += 1
                    if !hits.isEmpty { short.hit += 1 }
                }
                if let first = hits.first { firstCaptureDelay.append(first.time.timeIntervalSince(start)) }
            }
        }
        let p = "perception.capture"
        return [
            .ratio("\(p).timeCoverage", "采集覆盖率（应采集的 tick 中实际采到）", captured.count, capturable.count, direction: .higherIsBetter, gt: .synthetic),
            .ratio("\(p).stateCoverage", "屏幕状态覆盖率（持续 ≥ 1 个间隔的内容版本）", long.hit, long.total, direction: .higherIsBetter, gt: .synthetic),
            .ratio("\(p).shortStateCoverage", "短暂状态覆盖率（持续 < 1 个间隔）", short.hit, short.total, direction: .info, gt: .synthetic,
                   note: "定时截图的固有限制，仅供参考"),
            Metric(id: "\(p).firstCaptureDelay", name: "内容出现到首次采到的平均延迟", value: firstCaptureDelay.isEmpty ? nil : firstCaptureDelay.reduce(0, +) / Double(firstCaptureDelay.count),
                   unit: .seconds, direction: .lowerIsBetter, groundTruth: .synthetic, note: "采集间隔 \(Int(script.captureInterval)) 秒"),
            .ratio("\(p).privacyLeak", "隐私泄漏（不应采集却采到的 tick）", leaked.count, shouldNot.count, direction: .lowerIsBetter, gt: .synthetic,
                   note: "锁屏、暂停、安全输入、被排除的应用"),
            .ratio("\(p).skipReasonAccuracy", "跳过原因正确率", skipCorrect.count, skipExpected.count, direction: .higherIsBetter, gt: .synthetic),
            .ratio("\(p).blockedAccuracy", "锁屏时停止采集", blockedCorrect.count, blockedExpected.count, direction: .higherIsBetter, gt: .synthetic),
            Metric(id: "\(p).tickMs.p50", name: "单次 tick 耗时中位数（含编码写入）", value: median(trace.tickMs), unit: .milliseconds, direction: .lowerIsBetter, groundTruth: .measured,
                   note: "评测机器上测得，仅作数量级参考"),
        ]
    }

    /// 采集流中的去重：与上一个 tick 的内容是否相同由脚本决定（活动与内容版本都相同；时钟、光标是噪声）。
    /// 只评价"上一个 tick 也采到了"的帧：中间有跳过时采集器会丢弃去重状态，这是设计行为。
    static func streamDedupMetrics(_ trace: CaptureTrace) -> [Metric] {
        var falseMerge = 0, different = 0, falseSplit = 0, same = 0
        for i in trace.ticks.indices.dropFirst() {
            let cur = trace.ticks[i], prev = trace.ticks[i - 1]
            guard cur.outcome == "captured", prev.outcome == "captured" else { continue }
            let sameContent = cur.activity == prev.activity && cur.version == prev.version
            if sameContent {
                same += 1
                if !cur.markedDuplicate { falseSplit += 1 }
            } else {
                different += 1
                if cur.markedDuplicate { falseMerge += 1 }
            }
        }
        let p = "perception.dedup.stream"
        return [
            .ratio("\(p).falseMerge", "采集流·误合并率（内容变了却标为重复）", falseMerge, different, direction: .lowerIsBetter, gt: .synthetic,
                   note: "被标为重复的帧不再送去描述，等于丢信息"),
            .ratio("\(p).falseSplit", "采集流·误拆分率（内容没变却没标为重复）", falseSplit, same, direction: .lowerIsBetter, gt: .synthetic,
                   note: "多做无用的识别与推理"),
        ]
    }

    // MARK: - Pairwise dedup

    struct DedupCase {
        var name: String
        var expectedSame: Bool
        var a: (spec: ScreenSpec, clock: String, cursor: Bool)
        var b: (spec: ScreenSpec, clock: String, cursor: Bool)
    }

    static func dedupCases() -> [DedupCase] {
        let docLines = (0..<18).map { "第 \($0 + 1) 段：本周完成了离线同步的冲突合并，并补充了单元测试与文档说明" }
        let enLines = (0..<18).map { "Item \($0 + 1): reviewed the pull request for the sync engine and left comments" }
        let codeLines = (0..<22).map { "    let value\($0) = try await store.fetch(id: \"record-\($0)\", policy: .cacheFirst)" }
        let bases: [(String, ScreenSpec)] = [
            ("文档 16px", ScreenSpec(app: "备忘录", lines: docLines, fontSize: 16)),
            ("英文 12px", ScreenSpec(app: "Safari", lines: enLines, font: "Helvetica", fontSize: 12)),
            ("代码深色 13px", ScreenSpec(app: "Xcode", lines: codeLines, theme: .dark, font: "Menlo", fontSize: 13)),
        ]
        var cases: [DedupCase] = []
        for (name, base) in bases {
            func with(_ change: (inout ScreenSpec) -> Void) -> ScreenSpec {
                var s = base
                change(&s)
                return s
            }
            let plain = (base, "09:00", false)
            cases += [
                DedupCase(name: "\(name)·完全相同", expectedSame: true, a: plain, b: plain),
                DedupCase(name: "\(name)·光标闪烁", expectedSame: true, a: plain, b: (base, "09:00", true)),
                DedupCase(name: "\(name)·时钟跳动", expectedSame: true, a: plain, b: (base, "09:01", false)),
                DedupCase(name: "\(name)·光标+时钟", expectedSame: true, a: plain, b: (base, "09:01", true)),
                DedupCase(name: "\(name)·改一行", expectedSame: false, a: plain, b: (with { $0.lines[4] = String($0.lines[4].reversed()) }, "09:00", false)),
                DedupCase(name: "\(name)·改一个数字", expectedSame: false, a: plain, b: (with { $0.lines[2] = $0.lines[2].replacingOccurrences(of: "3", with: "8") }, "09:00", false)),
                DedupCase(name: "\(name)·追加一行", expectedSame: false, a: (with { $0.lines.removeLast() }, "09:00", false), b: plain),
                DedupCase(name: "\(name)·滚动三行", expectedSame: false, a: plain, b: (with { $0.lines = Array($0.lines.dropFirst(3)) + ["新出现的一行内容 A", "新出现的一行内容 B", "新出现的一行内容 C"] }, "09:00", false)),
                DedupCase(name: "\(name)·全部换掉", expectedSame: false, a: plain, b: (with { $0.lines = $0.lines.map { String($0.reversed()) } }, "09:00", false)),
                DedupCase(name: "\(name)·切换应用", expectedSame: false, a: plain, b: (with { $0.app = "Slack" }, "09:00", false)),
            ]
        }
        // "改一个数字"只在含 3 的行上才有变化；不含时跳过，避免把相同画面标成不同。
        return cases.filter { c in !(c.name.hasSuffix("改一个数字") && c.a.spec == c.b.spec) }
    }

    static func pairwiseDedup(ocr: any TextRecognizer) async -> (metrics: [Metric], notes: [String]) {
        var counts: [String: (fm: Int, diff: Int, fs: Int, same: Int)] = ["image": (0, 0, 0, 0), "text": (0, 0, 0, 0)]
        var failures: [String] = []
        var cache: [String: String] = [:]
        func text(_ image: CGImage, key: String) async -> String? {
            if let t = cache[key] { return t }
            guard let jpeg = try? JPEGEncoder.encode(image, quality: 0.85), let r = try? await ocr.recognize(jpeg: jpeg) else { return nil }
            cache[key] = r.text
            return r.text
        }
        for c in dedupCases() {
            let ia = SyntheticScreen.render(c.a.spec, clock: c.a.clock, cursor: c.a.cursor)
            let ib = SyntheticScreen.render(c.b.spec, clock: c.b.clock, cursor: c.b.cursor)
            let fa = ScreenFingerprint(image: ia), fb = ScreenFingerprint(image: ib)
            let ta = await text(ia, key: "\(c.a.spec.hashValue)|\(c.a.clock)|\(c.a.cursor)")
            let tb = await text(ib, key: "\(c.b.spec.hashValue)|\(c.b.clock)|\(c.b.cursor)")
            for (path, same) in [("image", fa.isSameScreen(as: fb)), ("text", fa.isSameScreen(as: fb, text: ta, otherText: tb))] {
                var x = counts[path]!
                if c.expectedSame {
                    x.same += 1
                    if !same { x.fs += 1; failures.append("\(path)：\(c.name) 应为同一屏") }
                } else {
                    x.diff += 1
                    if same { x.fm += 1; failures.append("\(path)：\(c.name) 应为不同画面") }
                }
                counts[path] = x
            }
        }
        let p = "perception.dedup.pairs"
        var metrics: [Metric] = []
        for (path, title) in [("image", "画面指纹（采集器使用）"), ("text", "画面指纹 + OCR 文字")] {
            let x = counts[path]!
            metrics += [
                .ratio("\(p).\(path).accuracy", "成对去重准确率·\(title)", x.same - x.fs + x.diff - x.fm, x.same + x.diff, direction: .higherIsBetter, gt: .synthetic),
                .ratio("\(p).\(path).falseMerge", "误合并率·\(title)", x.fm, x.diff, direction: .lowerIsBetter, gt: .synthetic),
                .ratio("\(p).\(path).falseSplit", "误拆分率·\(title)", x.fs, x.same, direction: .lowerIsBetter, gt: .synthetic),
            ]
        }
        return (metrics, failures.isEmpty ? [] : ["去重判错的样本：" + failures.joined(separator: "；")])
    }

    // MARK: - OCR

    struct OCRSample: Codable {
        var id: String
        var language: String
        var spec: ScreenSpec
    }

    struct OCRDetail: Codable {
        var sample: String
        var language: String
        var path: String
        var cer: Double
        var errors: Int
        var length: Int
        var lines: Int
        var linesRecovered: Int
        var ms: Double
    }

    static func ocrMetrics(_ samples: [OCRSample], ocr: any TextRecognizer, scratch: URL) async throws -> (metrics: [Metric], notes: [String], detail: [OCRDetail]) {
        defer { try? FileManager.default.removeItem(at: scratch) }
        // 正式路径：写进视频分段（H.264），再经 SpoolReader 解码成 JPEG——与抽取层读帧完全相同。
        let clock = FixedBenchmarkClock(date: Date(timeIntervalSince1970: 1_795_000_000))
        let spool = try RawSpool(root: scratch, limits: .default, clock: clock)
        let store = FrameStore(root: scratch, clock: clock)
        var refs: [FrameStore.FrameRef] = []
        for (i, s) in samples.enumerated() {
            refs.append(try await store.append(SyntheticScreen.render(s.spec), displayId: 1, at: clock.date.addingTimeInterval(Double(i) * 10)))
        }
        await store.finishSegment()
        let reader = SpoolReader(spool: spool)

        var detail: [OCRDetail] = []
        for (i, s) in samples.enumerated() {
            let reference = s.spec.visibleText
            var inputs: [(String, Data?)] = [("jpeg", try? JPEGEncoder.encode(SyntheticScreen.render(s.spec), quality: 0.85))]
            if case .available(let data) = await reader.frame(payloadRef: refs[i].segment, frameIndex: refs[i].frameIndex, maxHeight: 1080) {
                inputs.append(("video", data))
            } else {
                inputs.append(("video", nil))
            }
            for (path, data) in inputs {
                guard let data else { continue }
                let started = DispatchTime.now().uptimeNanoseconds
                let text = (try? await ocr.recognize(jpeg: data).text) ?? ""
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                let e = TextMetrics.characterErrors(reference: reference.joined(separator: "\n"), hypothesis: text)
                detail.append(OCRDetail(
                    sample: s.id, language: s.language, path: path, cer: Double(e.errors) / Double(max(e.length, 1)),
                    errors: e.errors, length: e.length,
                    lines: reference.count, linesRecovered: TextMetrics.linesRecovered(reference: reference, hypothesis: text), ms: ms
                ))
            }
        }
        func cer(_ rows: [OCRDetail]) -> (errors: Int, length: Int) {
            (rows.reduce(0) { $0 + $1.errors }, rows.reduce(0) { $0 + $1.length })
        }
        var metrics: [Metric] = []
        let p = "perception.ocr"
        for (path, title) in [("video", "正式路径（视频分段解码）"), ("jpeg", "直接 JPEG")] {
            let rows = detail.filter { $0.path == path }
            let c = cer(rows)
            metrics.append(Metric(
                id: "\(p).\(path).cer", name: "OCR 字符错误率·\(title)", value: c.length == 0 ? nil : Double(c.errors) / Double(c.length),
                numerator: Double(c.errors), denominator: Double(c.length), unit: .ratio, direction: .lowerIsBetter, groundTruth: .synthetic
            ))
            metrics.append(.ratio(
                "\(p).\(path).lineRecall", "OCR 整行识别率·\(title)", rows.reduce(0) { $0 + $1.linesRecovered }, rows.reduce(0) { $0 + $1.lines },
                direction: .higherIsBetter, gt: .synthetic, note: "归一化后整行作为子串出现"
            ))
        }
        for language in Set(samples.map(\.language)).sorted() {
            let rows = detail.filter { $0.path == "video" && $0.language == language }
            let c = cer(rows)
            metrics.append(Metric(
                id: "\(p).video.cer.\(language)", name: "OCR 字符错误率·\(language)", value: c.length == 0 ? nil : Double(c.errors) / Double(c.length),
                numerator: Double(c.errors), denominator: Double(c.length), unit: .ratio, direction: .lowerIsBetter, groundTruth: .synthetic
            ))
        }
        metrics.append(Metric(
            id: "\(p).ms.p50", name: "OCR 单帧耗时中位数", value: median(detail.map(\.ms)), unit: .milliseconds,
            direction: .lowerIsBetter, groundTruth: .measured, note: "评测机器上测得"
        ))
        let worst = detail.filter { $0.path == "video" }.sorted { $0.cer > $1.cer }.prefix(3)
        return (metrics, ["OCR 错误率最高的样本：" + worst.map { "\($0.sample) \(String(format: "%.1f%%", $0.cer * 100))" }.joined(separator: "，")], detail)
    }
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

struct FixedBenchmarkClock: AmaiClock {
    let date: Date
    func now() -> Date { date }
    func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

import AmaiCore
import AmaiPerception
import AmaiQAEval
import Foundation
import Testing
@testable import AmaiBenchmark

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("eval/benchmark/fixtures", isDirectory: true)

@Suite("Benchmark metrics")
struct BenchmarkMetricTests {
    @Test("edit distance and CER ignore whitespace and full-width forms")
    func cer() {
        #expect(TextMetrics.editDistance(Array("kitten"), Array("sitting")) == 3)
        #expect(TextMetrics.editDistance([Character](), Array("abc")) == 3)
        let same = TextMetrics.characterErrors(reference: "离线 同步 ABC", hypothesis: "离线同步ａｂｃ")
        #expect(same.errors == 0 && same.length == 7)
        let one = TextMetrics.characterErrors(reference: "3200 元", hypothesis: "3208 元")
        #expect(one.errors == 1 && one.length == 5)
        #expect(TextMetrics.linesRecovered(reference: ["第一行", "第二行"], hypothesis: "第 一 行\n其他") == 1)
    }

    @Test("anchors match after normalization")
    func anchors() {
        #expect(TextMetrics.contains("修复：离线重连后附件「重复上传」", "重复上传"))
        #expect(!TextMetrics.contains("anything", ""))
        #expect(TextMetrics.contains("token ghp_AmaiBenchCanary000", "BenchCanary"))
    }

    @Test("ratio metrics with an empty denominator have no value")
    func emptyRatio() {
        let m = Metric.ratio("x", "x", 0, 0, direction: .higherIsBetter, gt: .synthetic)
        #expect(m.value == nil && m.note?.contains("分母为 0") == true)
    }

    @Test("repeats are merged into a mean with per-run samples")
    func merge() {
        let a = SuiteResult(id: "s", title: "s", seconds: 2, metrics: [Metric.ratio("m", "m", 1, 2, direction: .higherIsBetter, gt: .synthetic)])
        let b = SuiteResult(id: "s", title: "s", seconds: 4, metrics: [Metric.ratio("m", "m", 2, 2, direction: .higherIsBetter, gt: .synthetic)])
        let merged = BenchmarkAggregation.merge([a, b])
        #expect(merged.metrics[0].value == 0.75)
        #expect(merged.metrics[0].samples == [0.5, 1])
        #expect(merged.seconds == 3)
    }
}

@Suite("Benchmark comparison")
struct BenchmarkComparisonTests {
    func run(_ metrics: [Metric], sha: String = "a") -> BenchmarkRun {
        var r = BenchmarkRun(runId: "r", label: "l", startedAt: Date(), gitCommit: nil, gitDirty: nil, machine: "m", repeats: 1, options: [:])
        r.suites = [SuiteResult(id: "s", title: "s", metrics: metrics, datasets: [DatasetRef(name: "d", path: "p", sha256: sha)])]
        return r
    }

    func m(_ id: String, _ v: Double, _ dir: MetricDirection = .higherIsBetter, gt: GroundTruthKind = .synthetic, unit: MetricUnit = .ratio) -> Metric {
        Metric(id: id, name: id, value: v, unit: unit, direction: dir, groundTruth: gt)
    }

    @Test("direction, threshold and missing metrics decide the verdict")
    func verdicts() {
        let base = run([m("up", 0.5), m("down", 0.2, .lowerIsBetter), m("flat", 0.5), m("ms", 100, .lowerIsBetter, unit: .milliseconds), m("gone", 1)])
        let new = run([m("up", 0.6), m("down", 0.3, .lowerIsBetter), m("flat", 0.51), m("ms", 105, .lowerIsBetter, unit: .milliseconds), m("added", 1)])
        let c = Dictionary(uniqueKeysWithValues: BenchmarkComparison.compare(base: base, new: new).map { ($0.id, $0.verdict) })
        #expect(c["up"] == .improved)
        #expect(c["down"] == .regressed)
        #expect(c["flat"] == .unchanged)
        #expect(c["ms"] == .unchanged)
        #expect(c["gone"] == .missing && c["added"] == .missing)
    }

    @Test("different ground truth or dataset makes numbers not comparable")
    func notComparable() {
        let gt = BenchmarkComparison.compare(base: run([m("x", 0.5, gt: .provisional)]), new: run([m("x", 0.9, gt: .human)]))
        #expect(gt[0].verdict == .notComparable)
        let data = BenchmarkComparison.compare(base: run([m("x", 0.5)], sha: "a"), new: run([m("x", 0.9)], sha: "b"))
        #expect(data[0].verdict == .notComparable)
    }

    @Test("a change within twice the repeat standard deviation is flagged as possible noise")
    func noise() {
        var noisy = m("x", 0.6)
        noisy.samples = [0.3, 0.9, 0.6]
        let c = BenchmarkComparison.compare(base: run([m("x", 0.5)]), new: run([noisy]))
        #expect(c[0].verdict == .improved && c[0].reason?.contains("噪声") == true)
    }

    @Test("the report lists metrics without ground truth separately")
    func report() {
        var r = run([m("x", 0.5), .missing("y", "人工准确率", reason: "需要人工审计", direction: .higherIsBetter)])
        r.suites[0].status = .ok
        let md = BenchmarkReport.markdown(r)
        #expect(md.contains("## 缺失的 Ground Truth"))
        #expect(md.contains("`y` 人工准确率：需要人工审计"))
    }
}

@Suite("Benchmark fixtures")
struct BenchmarkFixtureTests {
    @Test("the synthetic corpus builds and every question resolves to its evidence")
    func corpus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amai-bench-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = try await SyntheticCorpus.build(
            corpus: fixtures.appendingPathComponent("synthetic-memory.json"),
            questions: fixtures.appendingPathComponent("synthetic-qa.json"), at: root
        )
        #expect(corpus.catalog.days.count == 45)
        #expect(corpus.retrievalDataset.items.count == 50)
        #expect(corpus.qaDataset.items.count == 42)
        #expect(corpus.groundTruth.source == .synthetic)
        let answerable = corpus.qaDataset.items.filter(\.isAnswerable)
        #expect(answerable.allSatisfy { !$0.evidence.isEmpty && corpus.groundTruth.items[$0.id] != nil })
        // 题目的证据在数据集里，且每个信息点都有可用的记录。
        #expect(answerable.allSatisfy { corpus.qaDataset.evidence($0.evidence).count == $0.evidence.count })
        // 生成是确定的：同样的规格两次生成，摘要相同。
        let again = root.deletingLastPathComponent().appendingPathComponent("amai-bench-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: again) }
        let second = try await SyntheticCorpus.build(
            corpus: fixtures.appendingPathComponent("synthetic-memory.json"),
            questions: fixtures.appendingPathComponent("synthetic-qa.json"), at: again
        )
        #expect(second.qaDataset.memoryDigest == corpus.qaDataset.memoryDigest)
    }

    @Test("the activity script is contiguous, references existing activities, and keeps secrets off capturable screens")
    func script() throws {
        let script = try ActivityScript.load(fixtures.appendingPathComponent("activity-day.json"))
        let ranges = script.activities.map(script.range)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.end == b.start) }
        let ids = Set(script.activities.map(\.id))
        #expect(script.questions.allSatisfy { Set($0.activities).isSubset(of: ids) })
        let excluded = ExclusionListPolicy.defaultExcludedBundleIds
        for a in script.activities where script.expected(a, excludedBundleIds: excluded) == .capture {
            let text = a.screens.flatMap(\.spec.visibleText).joined(separator: "\n")
            #expect(!TextMetrics.contains(text, script.canaries["password"]!))
            #expect(!TextMetrics.contains(text, script.canaries["pausedDiary"]!))
        }
        // 每种跳过 / 停止的情形都至少出现一次。
        let expectations = script.activities.map { script.expected($0, excludedBundleIds: excluded) }
        for e: ActivityScript.Expected in [.blocked, .skip("userPaused"), .skip("secureInput"), .skip("excludedApp"), .capture] {
            #expect(expectations.contains(e))
        }
    }

    @Test("OCR samples decode")
    func ocrSamples() throws {
        let samples = try JSONDecoder().decode([PerceptionSuite.OCRSample].self, from: Data(contentsOf: fixtures.appendingPathComponent("ocr-samples.json")))
        #expect(samples.count >= 6)
        #expect(Set(samples.map(\.id)).count == samples.count)
    }
}

@Suite("Benchmark perception (simulated capture)")
struct BenchmarkCaptureTests {
    @Test("the simulated workday drives the real capturer: no privacy leaks, coverage and dedup are scored")
    func capture() async throws {
        let script = try ActivityScript.load(fixtures.appendingPathComponent("activity-day.json"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amai-bench-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = try await SimulatedCapture.run(script, root: root)
        #expect(trace.ticks.count == Int(script.end.timeIntervalSince(script.start) / script.captureInterval))
        let metrics = Dictionary(uniqueKeysWithValues: PerceptionSuite.coverageMetrics(trace, script: script).map { ($0.id, $0) })
        #expect(metrics["perception.capture.privacyLeak"]?.value == 0)
        #expect(metrics["perception.capture.skipReasonAccuracy"]?.value == 1)
        #expect(metrics["perception.capture.blockedAccuracy"]?.value == 1)
        #expect((metrics["perception.capture.timeCoverage"]?.value ?? 0) > 0.95)
        let dedup = PerceptionSuite.streamDedupMetrics(trace)
        #expect(dedup.allSatisfy { $0.denominator ?? 0 > 0 })
    }
}

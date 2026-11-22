import Foundation

// 统一 Quality Benchmark 的结果格式（docs/benchmark.md）。
//
// 每个指标都写明 Ground Truth 的来源：同一个数字，GT 是按构造已知的合成数据、人工标注、关键词锚点、
// 模型 Judge 还是临时 GT，可信程度完全不同；没有 GT 的指标只给出原因，不给数字。
// 版本间比较只在指标 id、GT 来源与数据集摘要都一致时才算"可比"。

/// 指标的 Ground Truth 来源。
public enum GroundTruthKind: String, Codable, Sendable, CaseIterable {
    /// 合成数据，答案按构造已知（渲染的文字、脚本化的活动、手写的期望）。
    case synthetic
    /// 人工标注。
    case human
    /// 关键词锚点近似：命中锚点即算找到。只能给出上界或下界，需要人工审计确认。
    case anchor
    /// 由模型 Judge 评分（标准答案是合成或人工的，但判定有噪声）。
    case judge
    /// 临时 GT：代码抽样的种子证据，未经人工确认。
    case provisional
    /// 没有 Ground Truth：不计算，只说明缺什么。
    case missing
    /// 实测值（耗时、数量），不需要 Ground Truth。
    case measured

    public var label: String {
        switch self {
        case .synthetic: "合成·按构造"
        case .human: "人工标注"
        case .anchor: "锚点近似"
        case .judge: "模型 Judge"
        case .provisional: "临时 GT"
        case .missing: "缺失"
        case .measured: "实测"
        }
    }
}

/// 数据来源：合成数据，还是真实（本人授权的）数据。
public enum DataOrigin: String, Codable, Sendable {
    case synthetic
    case real
}

public enum MetricDirection: String, Codable, Sendable {
    case higherIsBetter
    case lowerIsBetter
    /// 仅供参考（数量、分布），不判断好坏。
    case info
}

public enum MetricUnit: String, Codable, Sendable {
    case ratio
    case count
    case milliseconds
    case seconds
    case megabytes
    case minutes
    case score
}

public struct Metric: Codable, Sendable, Equatable {
    /// 稳定的标识，例如 `perception.ocr.cer`。版本间比较按它对齐。
    public var id: String
    public var name: String
    /// nil：无法计算（GT 缺失、依赖的模型未安装、分母为 0）。原因写在 `note`。
    public var value: Double?
    public var numerator: Double?
    public var denominator: Double?
    public var unit: MetricUnit
    public var direction: MetricDirection
    public var groundTruth: GroundTruthKind
    public var origin: DataOrigin
    public var note: String?
    /// 重复运行时每次的值（只有一次时为空）。
    public var samples: [Double]?

    public init(
        id: String, name: String, value: Double?, numerator: Double? = nil, denominator: Double? = nil,
        unit: MetricUnit = .ratio, direction: MetricDirection, groundTruth: GroundTruthKind,
        origin: DataOrigin = .synthetic, note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.numerator = numerator
        self.denominator = denominator
        self.unit = unit
        self.direction = direction
        self.groundTruth = groundTruth
        self.origin = origin
        self.note = note
    }

    /// 比例：分母为 0 时值为 nil。
    public static func ratio(
        _ id: String, _ name: String, _ numerator: Int, _ denominator: Int, direction: MetricDirection,
        gt: GroundTruthKind, origin: DataOrigin = .synthetic, note: String? = nil
    ) -> Metric {
        Metric(
            id: id, name: name, value: denominator == 0 ? nil : Double(numerator) / Double(denominator),
            numerator: Double(numerator), denominator: Double(denominator), unit: .ratio,
            direction: direction, groundTruth: gt, origin: origin,
            note: denominator == 0 ? (note.map { $0 + "；" } ?? "") + "分母为 0" : note
        )
    }

    /// 没有 Ground Truth 的指标：列出来，说明缺什么，不给数字。
    public static func missing(_ id: String, _ name: String, reason: String, unit: MetricUnit = .ratio, direction: MetricDirection, origin: DataOrigin = .synthetic) -> Metric {
        Metric(id: id, name: name, value: nil, unit: unit, direction: direction, groundTruth: .missing, origin: origin, note: reason)
    }
}

public struct SuiteResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        /// 依赖的模型或数据不可用，整组没有运行。
        case skipped
        case failed
    }

    public var id: String
    public var title: String
    public var status: Status
    public var reason: String?
    public var seconds: Double
    public var metrics: [Metric]
    /// 用到的数据集及其摘要（版本间比较时检查是否同一份）。
    public var datasets: [DatasetRef]
    /// 用到的模型。
    public var models: [String: String]
    public var notes: [String]
    /// 明细文件（相对本次运行目录）。
    public var details: [String]

    public init(
        id: String, title: String, status: Status = .ok, reason: String? = nil, seconds: Double = 0,
        metrics: [Metric] = [], datasets: [DatasetRef] = [], models: [String: String] = [:],
        notes: [String] = [], details: [String] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.reason = reason
        self.seconds = seconds
        self.metrics = metrics
        self.datasets = datasets
        self.models = models
        self.notes = notes
        self.details = details
    }

    public static func skipped(_ id: String, _ title: String, reason: String) -> SuiteResult {
        SuiteResult(id: id, title: title, status: .skipped, reason: reason)
    }
}

public struct DatasetRef: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var sha256: String
    public var origin: DataOrigin

    public init(name: String, path: String, sha256: String, origin: DataOrigin = .synthetic) {
        self.name = name
        self.path = path
        self.sha256 = sha256
        self.origin = origin
    }
}

public struct BenchmarkRun: Codable, Sendable {
    public static let schema = "amai-bench/1"

    public var schema = BenchmarkRun.schema
    public var runId: String
    public var label: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var gitCommit: String?
    /// 工作区有未提交的改动：结果对应的不是某个确切的提交。
    public var gitDirty: Bool?
    public var machine: String
    public var repeats: Int
    public var options: [String: String]
    public var suites: [SuiteResult]

    public init(runId: String, label: String, startedAt: Date, gitCommit: String?, gitDirty: Bool?, machine: String, repeats: Int, options: [String: String], suites: [SuiteResult] = []) {
        self.runId = runId
        self.label = label
        self.startedAt = startedAt
        self.gitCommit = gitCommit
        self.gitDirty = gitDirty
        self.machine = machine
        self.repeats = repeats
        self.options = options
        self.suites = suites
    }

    public var allMetrics: [Metric] { suites.flatMap(\.metrics) }
}

// MARK: - Repeats

public enum BenchmarkAggregation {
    /// 把同一组的多次运行合并：每个指标取均值，保留每次的值。状态取最差的一次。
    public static func merge(_ runs: [SuiteResult]) -> SuiteResult {
        guard var merged = runs.first else { preconditionFailure("merge needs at least one run") }
        guard runs.count > 1 else { return merged }
        if let failed = runs.first(where: { $0.status != .ok }) {
            merged.status = failed.status
            merged.reason = failed.reason
        }
        merged.seconds = runs.map(\.seconds).reduce(0, +) / Double(runs.count)
        var byId: [String: [Metric]] = [:]
        for run in runs { for m in run.metrics { byId[m.id, default: []].append(m) } }
        merged.metrics = merged.metrics.map { first in
            let all = byId[first.id] ?? [first]
            let values = all.compactMap(\.value)
            var m = first
            m.samples = values
            m.value = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            if values.count < all.count { m.note = (m.note.map { $0 + "；" } ?? "") + "\(all.count - values.count)/\(all.count) 次没有值" }
            let nums = all.compactMap(\.numerator), dens = all.compactMap(\.denominator)
            m.numerator = nums.count == all.count ? nums.reduce(0, +) / Double(nums.count) : nil
            m.denominator = dens.count == all.count ? dens.reduce(0, +) / Double(dens.count) : nil
            return m
        }
        merged.notes.append("重复 \(runs.count) 次：指标为均值，samples 为每次的值")
        return merged
    }

    public static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)).squareRoot()
    }
}

// MARK: - Comparison

public struct MetricComparison: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case improved, regressed, unchanged, info
        /// 两边 GT 来源或数据集不同，数字不能直接比较。
        case notComparable
        /// 只在一边出现，或一边没有值。
        case missing
    }

    public var id: String
    public var name: String
    public var suite: String
    public var base: Double?
    public var new: Double?
    public var delta: Double?
    public var unit: MetricUnit
    public var groundTruth: GroundTruthKind
    public var verdict: Verdict
    public var reason: String?
}

public enum BenchmarkComparison {
    /// 判定为变化的最小差值：比例 2 个百分点；延迟等其余单位按相对 10%。
    public static func threshold(for metric: Metric, ratioThreshold: Double) -> (absolute: Double?, relative: Double?) {
        metric.unit == .ratio || metric.unit == .score ? (ratioThreshold, nil) : (nil, 0.10)
    }

    public static func compare(base: BenchmarkRun, new: BenchmarkRun, ratioThreshold: Double = 0.02) -> [MetricComparison] {
        func index(_ run: BenchmarkRun) -> [String: (suite: SuiteResult, metric: Metric)] {
            var table: [String: (SuiteResult, Metric)] = [:]
            for s in run.suites { for m in s.metrics { table[m.id] = (s, m) } }
            return table
        }
        let a = index(base), b = index(new)
        // 只比较两边都运行了的组；只在一边运行的组由 `suitesOnlyInOne` 单独列出。
        let common = Set(base.suites.filter { $0.status == .ok }.map(\.id)).intersection(new.suites.filter { $0.status == .ok }.map(\.id))
        var order: [String] = []
        for s in new.suites where common.contains(s.id) { for m in s.metrics where !order.contains(m.id) { order.append(m.id) } }
        for s in base.suites where common.contains(s.id) { for m in s.metrics where !order.contains(m.id) { order.append(m.id) } }

        return order.map { id in
            let left = a[id], right = b[id]
            let metric = (right ?? left)!.metric
            var c = MetricComparison(
                id: id, name: metric.name, suite: (right ?? left)!.suite.id, base: left?.metric.value, new: right?.metric.value,
                delta: nil, unit: metric.unit, groundTruth: metric.groundTruth, verdict: .missing, reason: nil
            )
            guard let l = left, let r = right else {
                c.reason = left == nil ? "基线没有这个指标" : "新版本没有这个指标"
                return c
            }
            if l.metric.groundTruth != r.metric.groundTruth {
                c.verdict = .notComparable
                c.reason = "GT 来源不同：\(l.metric.groundTruth.label) → \(r.metric.groundTruth.label)"
                return c
            }
            if !datasetsMatch(l.suite.datasets, r.suite.datasets) {
                c.verdict = .notComparable
                c.reason = "数据集摘要不同"
                return c
            }
            guard let x = l.metric.value, let y = r.metric.value else {
                c.reason = "一边没有值"
                return c
            }
            c.delta = y - x
            if metric.direction == .info {
                c.verdict = .info
                return c
            }
            let t = threshold(for: metric, ratioThreshold: ratioThreshold)
            let significant: Bool
            if let abs_ = t.absolute { significant = abs(y - x) >= abs_ - 1e-12 } else {
                significant = x == 0 ? y != 0 : abs(y - x) / abs(x) >= (t.relative ?? 0.1)
            }
            guard significant else {
                c.verdict = .unchanged
                return c
            }
            let better = metric.direction == .higherIsBetter ? y > x : y < x
            c.verdict = better ? .improved : .regressed
            if let samples = r.metric.samples, let sd = BenchmarkAggregation.standardDeviation(samples), abs(y - x) < 2 * sd {
                c.reason = "差值小于新版本重复运行标准差的 2 倍（\(String(format: "%.3f", sd))），可能是噪声"
            }
            return c
        }
    }

    /// 只在一边运行（或一边跳过 / 失败）的组。
    public static func suitesOnlyInOne(base: BenchmarkRun, new: BenchmarkRun) -> [String] {
        let a = Set(base.suites.filter { $0.status == .ok }.map(\.id)), b = Set(new.suites.filter { $0.status == .ok }.map(\.id))
        return (base.suites + new.suites).map(\.id).filter { a.contains($0) != b.contains($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    static func datasetsMatch(_ a: [DatasetRef], _ b: [DatasetRef]) -> Bool {
        let left = Dictionary(a.map { ($0.name, $0.sha256) }, uniquingKeysWith: { x, _ in x })
        let right = Dictionary(b.map { ($0.name, $0.sha256) }, uniquingKeysWith: { x, _ in x })
        // 只比较两边都用到的数据集；一边多出来的（例如另一侧没导入真实评测）不影响其余指标。
        return left.keys.filter { right[$0] != nil }.allSatisfy { left[$0] == right[$0] }
    }
}

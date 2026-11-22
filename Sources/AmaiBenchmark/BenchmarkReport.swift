import Foundation

/// 统一报告（Markdown）。只含指标与说明，不含记忆正文或屏幕文字。
public enum BenchmarkReport {
    static func format(_ value: Double?, _ unit: MetricUnit) -> String {
        guard let value else { return "—" }
        switch unit {
        case .ratio: return String(format: "%.1f%%", value * 100)
        case .count: return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        case .milliseconds: return String(format: "%.0f ms", value)
        case .seconds: return String(format: "%.1f s", value)
        case .megabytes: return String(format: "%.0f MB", value)
        case .minutes: return String(format: "%.1f 分", value)
        case .score: return String(format: "%.3f", value)
        }
    }

    static func fraction(_ m: Metric) -> String {
        guard m.unit == .ratio, let n = m.numerator, let d = m.denominator else { return "" }
        func f(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x) }
        return "\(f(n))/\(f(d))"
    }

    static func arrow(_ d: MetricDirection) -> String {
        switch d {
        case .higherIsBetter: "↑"
        case .lowerIsBetter: "↓"
        case .info: ""
        }
    }

    static func spread(_ m: Metric) -> String {
        guard let s = m.samples, s.count > 1, let lo = s.min(), let hi = s.max() else { return "" }
        return "\(format(lo, m.unit))–\(format(hi, m.unit))"
    }

    public static func markdown(_ run: BenchmarkRun) -> String {
        var lines = [
            "# Amai Quality Benchmark · \(run.label)",
            "",
            "- 运行：`\(run.runId)`，\(ISO8601DateFormatter().string(from: run.startedAt))"
                + (run.finishedAt.map { "，用时 \(Int($0.timeIntervalSince(run.startedAt))) 秒" } ?? ""),
            "- 代码：`\(run.gitCommit ?? "未知")`" + (run.gitDirty == true ? "（**工作区有未提交改动**）" : ""),
            "- 机器：\(run.machine)；重复 \(run.repeats) 次",
        ]
        if !run.options.isEmpty {
            lines.append("- 选项：" + run.options.keys.sorted().map { "\($0)=`\(run.options[$0]!)`" }.joined(separator: "，"))
        }
        lines += [
            "",
            "GT 来源：**合成·按构造**＝答案由构造已知；**锚点近似**＝关键词命中，只是上界或下界；**模型 Judge**＝本地模型按固定规则评分，有噪声；"
                + "**临时 GT**＝代码抽样，未经人工确认；**缺失**＝没有 Ground Truth，不计算；**实测**＝耗时与数量。数据来源 real 表示本人授权的真实记忆（只导入计数）。",
            "",
            "## 总览",
            "",
            "| 组 | 状态 | 用时 | 指标数 | 说明 |",
            "|---|---|---|---|---|",
        ]
        for s in run.suites {
            let status = switch s.status {
            case .ok: "✅"
            case .skipped: "⏭ 跳过"
            case .failed: "❌ 失败"
            }
            lines.append("| \(s.title) | \(status) | \(format(s.seconds, .seconds)) | \(s.metrics.filter { $0.value != nil }.count)/\(s.metrics.count) | \(s.reason ?? "") |")
        }
        for s in run.suites {
            lines += ["", "## \(s.title)", ""]
            if let reason = s.reason { lines += ["> \(s.status == .ok ? "" : "未运行：")\(reason)", ""] }
            if !s.models.isEmpty {
                lines.append("- 模型：" + s.models.keys.sorted().map { "\($0) `\(s.models[$0]!)`" }.joined(separator: "，"))
            }
            for d in s.datasets {
                lines.append("- 数据：\(d.name)（\(d.origin.rawValue)，`\(d.path)`，sha256 `\(d.sha256.prefix(12))`）")
            }
            if !s.metrics.isEmpty {
                lines += ["", "| 指标 | 值 | 计数 | 范围 | GT | 数据 | 说明 |", "|---|---|---|---|---|---|---|"]
                for m in s.metrics {
                    lines.append("| \(m.name) \(arrow(m.direction)) | \(format(m.value, m.unit)) | \(fraction(m)) | \(spread(m)) | \(m.groundTruth.label) | \(m.origin.rawValue) | \(m.note ?? "") |")
                }
            }
            if !s.notes.isEmpty {
                lines.append("")
                for n in s.notes { lines.append("- \(n)") }
            }
            if !s.details.isEmpty {
                lines.append("- 明细：" + s.details.map { "`\($0)`" }.joined(separator: "，"))
            }
        }
        let missing = run.allMetrics.filter { $0.groundTruth == .missing }
        if !missing.isEmpty {
            lines += ["", "## 缺失的 Ground Truth", "", "这些指标目前没有可信的标准答案，**没有计算**，也没有用合成或推测的数据代替：", ""]
            for m in missing { lines.append("- `\(m.id)` \(m.name)：\(m.note ?? "")") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func comparisonMarkdown(base: BenchmarkRun, new: BenchmarkRun, comparisons: [MetricComparison]) -> String {
        func describe(_ r: BenchmarkRun) -> String {
            "`\(r.runId)`（\(r.label)，代码 `\(r.gitCommit?.prefix(8) ?? "?")`\(r.gitDirty == true ? "，有未提交改动" : "")）"
        }
        var lines = [
            "# Benchmark 对比",
            "",
            "- 基线：\(describe(base))",
            "- 新版：\(describe(new))",
            "- 判定阈值：比例类 2 个百分点，其余按相对 10%；GT 来源或数据集摘要不同的指标标为不可比，不给结论。",
            "",
        ]
        let oneSided = BenchmarkComparison.suitesOnlyInOne(base: base, new: new)
        if !oneSided.isEmpty { lines += ["只在一边成功运行、未参与比较的组：" + oneSided.joined(separator: "、"), ""] }
        let counts = Dictionary(grouping: comparisons, by: \.verdict).mapValues(\.count)
        lines.append("变好 \(counts[.improved] ?? 0) · 变差 \(counts[.regressed] ?? 0) · 持平 \(counts[.unchanged] ?? 0) · 不可比 \(counts[.notComparable] ?? 0) · 缺值 \(counts[.missing] ?? 0)")
        let regressions = comparisons.filter { $0.verdict == .regressed }
        if !regressions.isEmpty {
            lines += ["", "## ⚠️ 变差", ""]
            for c in regressions {
                lines.append("- `\(c.id)` \(c.name)：\(format(c.base, c.unit)) → \(format(c.new, c.unit))\(c.reason.map { "（\($0)）" } ?? "")")
            }
        }
        lines += ["", "## 全部指标", "", "| 组 | 指标 | 基线 | 新版 | 差值 | GT | 结论 |", "|---|---|---|---|---|---|---|"]
        for c in comparisons {
            let verdict = switch c.verdict {
            case .improved: "✅ 变好"
            case .regressed: "⚠️ 变差"
            case .unchanged: "持平"
            case .info: "参考"
            case .notComparable: "不可比"
            case .missing: "缺值"
            }
            let delta = c.delta.map { d -> String in
                c.unit == .ratio ? String(format: "%+.1f pp", d * 100) : String(format: "%+.2f", d)
            } ?? ""
            lines.append("| \(c.suite) | \(c.name) | \(format(c.base, c.unit)) | \(format(c.new, c.unit)) | \(delta) | \(c.groundTruth.label) | \(verdict)\(c.reason.map { "：\($0)" } ?? "") |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

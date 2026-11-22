import AmaiCore
import AmaiInference
import AmaiMemory
import AmaiMemoryEval
import Foundation

/// 记忆生成：复用记忆整理评测（`MemoryEvaluation`，eval/memory 的 17 个合成场景），
/// 加上不依赖模型的时间线保真度检查。
///
/// 自动评分只能用关键词锚点：期望事实"找到"、不应出现的内容"命中"都是锚点近似。
/// 写入了、但没有对应期望的条目可能是正确的额外信息，也可能是幻觉，自动评分无法区分，
/// 因此"事实准确率"只给下界，真正的准确率需要按 eval/memory/audits 的口径逐条人工审计。
public enum MemorySuite {
    public static let id = "memory"

    public static func run(_ ctx: BenchmarkContext) async -> SuiteResult {
        let started = Date()
        var result = SuiteResult(id: id, title: "记忆生成")
        let dev = ctx.fixtures.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("memory/scenarios.json")
        let heldout = dev.deletingLastPathComponent().appendingPathComponent("heldout.json")
        do {
            let sets = [("dev", try MemoryEvaluation.load(dev)), ("heldout", try MemoryEvaluation.load(heldout))]
            result.datasets = [ctx.dataset("memory-scenarios", dev), ctx.dataset("memory-heldout", heldout)]
            result.metrics += await timelineFidelity(sets.flatMap(\.1))

            guard let tag = ctx.models.memory else {
                result.reason = "没有可用的记忆整理模型：只运行了不依赖模型的时间线检查"
                result.metrics += modelMetricsMissing("未运行（没有模型）")
                result.seconds = Date().timeIntervalSince(started)
                return result
            }
            result.models["memory"] = tag
            let model = BenchmarkMemoryModel(provider: MLXModelProvider(modelTag: tag))
            var summaries: [(String, EvalSummary)] = []
            for (name, scenarios) in sets {
                ctx.log("记忆生成：\(name) \(scenarios.count) 个场景（\(tag)）")
                summaries.append((name, await MemoryEvaluation.run(scenarios, model: model)))
            }
            await model.provider.unload(reason: "benchmark memory suite finished")
            let all = EvalSummary(model: model.identifier, results: summaries.flatMap { $0.1.results })
            result.metrics += metrics(all, suffix: nil)
            for (name, s) in summaries { result.metrics += metrics(s, suffix: name).filter { $0.id.contains("factRecall") || $0.id.contains("falseMemory") } }
            result.metrics.append(.missing(
                "memory.precision.human", "事实准确率（人工审计）",
                reason: "需要对本次写入逐条人工审计（明细 details/memory-report.md，口径见 eval/memory/audits/）；自动评分不能区分正确的额外信息与幻觉",
                direction: .higherIsBetter
            ))
            result.metrics.append(.missing(
                "memory.timeline.sourceDate", "写入条目的来源日期准确率",
                reason: "场景只标了事实锚点，没有标注每条事实应引用的日期",
                direction: .higherIsBetter
            ))
            try ctx.writeDetail("memory-report.md", text: all.report())
            try ctx.writeDetail("memory-results.json", all.results)
            result.details += ["details/memory-report.md", "details/memory-results.json"]
            result.notes.append("参考：2026-11-03 的人工审计（eval/memory/audits/2026-11-03.md，较早的代码版本）中 Gemma 4 E4B 的人工 Precision 为 47%、Recall 39%；不是本次运行的结果，不能直接比较。")
            let errors = all.results.flatMap(\.errors)
            if !errors.isEmpty { result.notes.append("整理出错 \(errors.count) 次（见明细）") }
        } catch {
            result.status = .failed
            result.reason = "\(error)"
        }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    static func modelMetricsMissing(_ reason: String) -> [Metric] {
        [
            Metric(id: "memory.factRecall", name: "事实召回率", value: nil, direction: .higherIsBetter, groundTruth: .anchor, note: reason),
            Metric(id: "memory.falseMemory", name: "错误记忆率（不应出现的内容）", value: nil, direction: .lowerIsBetter, groundTruth: .anchor, note: reason),
        ]
    }

    static func metrics(_ s: EvalSummary, suffix: String?) -> [Metric] {
        func sum(_ k: KeyPath<EvalResult, Int>) -> Int { s.results.reduce(0) { $0 + $1[keyPath: k] } }
        let tag = suffix.map { ".\($0)" } ?? ""
        let label = suffix.map { "·\($0)" } ?? ""
        let found = sum(\.factsFound), expected = sum(\.factsExpected), written = sum(\.itemsWritten)
        var m: [Metric] = [
            .ratio("memory.factRecall\(tag)", "事实召回率\(label)", found, expected, direction: .higherIsBetter, gt: .anchor,
                   note: "期望事实的全部锚点出现在同一条有效条目中"),
            .ratio("memory.falseMemory\(tag)", "错误记忆率（不应出现的内容命中）\(label)", sum(\.forbiddenHits), sum(\.forbiddenChecked), direction: .lowerIsBetter, gt: .anchor,
                   note: "只覆盖场景列出的错误类型（第三方数据、阅读当计划、把关注写成诊断等），是幻觉率的下界"),
        ]
        guard suffix == nil else { return m }
        m += [
            .ratio("memory.omission", "遗漏率", expected - found, expected, direction: .lowerIsBetter, gt: .anchor),
            .ratio("memory.misattribution", "错误归属率", sum(\.factsMisattributed), expected, direction: .lowerIsBetter, gt: .anchor),
            .ratio("memory.precision.lowerBound", "事实准确率下界（写入中命中期望事实）", min(found, written), written, direction: .higherIsBetter, gt: .anchor,
                   note: "未命中期望的写入不一定错，真实准确率 ≥ 此值"),
            .ratio("memory.unmatchedWritten", "未匹配期望的写入比例", max(0, written - found), written, direction: .info, gt: .anchor,
                   note: "正确的额外信息与幻觉的总和，需要人工审计区分；幻觉率 ≤ 此值"),
            .ratio("memory.superseded", "跨天变化处理正确率", sum(\.supersededHandled), sum(\.supersededChecked), direction: .higherIsBetter, gt: .anchor,
                   note: "旧信息撤下、新信息有效"),
            Metric(id: "memory.contradictions", name: "新旧信息同时有效", value: Double(s.contradictions), unit: .count, direction: .lowerIsBetter, groundTruth: .anchor),
            .ratio("memory.routingRecall", "类别路由召回率", sum(\.routeHit), sum(\.routeExpected), direction: .higherIsBetter, gt: .synthetic),
            Metric(id: "memory.routeExtra", name: "多余路由", value: Double(sum(\.routeExtra)), unit: .count, direction: .lowerIsBetter, groundTruth: .synthetic),
            .ratio("memory.malformed", "结构化输出不合格率", sum(\.malformedOutputs), sum(\.modelCalls), direction: .lowerIsBetter, gt: .synthetic),
            Metric(id: "memory.itemsWritten", name: "写入条目数", value: Double(written), unit: .count, direction: .info, groundTruth: .measured),
            Metric(id: "memory.modelCalls", name: "模型调用次数", value: Double(sum(\.modelCalls)), unit: .count, direction: .info, groundTruth: .measured),
        ]
        return m
    }

    /// 时间线保真度：活动片段写进 daily 后再读回，起止时间、标题、摘要与顺序都应不变（确定性，不需要模型）。
    static func timelineFidelity(_ scenarios: [EvalScenario]) async -> [Metric] {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var total = 0, exact = 0, ordered = 0, days = 0
        for s in scenarios {
            for d in s.days {
                guard let segs = d.segments, !segs.isEmpty else { continue }
                let parts = d.date.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3, let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { continue }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("amai-bench-tl-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                guard let store = try? MemoryStore(root: root, timeZone: utc) else { continue }
                func time(_ hhmm: String) -> Date? {
                    let p = hhmm.split(separator: ":").compactMap { Double($0) }
                    return p.count == 2 ? day.addingTimeInterval(p[0] * 3600 + p[1] * 60) : nil
                }
                let segments: [ActivitySegment] = segs.compactMap { seg in
                    guard let start = time(seg.start), let end = time(seg.end), end > start else { return nil }
                    return ActivitySegment(
                        timeRange: TimeRange(start: start, end: end), title: seg.title, summary: seg.summary ?? "",
                        category: seg.category ?? .work, apps: seg.apps ?? [], observations: [], confidence: seg.confidence ?? 0.85,
                        provider: "bench", updatedAt: end
                    )
                }
                _ = try? await store.writeDailyTimeline(day: day, segments: segments)
                let api = MemoryAPI(root: root, index: nil, access: .all, timeZone: utc)
                guard let timeline = try? api.timeline(on: d.date) else { continue }
                days += 1
                let sorted = segs.sorted { $0.start < $1.start }
                for seg in sorted {
                    total += 1
                    if timeline.entries.contains(where: { $0.start == seg.start && $0.end == seg.end && $0.title == seg.title && $0.summary == (seg.summary ?? "") }) {
                        exact += 1
                    }
                }
                if timeline.entries.map(\.start) == sorted.map(\.start) { ordered += 1 }
            }
        }
        return [
            .ratio("memory.timeline.fidelity", "时间线保真度（片段写入 daily 后起止时间、标题、摘要一致）", exact, total, direction: .higherIsBetter, gt: .synthetic),
            .ratio("memory.timeline.order", "时间线顺序正确的天数", ordered, days, direction: .higherIsBetter, gt: .synthetic),
        ]
    }
}

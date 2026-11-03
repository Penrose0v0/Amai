import AmaiCore
import AmaiMemoryEval
import Foundation
import Testing
@testable import AmaiMemory

@Suite("MemoryEvaluation")
struct EvaluationTests {
    static let scenariosURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("eval/memory/scenarios.json")

    /// 按提示词里的日期与分区返回固定输出。
    final class OracleModel: MemoryLanguageModel, @unchecked Sendable {
        let identifier = "oracle:test"
        var routes: [String: [String]] = [:]
        var operations: [String: String] = [:]

        func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
            let day = user.split(separator: "\n").first { $0.hasPrefix("日期：") || $0.hasPrefix("今天：") }
                .map { String($0.split(separator: "：").last ?? "") } ?? ""
            if system == Prompts.digestSystem { return Responses.digest(routes: routes[day] ?? []) }
            let category = MemoryCategory.documents.first { system.contains("（\($0.rawValue).md）") }?.rawValue ?? ""
            return operations["\(day)/\(category)"] ?? #"{"operations":[]}"#
        }
    }

    @Test("bundled scenarios decode and only use synthetic dates")
    func scenariosDecode() throws {
        let scenarios = try MemoryEvaluation.load(Self.scenariosURL)
        #expect(scenarios.count >= 7)
        #expect(scenarios.allSatisfy { !$0.days.isEmpty })
        #expect(Set(scenarios.map(\.name)).count == scenarios.count)
    }

    @Test("scoring counts routing, facts, kinds and forbidden content")
    func goodRun() async throws {
        let scenario = try #require(try MemoryEvaluation.load(Self.scenariosURL).first { $0.name == "health-self-versus-third-party" })
        let model = OracleModel()
        model.routes["2026-10-15"] = ["health"]
        model.operations["2026-10-15/health"] = Responses.ops([
            ["op": "add", "section": "健康关注", "text": "这周右膝盖一直疼，暂停跑步", "evidence": ["S1"], "subject": "self"],
            ["op": "add", "section": "健康关注", "text": "妈妈血压偏高", "evidence": ["S2"], "subject": "third_party"],
            ["op": "add", "section": "健康关注", "text": "关注糖尿病饮食", "evidence": ["I1"], "subject": "self"],
        ])
        let r = await MemoryEvaluation.run(scenario, model: model)
        #expect(r.errors.isEmpty)
        #expect(r.routeHit == 1 && r.routeExpected == 1 && r.routeExtra == 0)
        #expect(r.factsFound == 1 && r.kindCorrect == 1)
        #expect(r.forbiddenHits == 0 && r.forbiddenChecked == 4)
        #expect(r.rejectedOperations == 2)
        #expect(r.itemsWritten == 1)
    }

    @Test("scoring reports missed routes, omissions, misattribution, false memories and contradictions")
    func badRun() async throws {
        let all = try MemoryEvaluation.load(Self.scenariosURL)
        let goals = try #require(all.first { $0.name == "goal-change-across-days" })
        let model = OracleModel()
        model.routes["2026-10-10"] = ["goals"]
        model.routes["2026-10-12"] = ["work"]
        model.operations["2026-10-10/goals"] = Responses.ops([
            ["op": "add", "section": "计划", "text": "计划 12 月把论文投到 CHI", "evidence": ["S1"]],
            ["op": "add", "section": "计划", "text": "周末看了电影", "evidence": ["I1"]],
        ])
        model.operations["2026-10-12/work"] = Responses.ops([
            ["op": "add", "project": "new:论文", "text": "论文改投明年 4 月的 UIST", "evidence": ["S1"]],
        ])
        let r = await MemoryEvaluation.run(goals, model: model)
        #expect(r.routeExpected == 4 && r.routeHit == 2)
        #expect(r.factsFound == 0 && r.factsMisattributed == 1)
        #expect(r.supersededHandled == 0)
        #expect(r.forbiddenHits == 1)

        let summary = EvalSummary(model: model.identifier, results: [r])
        #expect(summary.routingRecall == 0.5)
        #expect(summary.omissionRate == 1)
        #expect(summary.report().contains("类别路由召回率 | 50%"))
    }
}

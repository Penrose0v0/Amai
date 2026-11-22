import AmaiCore
import Foundation
import Testing
@testable import AmaiMemory

/// "删除时间段"在记忆层的完整性。App 的 `AppModel.eraseData` 依次：删原始数据 → 删抽取结果 →
/// 对受影响的日期调用 `Consolidator.forgetDay`（日终摘要与快照）→ `MemorySync.rewrite(day:)` → `syncOnce()`（刷新索引）。
/// 这里用真实的 MemoryStore / MemorySync / MemoryIndex / Consolidator / SnapshotStore 复现记忆层这一段：
/// 抽取结果删除后，片段来源对这一天返回空。
///
/// 删的是一整天，这样"这一天的内容是否还留在某处"没有歧义（日终摘要无法按时间段局部裁剪）。
@Suite("Erase completeness (memory layer)", .serialized)
struct EraseCompletenessTests {
    typealias Fixture = ConsolidatorTests.Fixture

    /// 一天的活动经过整理（日终摘要 + work 条目 + 改写前快照），然后整天被删除。
    private func consolidatedThenErased() async throws -> (Fixture, MemoryIndex) {
        let f = try Fixture()
        try await f.seedDay()
        f.model.operations[.work] = Responses.ops([
            ["op": "add", "project": "new:Amai", "text": "修改了 ScreenFrameSource.swift", "evidence": ["I1"]],
        ])
        let report = try await f.consolidator.consolidateDay(f.day)
        #expect(report.digestWritten)
        #expect(try f.items(.work).map(\.text) == ["修改了 ScreenFrameSource.swift"])

        let index = MemoryIndex(root: f.root, database: try .inMemory(), timeZone: utc)
        let sync = MemorySync(
            source: f.source, store: f.store, index: index,
            stateURL: f.support.appendingPathComponent("memory-sync.json"), clock: FixedClock(f.day), lookbackDays: 1
        )
        // 抽取层删除后：这一天没有片段了。
        f.source.set([], on: f.day)
        try await f.consolidator.forgetDay(f.day)
        try await sync.rewrite(day: f.day)
        await sync.syncOnce()
        return (f, index)
    }

    @Test("erased timeline entries leave the daily file and the search index")
    func timelineAndIndex() async throws {
        let (f, index) = try await consolidatedThenErased()
        defer { f.cleanup() }
        let daily = try f.read("daily/2026-10-19.md")
        #expect(!daily.contains("编辑采集代码") && !daily.contains("查阅论文"))
        #expect(daily.hasPrefix("# 2026-10-19"))
        #expect(try await index.retrieve("编辑采集代码").isEmpty)
    }

    /// 回归：日终摘要也是 daily 中的系统区块，内容来自这一天的片段；删除后曾原样保留并可被 MCP / 助手检索到。
    /// 现在整块去掉（连同变空的"摘要"标题），区块外的用户笔记保留。
    @Test("the end-of-day digest of an erased day is cleared")
    func digestCleared() async throws {
        let (f, index) = try await consolidatedThenErased()
        defer { f.cleanup() }
        let daily = try f.read("daily/2026-10-19.md")
        let hits = try await index.retrieve("完成活动切分")
        #expect(Consolidator.digestBlock.content(in: daily)?.isEmpty ?? true, "\(daily)")
        #expect(hits.isEmpty, "\(hits.map(\.file))")
    }

    /// 回归：整理改写文件前保存的快照（最多 100 份，位于 App 支持目录 snapshots/）含有改写前的 daily 全文，
    /// 包括已删除的时间线条目。现在删除时去掉这一天 daily 的快照；其他文件的快照不受影响。
    @Test("pre-change snapshots do not keep erased content")
    func snapshotsCleared() async throws {
        let (f, _) = try await consolidatedThenErased()
        defer { f.cleanup() }
        let leftovers = try f.snapshots.snapshots().filter {
            try String(contentsOf: $0, encoding: .utf8).contains("编辑采集代码")
        }
        #expect(leftovers.isEmpty, "\(leftovers.map(\.lastPathComponent))")
    }

    /// docs/memory.md §7 的设计：删除时间段时，分区文件中引用该时间段来源的条目标记为"来源已删除"，
    /// 由下一次整理决定去留。当前未实现：唯一来源已被删除的条目原样保留，看不出来源已不存在。
    @Test("long-term entries whose only source day was erased are flagged (docs/memory.md §7)")
    func longTermEntriesFlagged() async throws {
        let (f, _) = try await consolidatedThenErased()
        defer { f.cleanup() }
        // 标记的具体形式尚未设计；这里只要求"删除或带有来源已删除的标记"之一成立。
        let work = try f.read("work.md")
        withKnownIssue("source-deleted marking from docs/memory.md §7 is not implemented") {
            #expect(!work.contains("修改了 ScreenFrameSource.swift") || work.contains("来源已删除"), "\(work)")
        }
    }

    @Test("only the erased day's daily snapshots are removed")
    func snapshotScope() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(root: dir)
        for path in ["daily/2026-10-19.md", "daily/2026-10-20.md", "work.md", "daily/2026-10-19.md"] {
            try store.record(relativePath: path, previous: "old \(path)", task: "t", itemCount: 0)
        }
        #expect(store.removeSnapshots(of: "daily/2026-10-19.md") >= 1) // 同一毫秒内的两份同名快照会合并为一份
        #expect(store.snapshots().map { $0.lastPathComponent.components(separatedBy: "__").dropFirst().joined(separator: "/") }.sorted()
            == ["daily/2026-10-20.md", "work.md"])
    }

    /// 用户手写笔记与摘要在同一个文件里：去掉摘要不能碰笔记。
    @Test("removing the digest keeps the user's own notes")
    func notesSurvive() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try await f.seedDay(notes: "今天很累")
        _ = try await f.consolidator.consolidateDay(f.day)
        try await f.consolidator.forgetDay(f.day)
        let daily = try f.read("daily/2026-10-19.md")
        #expect(Consolidator.digestBlock.content(in: daily) == nil)
        #expect(!daily.contains("## 摘要"))
        #expect(daily.contains("## 我的笔记\n今天很累"))
    }

    /// 整理一天要多次调用模型（云端或本地，几十秒到几分钟）。期间用户删除了这一天的数据：
    /// 整理不能在删除之后再写入摘要或长期记忆条目。
    @Test("a consolidation in progress writes nothing after its day is erased")
    func eraseDuringConsolidation() async throws {
        let root = try tempDir(), support = try tempDir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: support) }
        let store = try MemoryStore(root: root, timeZone: utc)
        let source = FakeSource()
        let day = Date(timeIntervalSince1970: 1_792_368_000)
        let segs = [segment(0, 3600, "编辑采集代码", summary: "在 Xcode 中修改 ScreenFrameSource.swift", observations: [source.addFact(app: "Xcode", at: 60)])]
        source.set(segs, on: day)
        try await store.writeDailyTimeline(day: day, segments: segs)

        let model = GatedMemoryModel()
        model.inner.operations[.work] = Responses.ops([["op": "add", "project": "new:Amai", "text": "修改了 ScreenFrameSource.swift", "evidence": ["I1"]]])
        let snapshots = SnapshotStore(root: support.appendingPathComponent("snapshots"))
        let consolidator = Consolidator(
            store: store, source: source, model: model, snapshots: snapshots,
            stateURL: support.appendingPathComponent("consolidation.json"),
            clock: FixedClock(day.addingTimeInterval(86_400 + 5 * 3600)), timeZone: utc
        )

        let run = Task { try await consolidator.consolidateDay(day) }
        var entered = model.entered.makeAsyncIterator()
        _ = await entered.next() // 正在等日终摘要的模型输出
        source.set([], on: day)
        try await consolidator.forgetDay(day)
        try await store.writeDailyTimeline(day: day, segments: [])
        model.release()
        await #expect(throws: Consolidator.ConsolidationError.dayErased("2026-10-19")) { try await run.value }

        let daily = try String(contentsOf: root.appendingPathComponent("daily/2026-10-19.md"), encoding: .utf8)
        #expect(Consolidator.digestBlock.content(in: daily) == nil, "\(daily)")
        let work = (try? String(contentsOf: root.appendingPathComponent("work.md"), encoding: .utf8)) ?? ""
        #expect(!work.contains("ScreenFrameSource"))
        #expect(snapshots.snapshots().isEmpty)
    }
}

/// 第一次调用挂起，直到测试放行。
final class GatedMemoryModel: MemoryLanguageModel, @unchecked Sendable {
    let identifier = "gated:test"
    let inner = ScriptedModel()
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var open = false
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation

    init() { (entered, enteredContinuation) = AsyncStream.makeStream() }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            open = true
            defer { waiting = nil }
            return waiting
        }
        c?.resume()
    }

    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
        enteredContinuation.yield()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if open { return true }
                waiting = c
                return false
            }
            if now { c.resume() }
        }
        return try await inner.complete(system: system, user: user, maxTokens: maxTokens, schema: schema)
    }
}

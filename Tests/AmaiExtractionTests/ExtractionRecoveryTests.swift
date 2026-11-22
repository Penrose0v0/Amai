import AmaiCore
import Foundation
import Testing
@testable import AmaiExtraction

/// 模型调用在第一次进入时挂起，直到测试放行。用来制造"抽取正在处理一批帧"的时间窗。
final class GatedModel: ModelProvider, @unchecked Sendable {
    let identifier = "gated:vlm"
    let sendsDataOffDevice = false
    let inner = FakeModel()
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation

    init() { (entered, enteredContinuation) = AsyncStream.makeStream() }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiting = [] }
            return waiting
        }
        pending.forEach { $0.resume() }
    }

    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        enteredContinuation.yield()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if open { return true }
                waiting.append(c)
                return false
            }
            if now { c.resume() }
        }
        return try await inner.generate(request)
    }
}

/// 删除与抽取并发、异常退出后的恢复、存储文件损坏。全部使用合成事件与临时目录。
@Suite("Extraction recovery and erase races")
struct ExtractionRecoveryTests {
    private func pipeline(
        reader: FakeReader, model: any ModelProvider, store: ExtractionStore, now: Date
    ) -> ExtractionPipeline {
        var options = ExtractionPipeline.Options()
        options.lookback = 7 * 86_400
        return ExtractionPipeline(
            dependencies: .init(reader: reader, model: model, ocr: FakeOCR(), store: store, clock: TestClock(now), timeZone: utc),
            options: options
        )
    }

    /// 回归：抽取一批帧需要多次模型调用（本地 VLM 上是几十秒到几分钟）。用户在这期间"删除时间段"时，
    /// 这一批结束后曾把观察（含 OCR 文字）与片段写回，被删除的时间段重新出现。
    /// 现在 `ExtractionStore.deleteData` 记下墓碑，`commit` 丢弃落在其中的结果。
    @Test("data erased while a batch is being extracted does not come back")
    func eraseDuringExtraction() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reader = FakeReader(events: frames(0, 390))
        let model = GatedModel()
        model.inner.segmentation = [#"[{"start":"\#(hms(0))","end":"\#(hms(400))","title":"查看账户页面","category":"work","confidence":0.9}]"#]
        let store = try ExtractionStore(root: dir, timeZone: utc)
        let p = pipeline(reader: reader, model: model, store: store, now: at(1200))

        let run = Task { await p.runOnce() }
        var entered = model.entered.makeAsyncIterator()
        _ = await entered.next() // 抽取已读到帧，正在等模型

        // 删除 00:00–00:10（与 AppModel.eraseData 相同的两步：原始数据、抽取结果）。
        let range = TimeRange(start: at(0), end: at(600))
        reader.events.removeAll { range.contains($0.wallTime) }
        try await store.deleteData(overlapping: range)

        model.release()
        _ = await run.value

        let segments = await store.segments(on: at(0)).filter { $0.timeRange.start < range.end && $0.timeRange.end > range.start }
        let observations = await store.observations(on: at(0)).filter { range.contains($0.timeRange.start) }
        #expect(segments.isEmpty, "\(segments.map(\.title))")
        #expect(observations.isEmpty, "\(observations.count) observations resurrected")
    }

    /// 墓碑只挡住删除之前已经发生的时间：时间段延伸到将来时，删除之后才采集到的数据照常写入；
    /// 与已删除时间段不重叠的结果也照常写入。
    @Test("an erase tombstone only drops results inside the erased past")
    func tombstoneScope() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(at(1000))
        let store = try ExtractionStore(root: dir, timeZone: utc, clock: clock)
        // 用户在 00:16:40 删除 00:10 起到"将来"（00:30）的数据。
        try await store.deleteData(overlapping: TimeRange(start: at(600), end: at(1800)))
        func segment(_ start: TimeInterval, _ end: TimeInterval, _ title: String) -> ActivitySegment {
            ActivitySegment(timeRange: TimeRange(start: at(start), end: at(end)), title: title, summary: "", category: .work,
                            apps: [], observations: [], confidence: 0.9, provider: "test", updatedAt: at(end))
        }
        let written = try await store.commit(
            .init(segments: [segment(0, 300, "删除之前"), segment(700, 900, "已删除的时段"), segment(1100, 1400, "删除之后采集")]),
            state: .init(processedUntil: at(1400))
        )
        #expect(written == 2)
        #expect(await store.segments(on: at(0)).map(\.title) == ["删除之前", "删除之后采集"])
    }

    /// 回归：一批的观察与片段曾先于水位线写入，二者之间退出（崩溃、强制退出、断电）或水位线写入失败（磁盘满）后，
    /// 同一批会再处理一遍，出现两份片段与观察。现在结果与水位线经预写日志一起提交（`ExtractionStore.commit`）。
    ///
    /// 这里让水位线写入真实地失败（state.json 的位置被一个目录占住，原子写无法替换它）：观察与片段已经写下、
    /// 水位线没有，等价于在两者之间退出。随后"重启"（新的流水线实例）并再跑一轮。
    @Test("a failure between writing results and saving the watermark does not duplicate them after restart")
    func crashBeforeWatermark() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reader = FakeReader(events: frames(0, 390))
        let model = FakeModel()
        let output = #"[{"start":"\#(hms(0))","end":"\#(hms(400))","title":"编辑采集代码","category":"work","confidence":0.9}]"#
        model.segmentation = [output, output, output]
        let store = try ExtractionStore(root: dir, timeZone: utc)
        let statePath = dir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: statePath, withIntermediateDirectories: true)

        #expect(await pipeline(reader: reader, model: model, store: store, now: at(1200)).runOnce() == 0)
        #expect(await store.segments(on: at(0)).map(\.title) == ["编辑采集代码"], "results were written before the failure")
        let observationCount = await store.observations(on: at(0)).count
        #expect(observationCount > 0)

        try FileManager.default.removeItem(at: statePath) // 磁盘恢复；进程重启
        let restarted = try ExtractionStore(root: dir, timeZone: utc)
        _ = await pipeline(reader: reader, model: model, store: restarted, now: at(1300)).runOnce()

        #expect(await restarted.segments(on: at(0)).map(\.title) == ["编辑采集代码"])
        #expect(await restarted.observations(on: at(0)).count == observationCount)
        #expect(await restarted.loadState().processedUntil == at(390))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pending-commit.json").path))
    }

    /// 回归：观察以追加方式写入 observations.jsonl。进程在写一行的中途退出会留下没有换行的半行；
    /// 下一次追加曾直接接在半行后面，新的第一条观察与半行粘在一起、无法解析而被丢弃。
    /// 现在追加前先补换行（`AppendOnlyFile`），损坏只限于那半行。
    @Test("an append after a torn last line keeps the new observation")
    func tornObservationLine() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ExtractionStore(root: dir, timeZone: utc)
        let first = Observation(
            timeRange: TimeRange(start: at(0), end: at(10)), modality: .screen, kind: .fact,
            content: "first", confidence: 1, evidence: [], attributes: [:], provider: "test"
        )
        try await store.append([first])
        let file = dir.appendingPathComponent("2026-10-19/observations.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"torn-by-crash","timeRa"#.utf8)) // 没有换行
        try handle.close()

        let second = Observation(
            timeRange: TimeRange(start: at(20), end: at(30)), modality: .screen, kind: .fact,
            content: "second", confidence: 1, evidence: [], attributes: [:], provider: "test"
        )
        try await store.append([second])
        let contents = await store.observations(on: at(0)).map(\.content)
        #expect(contents == ["first", "second"], "\(contents)")
    }

    /// 回归：segments.json 读不出来（损坏、或将来版本的格式）时曾被当作空列表，下一次写片段就用新列表覆盖，
    /// 这一天已有的全部片段被静默丢弃。现在先把它原样移到 `segments.corrupt-<时间>.json`，再写新片段。
    @Test("an unreadable segments file is moved aside, not silently overwritten")
    func unreadableSegmentsFile() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ExtractionStore(root: dir, timeZone: utc)
        let dayDir = dir.appendingPathComponent("2026-10-19", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let damaged = Data(#"[{"id":"7A0B…","title":"上午的全部工作","#.utf8)
        try damaged.write(to: dayDir.appendingPathComponent("segments.json"))

        let segment = ActivitySegment(
            timeRange: TimeRange(start: at(3600), end: at(4000)), title: "新片段", summary: "", category: .work,
            apps: [], observations: [], confidence: 0.9, provider: "test", updatedAt: at(4000)
        )
        try await store.upsert(segment)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dayDir.path)
            .filter { $0.hasPrefix("segments.corrupt-") && $0.hasSuffix(".json") }
        try #require(aside.count == 1, "\(aside)")
        #expect(try Data(contentsOf: dayDir.appendingPathComponent(aside[0])) == damaged)
        #expect(await store.segments(on: at(0)).map(\.title) == ["新片段"])
    }
}

/// 长时间运行的存储增长。`extracted/`（观察含 OCR 文字、片段）目前没有保留期或容量上限（产品待定），
/// 与 raw/ 的 72 小时 TTL + 2 GB 不同；这里用合成数据测量最坏情况（每帧 OCR 都到存储上限、且各不相同）下每小时写入多少。
@Suite("Extraction storage growth")
struct ExtractionStorageGrowthTests {
    @Test("worst-case extracted/ growth per active hour is measured and bounded")
    func growthPerHour() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hours = 2.0
        let reader = FakeReader(events: frames(0, hours * 3600 - 10))
        let ocr = FakeOCR()
        // 4000 字（ocrStoreChars 上限）的中文屏幕文字，UTF-8 下约 12 KB。
        ocr.text = (0..<80).map { "第\($0)行：在编辑器中修改离线同步队列的冲突合并逻辑并补充测试用例" }.joined(separator: "\n")
        let model = FakeModel()
        model.describe = String(repeating: "在 Xcode 中编辑 ScreenFrameSource.swift，调整采集间隔与去重。", count: 4)
        model.segmentation = (0..<64).map { _ in
            #"[{"start":"\#(hms(0))","end":"\#(hms(hours * 3600))","title":"编辑采集代码","summary":"在 Xcode 中修改采集与去重逻辑","category":"work","confidence":0.9}]"#
        }
        let store = try ExtractionStore(root: dir, timeZone: utc)
        var options = ExtractionPipeline.Options()
        options.lookback = 7 * 86_400
        let pipeline = ExtractionPipeline(
            dependencies: .init(reader: reader, model: model, ocr: ocr, store: store, clock: TestClock(at(hours * 3600 + 1200)), timeZone: utc),
            options: options
        )
        var batches = 0
        for _ in 0..<64 {
            let n = await pipeline.runOnce()
            if n == 0 { break }
            batches += n
        }
        let bytes = Self.size(of: dir)
        let perHour = Double(bytes) / hours
        let observations = await store.observations(on: at(0))
        print("extracted/ growth: \(batches) batches, \(observations.count) observations, \(bytes) bytes → \(Int(perHour / 1024)) KB per active hour")
        #expect(batches > 0)
        #expect(observations.allSatisfy { $0.content.count <= options.ocrStoreChars })
        // 没有文档化的预算；以"16 小时活跃 × 365 天 < 10 GB"为界（约 1.7 MB / 小时），超过就需要保留策略。
        #expect(perHour < 1.7 * 1024 * 1024, "\(Int(perHour / 1024)) KB per hour")
    }

    static func size(of root: URL) -> Int64 {
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = e?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

import AmaiCore
import Foundation
import Testing
@testable import AmaiExtraction

@Suite("ModelProvider contracts")
struct ModelProviderTests {
    @Test("ModelRequest defaults")
    func requestDefaults() {
        let request = ModelRequest(cacheable: "system", dynamic: "now")
        #expect(request.images.isEmpty)
        #expect(request.maxTokens == 1024)
    }

    @Test("default local model tag is a Gemma 4 MLX build")
    func defaultModelTag() {
        #expect(LocalInferenceBackend.defaultModelTag.hasPrefix("mlx-community/gemma-4"))
    }

    @Test("model output cleaning strips thinking blocks")
    func clean() {
        #expect(MLXModelProvider.clean("<think>hmm</think>\n 在编辑文件 ") == "在编辑文件")
    }

    @Test("isInstalled is false for an unknown model")
    func notInstalled() throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!LocalInferenceBackend.isInstalled(tag: "nobody/nothing", hubCache: dir))
    }
}

@Suite("Batcher")
struct BatcherTests {
    @Test("splits on gaps longer than maxGap")
    func gapSplit() {
        let events = frames(0, 300) + frames(600, 900)
        let batches = Batcher.readyBatches(events: events, now: at(2000))
        #expect(batches.count == 2)
        #expect(batches[0].range.start == at(0))
        #expect(batches[0].lastEventTime == at(300))
        #expect(batches[0].range.end == at(310))
        #expect(batches[1].range.start == at(600))
    }

    @Test("splits at the target duration")
    func targetSplit() {
        let events = frames(0, 1790)
        let batches = Batcher.readyBatches(events: events, now: at(2000))
        #expect(batches.count == 2)
        #expect(batches[0].lastEventTime == at(890))
        #expect(batches[1].range.start == at(900))
    }

    @Test("still-growing window is not ready")
    func openWindow() {
        let events = frames(0, 300)
        #expect(Batcher.readyBatches(events: events, now: at(360)).isEmpty)
        #expect(Batcher.readyBatches(events: events, now: at(500)).count == 1)
    }

    @Test("batch carries skipped and focus events in range")
    func carriesContext() {
        var events = frames(0, 100)
        events.append(skipped(50))
        events.append(PerceptionEvent(
            wallTime: at(55), monoTime: 1, source: .interaction, kind: .focusChange, payloadRef: nil,
            metadata: PerceptionMetadata(app: "Safari", bundleId: "com.apple.Safari")
        ))
        let batch = try! #require(Batcher.readyBatches(events: events, now: at(1000)).first)
        #expect(batch.skipped.count == 1)
        #expect(batch.focusChanges.count == 1)
        #expect(batch.frames.count == 11)
    }
}

@Suite("IdleClassifier")
struct IdleClassifierTests {
    private func batch(_ events: [PerceptionEvent]) -> ExtractionBatch {
        Batcher.readyBatches(events: events, now: at(10_000)).first!
    }

    @Test("no input and static screen → idle")
    func away() {
        let first = frame(0, idle: 120)
        let rest = (1...20).map { frame(Double($0) * 10, idle: 120, duplicateOf: first.id) }
        #expect(IdleClassifier.isIdle(batch([first] + rest)))
    }

    @Test("no input but changing screen (watching video) → not idle")
    func watching() {
        let events = (0...20).map { frame(Double($0) * 10, idle: 300) }
        #expect(!IdleClassifier.isIdle(batch(events)))
    }

    @Test("active input → not idle")
    func active() {
        let first = frame(0, idle: 1)
        let rest = (1...20).map { frame(Double($0) * 10, idle: 1, duplicateOf: first.id) }
        #expect(!IdleClassifier.isIdle(batch([first] + rest)))
    }
}

@Suite("FrameSelector")
struct FrameSelectorTests {
    @Test("drops duplicates without input but keeps duplicates with input")
    func inputMatters() {
        let a = frame(0, idle: 1)
        let quietDup = frame(10, idle: 200, duplicateOf: a.id)
        let typingDup = frame(20, idle: 2, duplicateOf: a.id)
        let quietDup2 = frame(30, idle: 200, duplicateOf: a.id)
        let last = frame(40, idle: 200, duplicateOf: a.id)
        let selected = FrameSelector.select([a, quietDup, typingDup, quietDup2, last])
        let ids = selected.map(\.id)
        #expect(ids.contains(a.id))
        #expect(ids.contains(typingDup.id))
        #expect(!ids.contains(quietDup.id))
        #expect(!ids.contains(quietDup2.id))
        #expect(ids.contains(last.id))
    }

    @Test("app switches are always kept when capping")
    func appSwitchPriority() {
        var events = frames(0, 400)
        events[20] = frame(200, app: "Safari", bundle: "com.apple.Safari")
        var options = FrameSelector.Options()
        options.maxFrames = 5
        let selected = FrameSelector.select(events, options: options)
        #expect(selected.count <= 5)
        #expect(selected.contains { $0.id == events[20].id })
        #expect(selected.contains { $0.id == events[21].id })
        #expect(selected.first?.id == events.first?.id)
        #expect(selected.last?.id == events.last?.id)
    }

    @Test("caps to maxFrames with uniform spacing")
    func cap() {
        let events = frames(0, 890)
        let selected = FrameSelector.select(events)
        #expect(selected.count == 15)
        #expect(zip(selected, selected.dropFirst()).allSatisfy { $0.wallTime < $1.wallTime })
    }
}

@Suite("SegmentParser")
struct SegmentParserTests {
    let window = TimeRange(start: at(0), end: at(900))

    @Test("parses fenced JSON with multiple segments")
    func multiple() throws {
        let text = """
        好的：
        ```json
        [{"start":"\(hms(0))","end":"\(hms(400))","title":"编辑代码","summary":"在 Xcode 中编辑","category":"work","confidence":0.9,"continues_previous":true},
         {"start":"\(hms(400))","end":"\(hms(900))","title":"查资料","summary":"在 Safari 中查文档","category":"research","confidence":0.7}]
        ```
        """
        let segs = try SegmentParser.parse(text, window: window, timeZone: utc)
        #expect(segs.count == 2)
        #expect(segs[0].continuesPrevious)
        #expect(segs[0].category == .work)
        #expect(segs[1].range.start == at(400))
        #expect(segs[1].category == .research)
        #expect(!segs[1].continuesPrevious)
    }

    @Test("clamps to the window, fixes overlaps, accepts HH:MM")
    func clampAndOverlap() throws {
        let text = """
        [{"start":"02:50","end":"\(hms(500))","title":"A","category":"WORK"},
         {"start":"\(hms(450))","end":"04:30:00","title":"B","category":"weird"}]
        """
        let segs = try SegmentParser.parse(text, window: window, timeZone: utc)
        #expect(segs.count == 2)
        #expect(segs[0].range.start == at(0))
        #expect(segs[0].category == .work)
        #expect(segs[1].range.start == at(500))
        #expect(segs[1].range.end == at(900))
        #expect(segs[1].category == .other)
    }

    @Test("handles a window crossing midnight")
    func midnight() throws {
        let start = Date(timeIntervalSince1970: 1_792_454_100) // 2026-10-20T23:55:00Z
        let w = TimeRange(start: start, end: start.addingTimeInterval(900))
        let segs = try SegmentParser.parse(#"[{"start":"23:58:00","end":"00:08:00","title":"跨午夜"}]"#, window: w, timeZone: utc)
        #expect(segs.first?.range.start == start.addingTimeInterval(180))
        #expect(segs.first?.range.end == start.addingTimeInterval(780))
    }

    @Test("short segments are merged into neighbours")
    func mergeShort() throws {
        let text = """
        [{"start":"\(hms(0))","end":"\(hms(20))","title":"切换","category":"other","confidence":0.5,"continues_previous":true},
         {"start":"\(hms(20))","end":"\(hms(400))","title":"写代码","category":"work","confidence":0.9},
         {"start":"\(hms(400))","end":"\(hms(460))","title":"看消息","category":"communication","confidence":0.8},
         {"start":"\(hms(460))","end":"\(hms(900))","title":"读论文","category":"research","confidence":0.9}]
        """
        let parsed = try SegmentParser.parse(text, window: window, timeZone: utc)
        let merged = SegmentParser.mergeShort(parsed, minDuration: 180)
        #expect(merged.map(\.title) == ["写代码", "读论文"])
        #expect(merged[0].range.start == at(0))
        #expect(merged[0].continuesPrevious)
        #expect(merged[0].range.end == at(460))
        #expect(merged[1].range.start == at(460))
        #expect(merged.allSatisfy { $0.range.duration >= 180 })
    }

    @Test("a single short segment is kept")
    func singleShort() throws {
        let parsed = try SegmentParser.parse(#"[{"start":"\#(hms(0))","end":"\#(hms(60))","title":"短"}]"#, window: window, timeZone: utc)
        #expect(SegmentParser.mergeShort(parsed, minDuration: 180).count == 1)
    }

    @Test("garbage and empty outputs throw")
    func invalid() {
        #expect(throws: SegmentParserError.noJSONArray) { try SegmentParser.parse("抱歉", window: window, timeZone: utc) }
        #expect(throws: SegmentParserError.noValidSegments) { try SegmentParser.parse("[]", window: window, timeZone: utc) }
        #expect(throws: SegmentParserError.noValidSegments) {
            try SegmentParser.parse(#"[{"start":"\#(hms(100))","end":"\#(hms(50))","title":"倒序"}]"#, window: window, timeZone: utc)
        }
    }
}

@Suite("ExtractionStore")
struct ExtractionStoreTests {
    private func segment(_ start: TimeInterval, _ end: TimeInterval, title: String, observations: [UUID] = [], id: UUID = UUID()) -> ActivitySegment {
        ActivitySegment(
            id: id, timeRange: TimeRange(start: at(start), end: at(end)), title: title, summary: "",
            category: .work, apps: [], observations: observations, confidence: 0.8, provider: "test"
        )
    }

    @Test("upsert replaces by id and keeps order")
    func upsert() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ExtractionStore(root: dir, timeZone: utc)
        let id = UUID()
        try await store.upsert(segment(600, 700, title: "B"))
        try await store.upsert(segment(0, 100, title: "A", id: id))
        try await store.upsert(segment(0, 300, title: "A2", id: id))
        let list = await store.segments(on: at(0))
        #expect(list.map(\.title) == ["A2", "B"])
        #expect(await store.latestSegment(endingAtOrBefore: at(500))?.title == "A2")
    }

    @Test("delete removes the segment and its observations; search finds OCR text")
    func deleteAndSearch() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ExtractionStore(root: dir, timeZone: utc)
        let obs = Observation(
            timeRange: TimeRange(start: at(10), end: at(20)), modality: .screen, kind: .fact,
            content: "Quarterly report draft", confidence: 0.9, evidence: [], provider: "vision-ocr"
        )
        let other = Observation(
            timeRange: TimeRange(start: at(500), end: at(510)), modality: .screen, kind: .fact,
            content: "unrelated", confidence: 0.9, evidence: [], provider: "vision-ocr"
        )
        try await store.append([obs, other])
        let seg = segment(0, 100, title: "写文档", observations: [obs.id])
        try await store.upsert(seg)

        #expect(await store.search("quarterly", endingOn: at(0)).map(\.id) == [seg.id])
        #expect(await store.search("写文档", endingOn: at(0)).count == 1)

        try await store.deleteSegment(id: seg.id, on: at(0))
        #expect(await store.segments(on: at(0)).isEmpty)
        #expect(await store.observations(on: at(0)).map(\.id) == [other.id])
    }

    @Test("state round-trips")
    func state() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ExtractionStore(root: dir, timeZone: utc)
        #expect(await store.loadState().processedUntil == nil)
        try await store.saveState(.init(processedUntil: at(42)))
        #expect(await store.loadState().processedUntil == at(42))
    }
}

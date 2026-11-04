import AmaiCore
import Foundation
import Testing
@testable import AmaiExtraction

@Suite("ExtractionPipeline end-to-end (fakes)")
struct PipelineTests {
    struct Harness {
        let dir: URL
        let reader: FakeReader
        let model = FakeModel()
        let ocr = FakeOCR()
        let store: ExtractionStore
        let clock: TestClock
        let pipeline: ExtractionPipeline

        init(events: [PerceptionEvent], now: Date) throws {
            dir = try TempDir.make()
            reader = FakeReader(events: events)
            store = try ExtractionStore(root: dir, timeZone: utc)
            clock = TestClock(now)
            var options = ExtractionPipeline.Options()
            options.lookback = 7 * 86_400
            pipeline = ExtractionPipeline(
                dependencies: .init(reader: reader, model: model, ocr: ocr, store: store, clock: clock, timeZone: utc),
                options: options
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test("one window → multiple segments with observations and evidence")
    func multipleSegments() async throws {
        let events = frames(0, 390) + frames(400, 890, app: "Safari", bundle: "com.apple.Safari", firstIndex: 40)
        let h = try Harness(events: events, now: at(1200))
        defer { h.cleanup() }
        h.model.segmentation = ["""
        [{"start":"\(hms(0))","end":"\(hms(400))","title":"编辑采集代码","summary":"在 Xcode 中编辑","category":"work","confidence":0.9},
         {"start":"\(hms(400))","end":"\(hms(900))","title":"查阅文档","summary":"在 Safari 中阅读","category":"research","confidence":0.8}]
        """]

        #expect(await h.pipeline.runOnce() == 1)

        let segments = await h.store.segments(on: at(0))
        #expect(segments.map(\.title) == ["编辑采集代码", "查阅文档"])
        #expect(segments[0].apps == ["com.apple.dt.Xcode"])
        #expect(segments[1].apps == ["com.apple.Safari"])
        #expect(!segments[0].evidence.isEmpty && !segments[1].evidence.isEmpty)
        #expect(segments.allSatisfy { $0.provider == "fake:vlm" })

        // 每个选中帧产生一条事实（OCR）与一条推断（VLM 描述）。
        let observations = await h.store.observations(on: at(0))
        let facts = observations.filter { $0.kind == .fact }
        let inferences = observations.filter { $0.kind == .inference }
        #expect(facts.count == 15 && inferences.count == 15)
        #expect(facts.allSatisfy { $0.provider == "vision-ocr" && $0.evidence.first?.frameIndex != nil })
        #expect(Set(segments.flatMap(\.observations)) == Set(observations.map(\.id)))

        #expect(await h.store.loadState().processedUntil == at(890))
        #expect(h.model.lastSegmentPrompt.contains("[Safari]"))
        #expect(await h.pipeline.status.segmentsWritten == 2)
    }

    @Test("a later window can continue the previous segment")
    func continuation() async throws {
        let events = frames(0, 890) + frames(900, 1790, firstIndex: 90)
        let h = try Harness(events: events, now: at(2500))
        defer { h.cleanup() }
        h.model.segmentation = [
            #"[{"start":"\#(hms(0))","end":"\#(hms(900))","title":"编写代码","summary":"第一段","category":"work","confidence":0.8}]"#,
            #"[{"start":"\#(hms(900))","end":"\#(hms(1800))","title":"编写并测试代码","summary":"合并后","category":"work","confidence":0.9,"continues_previous":true}]"#,
        ]

        #expect(await h.pipeline.runOnce() == 2)

        let segments = await h.store.segments(on: at(0))
        #expect(segments.count == 1)
        let seg = try #require(segments.first)
        #expect(seg.title == "编写并测试代码")
        #expect(seg.timeRange.start == at(0))
        #expect(seg.timeRange.end == at(1800))
        #expect(seg.observations.count == 60)
        #expect(h.model.lastSegmentPrompt.contains("「编写代码」"))
    }

    @Test("frames still being written postpone the window")
    func pending() async throws {
        let h = try Harness(events: frames(0, 300), now: at(1000))
        defer { h.cleanup() }
        h.reader.availability = .pending

        #expect(await h.pipeline.runOnce() == 0)
        #expect(await h.pipeline.status.state == .waitingForFrames)
        #expect(await h.store.loadState().processedUntil == nil)
        #expect(h.model.segmentCalls == 0)
    }

    @Test("expired frames still yield metadata observations without VLM calls")
    func expired() async throws {
        let h = try Harness(events: frames(0, 300), now: at(1000))
        defer { h.cleanup() }
        h.reader.availability = .expired
        h.model.segmentation = [#"[{"start":"\#(hms(0))","end":"\#(hms(310))","title":"使用 Xcode","category":"work","confidence":0.4}]"#]

        #expect(await h.pipeline.runOnce() == 1)
        #expect(h.model.describeCalls == 0)
        let obs = await h.store.observations(on: at(0))
        #expect(obs.allSatisfy { $0.kind == .fact && $0.attributes["frameAvailable"] == "false" })
        #expect(h.model.lastSegmentPrompt.contains("截图已清理"))
    }

    @Test("repeated model failures fall back to low-confidence app segments")
    func fallback() async throws {
        let events = frames(0, 300) + frames(310, 600, app: "Safari", bundle: "com.apple.Safari")
        let h = try Harness(events: events, now: at(1000))
        defer { h.cleanup() }
        h.model.error = ModelProviderError.generationFailed("boom")

        #expect(await h.pipeline.runOnce() == 0)
        #expect(await h.pipeline.status.state == .retrying)
        #expect(await h.pipeline.runOnce() == 0)
        #expect(await h.pipeline.runOnce() == 1)

        let segments = await h.store.segments(on: at(0))
        #expect(segments.map(\.title) == ["使用 Xcode", "使用 Safari"])
        #expect(segments.allSatisfy { $0.provider == "fallback:metadata" && $0.confidence < 0.5 })
        #expect(await h.pipeline.status.fallbackBatches == 1)
        #expect(await h.store.loadState().processedUntil == at(600))
    }

    @Test("unparsable segmentation output is retried, then counts as a failure")
    func unparsable() async throws {
        let h = try Harness(events: frames(0, 300), now: at(1000))
        defer { h.cleanup() }
        h.model.segmentation = ["我无法完成", "还是不行"]
        #expect(await h.pipeline.runOnce() == 0)
        #expect(h.model.segmentCalls == 2)
        #expect(await h.pipeline.status.state == .retrying)
        // 帧描述已缓存，重试不再重复推理。
        let describedBefore = h.model.describeCalls
        h.model.segmentation = [#"[{"start":"\#(hms(0))","end":"\#(hms(310))","title":"编辑","category":"work"}]"#]
        #expect(await h.pipeline.runOnce() == 1)
        #expect(h.model.describeCalls == describedBefore)
    }

    @Test("missing model waits instead of falling back")
    func modelMissing() async throws {
        let h = try Harness(events: frames(0, 300), now: at(1000))
        defer { h.cleanup() }
        h.model.error = ModelProviderError.modelNotInstalled("x/y")
        for _ in 0..<5 { _ = await h.pipeline.runOnce() }
        #expect(await h.pipeline.status.state == .modelUnavailable)
        #expect(await h.store.segments(on: at(0)).isEmpty)
        #expect(await h.store.loadState().processedUntil == nil)
    }

    @Test("idle and privacy windows use rules without model calls, and merge")
    func rules() async throws {
        // 0–300 秒：无输入且画面不变；500–700 秒：密码输入被跳过。中间 200 秒空白把它们切成两个窗口。
        let first = frame(0, idle: 200)
        let events = [first] + (1...30).map { frame(Double($0) * 10, idle: 200, duplicateOf: first.id) }
            + (50...70).map { skipped(Double($0) * 10) }
        let h = try Harness(events: events, now: at(2000))
        defer { h.cleanup() }

        #expect(await h.pipeline.runOnce() == 2)
        #expect(h.model.describeCalls == 0 && h.model.segmentCalls == 0)
        let segments = await h.store.segments(on: at(0))
        #expect(segments.map(\.title) == ["离开电脑", "隐私跳过：密码输入"])
        #expect(segments[0].category == .idle)
        #expect(segments[1].provider == "rule:privacy")
    }

    @Test("two displays yield one unified record with display labels and a bounded frame budget")
    func crossDisplay() async throws {
        let events = dualDisplayFrames(count: 90, focus: { _ in 1 }, idle: { _ in 2 })
        let h = try Harness(events: events, now: at(2000))
        defer { h.cleanup() }
        h.model.segmentation = ["""
        [{"start":"\(hms(0))","end":"\(hms(900))","title":"编辑采集代码","summary":"在 Xcode 中编辑，副屏开着视频","category":"work","confidence":0.8}]
        """]

        #expect(await h.pipeline.runOnce() == 1)
        #expect(h.model.segmentCalls == 1)
        #expect(h.model.describeCalls <= 15)

        let segments = await h.store.segments(on: at(0))
        #expect(segments.count == 1)
        #expect(segments[0].apps == ["com.apple.dt.Xcode"])

        let prompt = h.model.lastSegmentPrompt
        #expect(prompt.contains("[屏幕1·焦点] [Xcode]"))
        #expect(prompt.contains("[屏幕2·副屏]"))
        #expect(!prompt.contains("[屏幕2·副屏] [Xcode]"), "secondary frames must not claim the frontmost app")
        #expect(prompt.contains("[屏幕概况] 屏幕1：焦点约 100% 的时间，画面变化 0/89 次截图；屏幕2：焦点约 0% 的时间，画面变化 89/89 次截图"))
        #expect(h.model.describePrompts.contains { $0.contains("副屏") && !$0.contains("前台应用：") })

        let facts = await h.store.observations(on: at(0)).filter { $0.kind == .fact }
        #expect(Set(facts.compactMap { $0.attributes["displayId"] }) == ["1", "5"])
        #expect(facts.filter { $0.attributes["focusDisplay"] == "true" }.count
            > facts.filter { $0.attributes["focusDisplay"] == "false" }.count)
    }

    @Test("no input with a video on the secondary display is recorded as away, with the change noted")
    func awayWithSecondaryVideo() async throws {
        let events = dualDisplayFrames(count: 60, focus: { _ in 1 }, idle: { _ in 300 })
        let h = try Harness(events: events, now: at(2000))
        defer { h.cleanup() }

        #expect(await h.pipeline.runOnce() == 1)
        #expect(h.model.describeCalls == 0 && h.model.segmentCalls == 0)
        let segments = await h.store.segments(on: at(0))
        #expect(segments.map(\.title) == ["离开电脑"])
        #expect(segments[0].summary.contains("其他屏幕的画面仍在变化"))
    }

    @Test("credentials seen by OCR are redacted before storage")
    func redaction() async throws {
        let h = try Harness(events: frames(0, 100), now: at(1000))
        defer { h.cleanup() }
        h.ocr.text = "export OPENAI_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123\nREADME.md"
        h.model.segmentation = [#"[{"start":"\#(hms(0))","end":"\#(hms(110))","title":"编辑","category":"work"}]"#]
        #expect(await h.pipeline.runOnce() == 1)
        let facts = await h.store.observations(on: at(0)).filter { $0.kind == .fact }
        #expect(!facts.isEmpty)
        #expect(facts.allSatisfy { !$0.content.contains("sk-proj") && $0.content.contains(SecretRedactor.placeholder) })
        #expect(facts.allSatisfy { $0.attributes["redactions"] == "1" })
    }

    @Test("deferred when power policy disallows, unless forced")
    func deferred() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FakeModel()
        model.segmentation = [#"[{"start":"\#(hms(0))","end":"\#(hms(110))","title":"编辑","category":"work"}]"#]
        var options = ExtractionPipeline.Options()
        options.lookback = 7 * 86_400
        let pipeline = ExtractionPipeline(
            dependencies: .init(
                reader: FakeReader(events: frames(0, 100)), model: model, ocr: FakeOCR(),
                store: try ExtractionStore(root: dir, timeZone: utc), clock: TestClock(at(1000)),
                timeZone: utc, shouldRun: { false }
            ),
            options: options
        )
        #expect(await pipeline.runOnce() == 0)
        #expect(await pipeline.status.state == .deferred)
        #expect(await pipeline.runOnce(force: true) == 1)
    }
}

@Suite("Extraction memory language")
struct ExtractionLanguageTests {
    @Test("in English, prompts, timeline labels and rule segments are English")
    func english() async throws {
        let events = dualDisplayFrames(count: 90, focus: { _ in 1 }, idle: { _ in 2 })
        let h = try PipelineTests.Harness(events: events, now: at(2000))
        defer { h.cleanup() }
        await h.pipeline.setLanguage(.en)
        h.model.segmentation = ["""
        [{"start":"\(hms(0))","end":"\(hms(900))","title":"Editing capture code","summary":"Edited code in Xcode","category":"work","confidence":0.8}]
        """]
        #expect(await h.pipeline.runOnce() == 1)
        let prompt = h.model.lastSegmentPrompt
        #expect(prompt.hasPrefix("Previous segment: none\nTimeline range: "))
        #expect(prompt.contains("[Display 1 · focused] [Xcode] screen: "))
        #expect(prompt.contains("[display overview] Display 1: focused about 100% of the time, screen changed in 0/89 screenshots; Display 2:"))
        #expect(h.model.describePrompts.contains { $0.hasPrefix("Time: ") })

        // 规则片段也使用英文。
        let first = frame(1000, idle: 200)
        let idle = [first] + (1...30).map { frame(1000 + Double($0) * 10, idle: 200, duplicateOf: first.id) }
        let h2 = try PipelineTests.Harness(events: idle, now: at(3000))
        defer { h2.cleanup() }
        await h2.pipeline.setLanguage(.en)
        #expect(await h2.pipeline.runOnce() == 1)
        #expect(await h2.store.segments(on: at(0)).map(\.title) == ["Away from computer"])
    }

    @Test("system prompts exist for every language and keep the JSON contract")
    func prompts() {
        for lang in MemoryLanguage.allCases {
            let s = Prompts.segmentationSystem(lang)
            #expect(s.contains(#""continues_previous":false"#))
            #expect(s.contains("work") && s.contains("idle"))
            #expect(!Prompts.frameDescriptionSystem(lang).isEmpty)
        }
        #expect(Prompts.segmentationSystem(.ja).contains("JSON 配列だけを出力"))
    }
}

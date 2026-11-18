import AmaiCore
import AmaiMemory
import Foundation
import os
import Testing
@testable import AmaiAssistant

// MARK: - Fakes

/// 按脚本回复的假模型：每次调用取出下一组事件，并记录收到的请求。
final class ScriptedModel: ChatModel, @unchecked Sendable {
    let identifier = "fake:model"
    let sendsDataOffDevice: Bool
    let supportsImages: Bool
    let supportsTools: Bool
    private let state = OSAllocatedUnfairLock(initialState: (script: [[ChatEvent]](), requests: [ChatRequest](), resets: 0))
    private let preparedState = OSAllocatedUnfairLock(initialState: [ChatRequest]())
    var failNext = false

    init(_ script: [[ChatEvent]], images: Bool = true, tools: Bool = true, offDevice: Bool = false) {
        supportsImages = images
        supportsTools = tools
        sendsDataOffDevice = offDevice
        state.withLock { $0.script = script }
    }

    var requests: [ChatRequest] { state.withLock { $0.requests } }
    var resets: Int { state.withLock { $0.resets } }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let events = state.withLock { s -> [ChatEvent] in
            s.requests.append(request)
            return s.script.isEmpty ? [.text("ok")] : s.script.removeFirst()
        }
        let fail = failNext
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if fail {
                continuation.finish(throwing: ModelFailure())
            } else {
                continuation.yield(.finished(ChatUsage()))
                continuation.finish()
            }
        }
    }

    func resetConversation() async { state.withLock { $0.resets += 1 } }

    /// 收到的预填充请求。
    var prepared: [ChatRequest] { preparedState.withLock { $0 } }
    func prepare(_ request: ChatRequest) async { preparedState.withLock { $0.append(request) } }

    struct ModelFailure: Error {}
}

final class FakeLive: LiveContextReading, @unchecked Sendable {
    var snapshot = FocusSnapshot(appName: "Xcode", bundleId: "com.apple.dt.Xcode", pid: 1, windowTitle: "AgentSession.swift", selectedText: "let x = 1", accessibilityGranted: true)
    var text = "func runTurn\nlet checkpoint\nthrow error"
    var states: [RecentTextState] = []
    var blocked: String?
    private(set) var screenCalls = 0

    func focus() async -> FocusSnapshot { blocked == nil ? snapshot : FocusSnapshot() }

    func screen(_ scope: ScreenScope, maxAge: TimeInterval, maxHeight: Int) async throws -> ScreenImage {
        if let blocked { throw LiveContextError.blocked(reason: blocked) }
        screenCalls += 1
        return ScreenImage(jpeg: Data([0xFF, 0xD8, 0xFF]), perceptualHash: 42, scope: scope, capturedAt: Date(), reusedBackgroundFrame: false)
    }

    private(set) var textCalls = 0

    func screenText(_ scope: ScreenScope, maxAge: TimeInterval) async throws -> String {
        if let blocked { throw LiveContextError.blocked(reason: blocked) }
        textCalls += 1
        return text
    }

    func recentStates() async -> [RecentTextState] { states }
}

/// 合成的记忆目录。
struct MemoryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("amai-assistant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("daily"), withIntermediateDirectories: true)
        try write("work.md", """
        # 工作

        <!-- amai:memory:begin · x -->
        ### Amai
        - 论文投到了 CHI 2027 <!-- src:2026-11-10 -->
        <!-- amai:memory:end -->
        """)
        try write("health.md", """
        # 健康

        <!-- amai:memory:begin · x -->
        ### 基本指标
        - 身高 175 cm <!-- src:2026-10-01 -->
        <!-- amai:memory:end -->
        """)
        try write("daily/2026-11-10.md", """
        # 2026-11-10

        ## 时间线

        <!-- amai:timeline:begin · x -->
        - 10:00–11:30 提交 CHI 论文 <!-- seg:a conf:0.9 -->
          在投稿系统里上传了终稿。
        <!-- amai:timeline:end -->
        """)
    }

    func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func api(_ categories: Set<MemoryCategory>) throws -> MemoryAPI {
        let utc = TimeZone(identifier: "UTC")!
        let index = MemoryIndex(root: root, database: try MemoryIndexDatabase.inMemory(), timeZone: utc)
        return MemoryAPI(root: root, index: index, access: MemoryAccess(categories: categories), timeZone: utc)
    }

    func snapshot() throws -> [String: String] {
        var files: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "md" {
            files[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let utc = TimeZone(identifier: "UTC")!
private let builder = ContextBuilder(language: "Chinese", timeZone: utc)

struct FixedClock: AmaiClock {
    let date: Date
    func now() -> Date { date }
    func monotonicNanoseconds() -> UInt64 { 0 }
}

/// 2026-11-11 12:00 UTC：合成记忆里的 2026-11-10 是"昨天"。
private let clock = FixedClock(date: ISO8601DateFormatter().date(from: "2026-11-11T12:00:00Z")!)

private func run(_ session: AssistantSession, _ text: String, options: AssistantSession.TurnOptions = .init()) async throws -> [AssistantEvent] {
    var events: [AssistantEvent] = []
    for try await event in session.send(text, options: options) { events.append(event) }
    return events
}

// MARK: - Session

@Suite("Assistant session")
struct AssistantSessionTests {
    @Test("memory is retrieved by the backend: no tools in the request, sources recorded, memory never written")
    func memoryAnswer() async throws {
        let fixture = try MemoryFixture()
        defer { fixture.cleanup() }
        let before = try fixture.snapshot()
        // 一个既不会调用工具、也看不了图的模型：记忆问答照样完整。
        let model = ScriptedModel([[.text("投到了 CHI 2027（2026-11-10）。")]], images: false, tools: false)
        let session = AssistantSession(model: model, memory: try fixture.api([.work, .daily]), live: nil, builder: builder, clock: clock)

        let events = try await run(session, "我的论文投到哪里了？")
        #expect(model.requests.count == 1)
        let request = try #require(model.requests.first)
        #expect(request.tools.isEmpty)
        #expect(request.system.contains("Amai searches the user's memory before every answer"))
        let message = try #require(request.messages.last?.text)
        #expect(message.contains("<memory>") && message.contains("[work › Amai, 2026-11-10] 论文投到了 CHI 2027"))
        #expect(message.hasSuffix("User's message:\n我的论文投到哪里了？"))
        guard case .context(let summary) = events.first else { Issue.record("no context event"); return }
        #expect(summary.memorySourceCount >= 1)
        guard case .finished(let text, let sources) = events.last else { Issue.record("no finish event"); return }
        #expect(text == "投到了 CHI 2027（2026-11-10）。")
        #expect(sources.contains(MemorySource(category: .work, file: "work.md", section: "Amai", date: "2026-11-10")))
        #expect(await session.transcript.map(\.role) == [.user, .assistant])
        #expect(try fixture.snapshot() == before)
    }

    @Test("a turn that skips memory sends no memory block and reports no sources")
    func turnWithoutMemory() async throws {
        let fixture = try MemoryFixture()
        defer { fixture.cleanup() }
        let model = ScriptedModel([[.text("Translated.")]], images: false, tools: false)
        let session = AssistantSession(model: model, memory: try fixture.api([.work, .daily]), live: nil, builder: builder, clock: clock)

        let events = try await run(session, "我的论文投到哪里了？", options: .init(includeMemory: false))
        let message = try #require(model.requests.first?.messages.last?.text)
        #expect(!message.contains("<memory>"))
        guard case .finished(_, let sources) = events.last else { Issue.record("no finish event"); return }
        #expect(sources.isEmpty)
    }

    @Test("a question about a day gets that day's timeline; 'that day' in a follow-up stays on it and nothing is repeated")
    func dates() async throws {
        let fixture = try MemoryFixture()
        defer { fixture.cleanup() }
        let model = ScriptedModel([[.text("提交了 CHI 论文。")], [.text("没有记录到决定。")]])
        let session = AssistantSession(model: model, memory: try fixture.api([.work, .daily]), live: nil, builder: builder, clock: clock)

        let events = try await run(session, "我昨天做了什么？")
        let first = try #require(model.requests.first?.messages.last?.text)
        #expect(first.contains("Timeline for 2026-11-10:"))
        #expect(first.contains("- 10:00–11:30 提交 CHI 论文 — 在投稿系统里上传了终稿。"))
        guard case .finished(_, let sources) = events.last else { Issue.record("no finish event"); return }
        #expect(sources.contains(MemorySource(category: .daily, file: "daily/2026-11-10.md", date: "2026-11-10")))

        _ = try await run(session, "那天还做了什么决定？")
        let second = try #require(model.requests.last)
        // 第一轮原样留在历史里（缓存前缀），这一轮不重复给时间线。
        #expect(second.messages.first?.text == first)
        let follow = try #require(second.messages.last?.text)
        #expect(follow.contains("\"That day\" in the question refers to 2026-11-10"))
        #expect(!follow.contains("Timeline for 2026-11-10:") && !follow.contains("提交 CHI 论文"))
    }

    @Test("categories the user did not allow are never retrieved; with none allowed the prompt has no memory part")
    func access() async throws {
        let fixture = try MemoryFixture()
        defer { fixture.cleanup() }
        let model = ScriptedModel([[.text("没有记录。")], [.text("好")]])
        let session = AssistantSession(model: model, memory: try fixture.api([.work]), live: nil, builder: builder, clock: clock)
        let events = try await run(session, "我的身高是多少？昨天做了什么？")
        let message = try #require(model.requests.first?.messages.last?.text)
        #expect(!message.contains("175") && !message.contains("提交 CHI 论文"))
        #expect(message.contains("has not allowed the assistant to read daily timelines"))
        guard case .finished(_, let sources) = events.last else { Issue.record("no finish event"); return }
        #expect(!sources.contains { $0.category == .health || $0.category == .daily })

        let none = AssistantSession(model: model, memory: try fixture.api([]), live: nil, builder: builder, clock: clock)
        _ = try await run(none, "论文投到哪里了？")
        let request = try #require(model.requests.last)
        #expect(!request.system.contains("<memory>") && !(request.messages.last?.text.contains("<memory>") ?? true))
    }

    @Test("the screen context leads the message; unchanged screen text and old recent states are not repeated")
    func contextOrderAndDedup() async throws {
        let live = FakeLive()
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        live.states = [RecentTextState(firstSeen: t0, lastSeen: t0, appName: "Safari", windowTitle: "ADR-0008", text: "只读 MCP Server\n授权分区", source: .ocr)]
        let model = ScriptedModel([[.text("一")], [.text("二")]])
        let session = AssistantSession(model: model, memory: nil, live: live, builder: builder)

        _ = try await run(session, "这段代码做什么？")
        let first = try #require(model.requests.first)
        #expect(!first.system.contains("Xcode") && !first.system.contains("Time:"))
        let message = try #require(first.messages.last?.text)
        #expect(message.hasPrefix("<context>") && message.hasSuffix("这段代码做什么？"))
        #expect(message.contains("Active app: Xcode — window \"AgentSession.swift\""))
        #expect(message.contains("let x = 1") && message.contains("func runTurn") && message.contains("Safari — \"ADR-0008\""))

        _ = try await run(session, "那下一行呢？")
        let second = try #require(model.requests.last)
        // 第一轮的内容原样保留（缓存前缀）。
        #expect(second.messages.first == first.messages.first)
        let follow = try #require(second.messages.last?.text)
        #expect(follow.contains("Screen text: unchanged since the previous message."))
        #expect(!follow.contains("func runTurn") && !follow.contains("ADR-0008"))
    }

    @Test("prepare reads the screen and prefills the context; the submitted message starts with exactly that block")
    func prepareThenSend() async throws {
        let fixture = try MemoryFixture()
        defer { fixture.cleanup() }
        let live = FakeLive()
        let model = ScriptedModel([[.text("好")], [.text("好")]])
        let session = AssistantSession(model: model, memory: try fixture.api([.work]), live: live, builder: builder, clock: clock)

        let summary = try #require(await session.prepare())
        #expect(summary.appName == "Xcode" && summary.includesScreenText)
        // 两次预填充：先是系统提示词与历史（与读屏幕同时开始），再加上读好的屏幕上下文。
        #expect(model.prepared.count == 2 && model.prepared[0].messages.isEmpty)
        let block = try #require(model.prepared.last?.messages.last?.text)
        #expect(block.hasPrefix("<context>") && block.hasSuffix("</context>") && block.contains("func runTurn"))
        #expect(!block.contains("<memory>") && model.requests.isEmpty)

        let events = try await run(session, "论文投到哪里了？")
        let message = try #require(model.requests.first?.messages.last?.text)
        // 提交的消息以预填充过的那一段原样开头，记忆和问题只追加在后面。
        #expect(message.hasPrefix(block + "\n\n<memory>"))
        #expect(model.requests.first?.system == model.prepared.last?.system)
        guard case .context(let used) = events.first else { Issue.record("no context event"); return }
        #expect(used.usedPreparedContext)
        #expect(await session.lastTimings.usedPreparedContext)

        // 准备之后屏幕变了：不用过期的那一份。
        _ = await session.prepare()
        let stale = try #require(model.prepared.last?.messages.last?.text)
        live.text = "完全不同的一屏\n另一个文件"
        let next = try await run(session, "现在呢？")
        let second = try #require(model.requests.last?.messages.last?.text)
        #expect(!second.hasPrefix(stale) && second.contains("完全不同的一屏"))
        guard case .context(let fresh) = next.first else { Issue.record("no context event"); return }
        #expect(!fresh.usedPreparedContext)
    }

    @Test("a blocked screen is reported to the model instead of being read")
    func privacyBlock() async throws {
        let live = FakeLive()
        live.blocked = "excludedApp"
        let model = ScriptedModel([[.text("好")]])
        let session = AssistantSession(model: model, memory: nil, live: live, builder: builder)
        let events = try await run(session, "屏幕上是什么？")
        let message = try #require(model.requests.first?.messages.last?.text)
        #expect(message.contains("not read") && message.contains("excludedApp"))
        #expect(!message.contains("Xcode") && !message.contains("func runTurn"))
        guard case .context(let summary) = events.first else { Issue.record("no context event"); return }
        #expect(summary.blockedReason == "excludedApp" && !summary.includesScreenText)
    }

    @Test("a failed turn is rolled back so history matches what the user sees")
    func rollback() async throws {
        let model = ScriptedModel([[.text("第一轮")], [.text("半句")]])
        let session = AssistantSession(model: model, memory: nil, live: nil, builder: builder)
        _ = try await run(session, "一")
        model.failNext = true
        await #expect(throws: ScriptedModel.ModelFailure.self) { _ = try await run(session, "二") }
        #expect(await session.transcript.map(\.role) == [.user, .assistant])
        model.failNext = false
        _ = try await run(session, "三")
        #expect(await session.transcript.count == 4)
        await #expect(throws: AssistantError.emptyMessage) { _ = try await run(session, "   ") }
    }

    @Test("screenshots: a model that sees images receives the image, a text model gets none, old images are dropped")
    func screenshots() async throws {
        let live = FakeLive()
        let seeing = ScriptedModel([[.text("看到了")], [.text("好")]])
        let session = AssistantSession(model: seeing, memory: nil, live: live, builder: builder)
        _ = try await run(session, "看看屏幕", options: .init(attachScreen: .focusedWindow))
        let attached = try #require(seeing.requests.first?.messages.last)
        #expect(attached.role == .user && attached.images.count == 1 && attached.images[0].perceptualHash == 42)
        // 下一轮：历史里的截图不再发送。
        _ = try await run(session, "继续")
        #expect(seeing.requests[1].messages.allSatisfy { $0.images.isEmpty })

        let blind = ScriptedModel([[.text("明白")]], images: false)
        let textSession = AssistantSession(model: blind, memory: nil, live: live, builder: builder)
        _ = try await run(textSession, "屏幕上是什么？", options: .init(attachScreen: .desktop))
        let message = try #require(blind.requests.first?.messages.last)
        #expect(message.images.isEmpty && !message.text.contains("<screenshot>"))
    }

    @Test("restoring a saved conversation and starting a new one reset the model's cache")
    func restoreAndReset() async throws {
        let model = ScriptedModel([[.text("接着说")]])
        let session = AssistantSession(model: model, memory: nil, live: nil, builder: builder)
        await session.restore([DisplayMessage(role: .user, text: "你好"), DisplayMessage(role: .assistant, text: "你好！")])
        _ = try await run(session, "继续")
        #expect(model.requests.first?.messages.map(\.role) == [.user, .assistant, .user])
        await session.reset()
        #expect(await session.transcript.isEmpty && model.resets == 2)
    }

    @Test("history beyond the limit drops the oldest whole turns")
    func trimming() async throws {
        var configuration = AssistantSession.Configuration()
        configuration.maxHistoryCharacters = 400
        let long = String(repeating: "很长的回答。", count: 40)
        let model = ScriptedModel([[.text(long)], [.text(long)], [.text("短")]])
        let session = AssistantSession(model: model, memory: nil, live: nil, builder: builder, configuration: configuration)
        _ = try await run(session, "一")
        _ = try await run(session, "二")
        _ = try await run(session, "三")
        let last = try #require(model.requests.last)
        #expect(last.messages.first?.role == .user && last.messages.count < 5)
        #expect(last.messages.last?.text.hasSuffix("三") == true)
    }
}

@Suite("Date mentions")
struct DateMentionTests {
    /// 2026-11-11 是星期三。
    private func parse(_ text: String) -> (days: [String], range: String?) {
        let result = DateMentions.parse(text, now: clock.date, timeZone: utc)
        func name(_ date: Date) -> String { MemoryDirectory.dayName(for: date, timeZone: utc) }
        return (result.days.map(name), result.range.map { "\(name($0.lowerBound))...\(name($0.upperBound))" })
    }

    @Test("explicit and relative days in Chinese, English and Japanese")
    func days() {
        #expect(parse("我在 2026-11-06 那天主要做了什么？").days == ["2026-11-06"])
        #expect(parse("11月6日和11月7号做了什么").days == ["2026-11-06", "2026-11-07"])
        #expect(parse("2026年11月6日的会议").days == ["2026-11-06"])
        #expect(parse("昨天和今天分别做了什么").days == ["2026-11-10", "2026-11-11"])
        #expect(parse("大前天做了什么").days == ["2026-11-08"])
        #expect(parse("what did I do yesterday?").days == ["2026-11-10"])
        #expect(parse("昨日は何をした？").days == ["2026-11-10"])
        #expect(parse("周一做了什么").days == ["2026-11-09"])
        #expect(parse("上周五做了什么").days == ["2026-11-06"])
        // 没写年份而日期在将来：指去年。
        #expect(parse("12月25日做了什么").days == ["2025-12-25"])
    }

    @Test("ranges; questions without a date are left alone")
    func ranges() {
        #expect(parse("这周做了哪些事").range == "2026-11-09...2026-11-11")
        #expect(parse("what did I work on last week").range == "2026-11-02...2026-11-08")
        #expect(parse("过去 3 天的进展").range == "2026-11-09...2026-11-11")
        #expect(parse("上周五做了什么").range == nil)
        let none = parse("Lumen 的同步方案是什么？用了 3 个服务")
        #expect(none.days.isEmpty && none.range == nil)
        #expect(parse("1/2 的概率是多少").days.isEmpty)
    }
}

// MARK: - Storage

@Suite("Chat session store")
struct ChatSessionStoreTests {
    @Test("messages and their sources survive a round trip; sessions list newest first; deletion works")
    func roundTrip() throws {
        let store = try ChatSessionStore.inMemory()
        let (a, b) = (UUID(), UUID())
        let source = MemorySource(category: .work, file: "work.md", section: "Amai", date: "2026-11-10")
        try store.save(DisplayMessage(role: .user, text: "论文投到哪了？\n第二行", createdAt: Date(timeIntervalSince1970: 1)), in: a)
        try store.save(DisplayMessage(role: .assistant, text: "CHI 2027。", sources: [source], createdAt: Date(timeIntervalSince1970: 2)), in: a)
        try store.save(DisplayMessage(role: .user, text: String(repeating: "长", count: 80)), in: b)

        let messages = try store.messages(in: a)
        #expect(messages.map(\.role) == [.user, .assistant] && messages[1].sources == [source])
        let sessions = try store.recentSessions()
        #expect(sessions.map(\.id) == [b, a])
        #expect(sessions[1].title == "论文投到哪了？" && sessions[0].title.count == 61)

        try store.prune(keeping: 1)
        #expect(try store.recentSessions().map(\.id) == [b])
        #expect(try store.messages(in: a).isEmpty)
        try store.deleteAll()
        #expect(try store.recentSessions().isEmpty)
    }

    @Test("regenerating withdraws only the old answer")
    func deleteMessage() throws {
        let store = try ChatSessionStore.inMemory()
        let session = UUID()
        let question = DisplayMessage(role: .user, text: "问题", createdAt: Date(timeIntervalSince1970: 1))
        let answer = DisplayMessage(role: .assistant, text: "旧回答", createdAt: Date(timeIntervalSince1970: 2))
        try store.save(question, in: session)
        try store.save(answer, in: session)
        try store.deleteMessage(answer.id)
        #expect(try store.messages(in: session).map(\.id) == [question.id])
        #expect(try store.recentSessions().map(\.id) == [session])
    }
}

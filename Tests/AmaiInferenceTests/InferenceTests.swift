import AmaiCore
import Foundation
import os
import Testing
@testable import AmaiInference

@Suite("Thinking filter")
struct ThinkingFilterTests {
    @Test("removes thinking blocks split across chunks")
    func streaming() {
        var filter = ThinkingFilter()
        var out = ""
        for chunk in ["你好", "<th", "ink>内部", "推理</thi", "nk>，世界", "<|channel>thought", "<channel|>！"] {
            out += filter.feed(chunk)
        }
        out += filter.finish()
        #expect(out == "你好，世界！")
    }

    @Test("text that only looks like a marker prefix is kept")
    func falsePrefix() {
        var filter = ThinkingFilter()
        var out = filter.feed("a < b and <thin")
        out += filter.feed("g> c")
        out += filter.finish()
        #expect(out == "a < b and <thing> c")
    }

    @Test("an unclosed thinking block is dropped")
    func unclosed() {
        var filter = ThinkingFilter()
        let out = filter.feed("答案<think>还没想完") + filter.finish()
        #expect(out == "答案")
        #expect(MLXModelProvider.clean("<think>hmm</think>\n 在编辑文件 ") == "在编辑文件")
    }
}

@Suite("Inference gate")
struct InferenceGateTests {
    @Test("interactive waiters run before background waiters")
    func priorityOrder() async throws {
        let gate = InferenceGate()
        let order = OSAllocatedUnfairLock(initialState: [String]())
        try await gate.acquire(.background)

        let background = Task {
            try await gate.run(.background) { order.withLock { $0.append("background") } }
        }
        try await Task.sleep(for: .milliseconds(50))
        let interactive = Task {
            try await gate.run(.interactive) { order.withLock { $0.append("interactive") } }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(gate.interactiveRecentlyActive(within: 0))

        gate.release(.background)
        try await interactive.value
        try await background.value
        #expect(order.withLock { $0 } == ["interactive", "background"])
    }

    @Test("only one holder at a time")
    func exclusive() async throws {
        let gate = InferenceGate()
        let counters = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try await gate.run(index % 3 == 0 ? .interactive : .background) {
                        counters.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) }
                        try await Task.sleep(for: .milliseconds(2))
                        counters.withLock { $0.current -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(counters.withLock { $0.peak } == 1)
    }

    @Test("a cancelled waiter gives up its place without blocking others")
    func cancellation() async throws {
        let gate = InferenceGate()
        try await gate.acquire(.background)
        let waiter = Task { try await gate.acquire(.interactive) }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        gate.release(.background)
        // 闸门已空：下一个请求立即拿到。
        try await gate.acquire(.background)
        gate.release(.background)
    }

    @Test("interactive activity is remembered for a grace period")
    func grace() async throws {
        let gate = InferenceGate()
        #expect(!gate.interactiveRecentlyActive())
        try await gate.run(.interactive) {}
        #expect(gate.interactiveRecentlyActive(within: 30))
        #expect(!gate.interactiveRecentlyActive(within: 0))
    }
}

@Suite("Local model sessions")
struct FingerprintTests {
    @Test("fingerprints ignore images but not text, role or tool calls")
    func fingerprint() {
        let plain = ChatMessage.user("看一下屏幕")
        let withImage = ChatMessage.user("看一下屏幕", images: [ChatImage(jpeg: Data([1, 2, 3]))])
        #expect(LocalModelHost.fingerprint(plain) == LocalModelHost.fingerprint(withImage))
        #expect(LocalModelHost.fingerprint(plain) != LocalModelHost.fingerprint(.assistant("看一下屏幕")))
        let call = ChatToolCall(id: "c1", name: "search_memory", argumentsJSON: #"{"query":"Amai"}"#)
        #expect(LocalModelHost.fingerprint(.assistant("")) != LocalModelHost.fingerprint(.assistant("", toolCalls: [call])))
    }

    @Test("the same model tag shares one host")
    func sharedHost() {
        let a = LocalModelRuntime.host(for: "test/shared-model")
        let b = LocalModelRuntime.host(for: "test/shared-model")
        #expect(a === b)
        #expect(LocalModelRuntime.host(for: "test/other-model") !== a)
    }
}

@Suite("Prefix cache")
struct PrefixCacheTests {
    @Test("the common token prefix decides how much of a cached prompt can be reused")
    func commonPrefix() {
        #expect(LocalModelHost.commonPrefix([1, 2, 3], [1, 2, 3, 4, 5]) == 3)
        #expect(LocalModelHost.commonPrefix([1, 2, 9, 4], [1, 2, 3, 4]) == 2)
        #expect(LocalModelHost.commonPrefix([], [1]) == 0)
        #expect(LocalModelHost.commonPrefix([7], [8]) == 0)
    }

    @Test("an embedder whose model is not downloaded reports unavailable and refuses to embed")
    func embedderUnavailable() async {
        let embedder = MLXTextEmbedder(modelTag: "amai-tests/not-a-real-embedding-model")
        #expect(!embedder.isAvailable)
        await #expect(throws: ModelProviderError.self) { _ = try await embedder.embed(["你好"], kind: .query) }
        #expect((try? await embedder.embed([], kind: .query)) == [])
    }
}

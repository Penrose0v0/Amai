import Foundation
import Testing
@testable import AmaiCloud

/// 拦截 URLSession 请求，返回脚本化响应，并记录收到的请求。
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var status: Int
        var body: String
    }

    nonisolated(unsafe) static var stubs: [Stub] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub = Self.lock.withLock {
            Self.requests.append(request)
            Self.bodies.append(Self.readBody(request))
            return Self.stubs.isEmpty ? Stub(status: 500, body: "{}") : Self.stubs.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    static func reset(_ stubs: [Stub]) {
        lock.withLock {
            self.stubs = stubs
            requests = []
            bodies = []
        }
    }

    static func lastBody() -> [String: Any] {
        lock.withLock {
            (try? JSONSerialization.jsonObject(with: bodies.last ?? Data())) as? [String: Any] ?? [:]
        }
    }

    static var requestCount: Int { lock.withLock { requests.count } }
}

func mockTransport() -> HTTPTransport {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return HTTPTransport(session: URLSession(configuration: config), maxRetries: 2, sleep: { _ in })
}

let schemaJSON = #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}"#
let request = CloudRequest(system: "sys", user: "hello", maxTokens: 700, schemaName: "daily_digest", schemaJSON: schemaJSON)

// URLProtocol 的桩是全局状态，测试必须串行。
@Suite("Cloud clients", .serialized)
struct CloudClientTests {
    // MARK: Anthropic

    @Test("Anthropic: headers, structured output and effort in the request; text block parsed")
    func anthropicRequest() async throws {
        MockURLProtocol.reset([.init(status: 200, body: """
        {"model":"claude-opus-5-5","stop_reason":"end_turn",
         "content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\\"summary\\":\\"ok\\"}"}],
         "usage":{"input_tokens":120,"output_tokens":45}}
        """)])
        let client = AnthropicClient(apiKey: "sk-ant-test-key", transport: mockTransport())
        let response = try await client.generate(request)

        #expect(response.text == #"{"summary":"ok"}"#)
        #expect(response.inputTokens == 120 && response.outputTokens == 45)
        #expect(client.identifier == "anthropic:claude-opus-5-5")

        let sent = try #require(MockURLProtocol.lock.withLock { MockURLProtocol.requests.last })
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-key")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = MockURLProtocol.lastBody()
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["system"] as? String == "sys")
        #expect(body["thinking"] == nil)
        let output = try #require(body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "high")
        let format = try #require(output["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["additionalProperties"] as? Bool == false)
        #expect((body["max_tokens"] as? Int ?? 0) > 700)
    }

    @Test("Anthropic: refusal and max_tokens stop reasons are errors")
    func anthropicStopReasons() async throws {
        let client = AnthropicClient(apiKey: "k", transport: mockTransport())
        MockURLProtocol.reset([.init(status: 200, body: #"{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":null},"content":[]}"#)])
        await #expect(throws: CloudError.refusal("cyber")) { try await client.generate(request) }
        MockURLProtocol.reset([.init(status: 200, body: #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"{\"su"}]}"#)])
        await #expect(throws: CloudError.truncated) { try await client.generate(request) }
    }

    @Test("Anthropic: 429 and 529 are retried, 401 is not; the key never appears in errors")
    func anthropicRetries() async throws {
        let ok = MockURLProtocol.Stub(status: 200, body: #"{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}"#)
        MockURLProtocol.reset([.init(status: 429, body: "{}"), .init(status: 529, body: "{}"), ok])
        let client = AnthropicClient(apiKey: "sk-ant-secret-1234", transport: mockTransport())
        #expect(try await client.generate(request).text == "done")
        #expect(MockURLProtocol.requestCount == 3)

        MockURLProtocol.reset([.init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#), ok])
        do {
            _ = try await client.generate(request)
            Issue.record("expected unauthorized")
        } catch let error as CloudError {
            #expect(error == .unauthorized("invalid x-api-key"))
            #expect(!error.description.contains("sk-ant-secret"))
        }
        #expect(MockURLProtocol.requestCount == 1)
    }

    @Test("Anthropic: retries stop after maxRetries")
    func anthropicGivesUp() async throws {
        MockURLProtocol.reset(Array(repeating: .init(status: 503, body: "{}"), count: 5))
        let client = AnthropicClient(apiKey: "k", transport: mockTransport())
        await #expect(throws: CloudError.server(503)) { try await client.generate(request) }
        #expect(MockURLProtocol.requestCount == 3)
    }

    @Test("missing key or model fails before any request")
    func missingConfig() async throws {
        MockURLProtocol.reset([])
        await #expect(throws: CloudError.missingAPIKey(.anthropic)) {
            try await AnthropicClient(apiKey: "", transport: mockTransport()).generate(request)
        }
        await #expect(throws: CloudError.missingModel(.openai)) {
            try await OpenAIClient(apiKey: "k", model: "", transport: mockTransport()).generate(request)
        }
        #expect(MockURLProtocol.requestCount == 0)
    }

    // MARK: OpenAI

    @Test("OpenAI: bearer auth, strict json_schema response format, no reasoning_effort unless set")
    func openAIRequest() async throws {
        MockURLProtocol.reset([.init(status: 200, body: """
        {"model":"m1","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"{\\"summary\\":\\"ok\\"}","refusal":null}}],
         "usage":{"prompt_tokens":90,"completion_tokens":30}}
        """)])
        let client = OpenAIClient(apiKey: "sk-openai-key", model: "m1", transport: mockTransport())
        let response = try await client.generate(request)
        #expect(response.text == #"{"summary":"ok"}"#)
        #expect(response.inputTokens == 90 && response.outputTokens == 30)
        #expect(client.identifier == "openai:m1")

        let sent = try #require(MockURLProtocol.lock.withLock { MockURLProtocol.requests.last })
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "authorization") == "Bearer sk-openai-key")
        let body = MockURLProtocol.lastBody()
        #expect(body["reasoning_effort"] == nil)
        #expect((body["messages"] as? [[String: Any]])?.first?["role"] as? String == "system")
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["name"] as? String == "daily_digest")
        #expect(schema["strict"] as? Bool == true)
    }

    @Test("OpenAI: reasoning_effort sent when configured; custom base URL")
    func openAIOptions() async throws {
        MockURLProtocol.reset([.init(status: 200, body: #"{"choices":[{"finish_reason":"stop","message":{"content":"x"}}]}"#)])
        let client = OpenAIClient(
            apiKey: "k", model: "m", reasoningEffort: "high",
            baseURL: URL(string: "https://example.test/v1")!, transport: mockTransport()
        )
        _ = try await client.generate(request)
        #expect(MockURLProtocol.lastBody()["reasoning_effort"] as? String == "high")
        #expect(MockURLProtocol.lock.withLock { MockURLProtocol.requests.last?.url?.absoluteString } == "https://example.test/v1/chat/completions")
    }

    @Test("OpenAI: refusal and length are errors")
    func openAIStops() async throws {
        let client = OpenAIClient(apiKey: "k", model: "m", transport: mockTransport())
        MockURLProtocol.reset([.init(status: 200, body: #"{"choices":[{"finish_reason":"stop","message":{"content":null,"refusal":"I can't help with that."}}]}"#)])
        await #expect(throws: CloudError.refusal("I can't help with that.")) { try await client.generate(request) }
        MockURLProtocol.reset([.init(status: 200, body: #"{"choices":[{"finish_reason":"length","message":{"content":"{\"su"}}]}"#)])
        await #expect(throws: CloudError.truncated) { try await client.generate(request) }
    }

    @Test("masked key shows only the last four characters")
    func masked() {
        #expect(KeychainStore.masked("sk-ant-abcdef1234") == "••••1234")
        #expect(KeychainStore.masked("abc") == "••••")
    }
}

@Suite("KeychainStore")
struct KeychainStoreTests {
    @Test("set, read, replace and delete an API key")
    func roundTrip() throws {
        let store = KeychainStore(servicePrefix: "com.amai.tests.\(UUID().uuidString)")
        defer { try? store.deleteAPIKey(for: .openai) }
        #expect(store.apiKey(for: .openai) == nil)
        try store.setAPIKey("first-key\n", for: .openai)
        #expect(store.apiKey(for: .openai) == "first-key")
        try store.setAPIKey("second-key", for: .openai)
        #expect(store.apiKey(for: .openai) == "second-key")
        #expect(store.apiKey(for: .anthropic) == nil)
        try store.deleteAPIKey(for: .openai)
        #expect(store.apiKey(for: .openai) == nil)
    }
}

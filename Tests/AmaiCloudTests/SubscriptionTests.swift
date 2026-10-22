import Foundation
import Security
import Testing
@testable import AmaiCloud

// MARK: - Routed HTTP stub

/// 按 URL 路径返回响应的 URLProtocol，并记录请求体。
final class RoutedURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, String)
    nonisolated(unsafe) static var handler: Handler = { _, _ in (404, "{}") }
    nonisolated(unsafe) static var log: [(path: String, body: String, auth: String?)] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        let (status, text): (Int, String) = Self.lock.withLock {
            Self.log.append((request.url?.path ?? "", String(decoding: body, as: UTF8.self), request.value(forHTTPHeaderField: "authorization")))
            return Self.handler(request, body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    static func install(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler; log = [] }
    }

    static func requests(_ path: String) -> [(path: String, body: String, auth: String?)] {
        lock.withLock { log.filter { $0.path == path } }
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoutedURLProtocol.self]
        return URLSession(configuration: config)
    }
}

func form(_ body: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        if kv.count == 2 { result[kv[0]] = kv[1] }
    }
    return result
}

// MARK: - Test RSA key and JWT

struct TestSigner: @unchecked Sendable {
    let privateKey: SecKey
    let jwk: [String: String]

    init() {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        let (n, e) = Self.parseRSAPublicKey(der)
        jwk = ["kty": "RSA", "kid": "test-key", "alg": "RS256", "n": PKCE.base64URL(n), "e": PKCE.base64URL(e)]
    }

    var jwksJSON: String {
        let data = try! JSONSerialization.data(withJSONObject: ["keys": [jwk]])
        return String(decoding: data, as: UTF8.self)
    }

    func token(_ claims: [String: Any], kid: String = "test-key") -> String {
        let header = PKCE.base64URL(try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": kid, "typ": "JWT"]))
        let payload = PKCE.base64URL(try! JSONSerialization.data(withJSONObject: claims))
        let signingInput = Data("\(header).\(payload)".utf8)
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, nil)! as Data
        return "\(header).\(payload).\(PKCE.base64URL(signature))"
    }

    /// PKCS#1 RSAPublicKey：SEQUENCE { INTEGER n, INTEGER e }。
    static func parseRSAPublicKey(_ der: Data) -> (Data, Data) {
        var i = der.startIndex
        func length() -> Int {
            let first = Int(der[i]); i += 1
            guard first & 0x80 != 0 else { return first }
            var value = 0
            for _ in 0..<(first & 0x7F) { value = value << 8 | Int(der[i]); i += 1 }
            return value
        }
        i += 1; _ = length()                 // SEQUENCE
        i += 1; let nLen = length()          // INTEGER n
        let n = der[i..<(i + nLen)]; i += nLen
        i += 1; let eLen = length()          // INTEGER e
        let e = der[i..<(i + eLen)]
        return (Data(n), Data(e))
    }
}

func claims(aud: String, nonce: String, exp: Date = Date().addingTimeInterval(3600)) -> [String: Any] {
    ["iss": "https://auth.openai.com", "aud": aud, "sub": "user-123", "email": "test@example.com",
     "nonce": nonce, "exp": exp.timeIntervalSince1970, "iat": Date().timeIntervalSince1970]
}

let fullScope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

func discoveryRoutes(_ signer: TestSigner, path: String) -> (Int, String)? {
    switch path {
    case "/.well-known/openid-configuration":
        return (200, #"{"jwks_uri":"https://auth.openai.com/test-jwks","revocation_endpoint":"https://auth.openai.com/test-revoke"}"#)
    case "/test-jwks":
        return (200, signer.jwksJSON)
    case "/test-revoke":
        return (200, "")
    default:
        return nil
    }
}

func signedInCredential(expiresIn: TimeInterval = 3600, scopes: String = fullScope) -> ChatGPTCredential {
    ChatGPTCredential(
        email: "test@example.com", subject: "user-123", clientId: "oaiapp_test", hostId: "urn:uuid:host",
        idToken: "id", accessToken: "access-1", refreshToken: "refresh-1",
        expiresAt: Date().addingTimeInterval(expiresIn), scopes: scopes.split(separator: " ").map(String.init),
        savedAt: Date(), welcomed: true
    )
}

func storeWith(_ credential: ChatGPTCredential?) throws -> InMemorySecretStore {
    let store = InMemorySecretStore()
    if let credential {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try store.setData(encoder.encode(credential), for: ChatGPTSession.credentialName)
    }
    return store
}

// MARK: - Tests

@Suite("SIWC protocol")
struct SIWCProtocolTests {
    @Test("PKCE S256 matches the RFC 7636 example")
    func pkce() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("first authorization registers with dynamic_agent_client; later ones reuse the issued client")
    func authorizeURL() throws {
        let endpoints = SIWCEndpoints()
        func query(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
        let first = query(endpoints.authorizeURL(.init(
            clientId: nil, hostId: "urn:uuid:h", redirectURI: "http://127.0.0.1:1455/auth/callback",
            state: "s", nonce: "n", codeChallenge: "c"
        )))
        #expect(first["client_id"] == "dynamic_agent_client")
        #expect(first["agent_name_hint"] == "Amai")
        #expect(first["ext_agent_host_id"] == "urn:uuid:h")
        #expect(first["scope"] == fullScope)
        #expect(first["resource"] == "https://api.openai.com/v1")
        #expect(first["code_challenge_method"] == "S256")
        #expect(first["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")

        let again = query(endpoints.authorizeURL(.init(
            clientId: "oaiapp_x", hostId: "urn:uuid:h", redirectURI: "http://127.0.0.1:1455/auth/callback",
            state: "s", nonce: "n", codeChallenge: "c", idTokenHint: "old", loginHint: "a@b.c"
        )))
        #expect(again["client_id"] == "oaiapp_x")
        #expect(again["agent_name_hint"] == nil)
        #expect(again["id_token_hint"] == "old" && again["login_hint"] == "a@b.c")
    }

    @Test("ID token validation checks signature, issuer, audience, expiry and nonce")
    func idToken() throws {
        let signer = TestSigner()
        let keys = [JWK(kty: "RSA", kid: "test-key", n: signer.jwk["n"], e: signer.jwk["e"], alg: "RS256")]
        let good = signer.token(claims(aud: "oaiapp_x", nonce: "n1"))
        let result = try IDTokenValidator.validate(good, keys: keys, issuer: "https://auth.openai.com", audience: "oaiapp_x", nonce: "n1")
        #expect(result == IDTokenClaims(subject: "user-123", email: "test@example.com"))

        #expect(throws: IDTokenValidator.ValidationError.nonceMismatch) {
            try IDTokenValidator.validate(good, keys: keys, issuer: "https://auth.openai.com", audience: "oaiapp_x", nonce: "other")
        }
        #expect(throws: IDTokenValidator.ValidationError.wrongAudience) {
            try IDTokenValidator.validate(good, keys: keys, issuer: "https://auth.openai.com", audience: "oaiapp_y", nonce: "n1")
        }
        let expired = signer.token(claims(aud: "oaiapp_x", nonce: "n1", exp: Date().addingTimeInterval(-3600)))
        #expect(throws: IDTokenValidator.ValidationError.expired) {
            try IDTokenValidator.validate(expired, keys: keys, issuer: "https://auth.openai.com", audience: "oaiapp_x", nonce: "n1")
        }
        let otherSigner = TestSigner()
        let forged = otherSigner.token(claims(aud: "oaiapp_x", nonce: "n1"))
        #expect(throws: IDTokenValidator.ValidationError.badSignature) {
            try IDTokenValidator.validate(forged, keys: keys, issuer: "https://auth.openai.com", audience: "oaiapp_x", nonce: "n1")
        }
    }
}

@Suite("ChatGPT session and plan client", .serialized)
struct ChatGPTSessionTests {
    /// 完整登录：真实的 127.0.0.1 回调服务，授权与令牌接口为桩。
    @Test("sign-in registers, exchanges the code with PKCE, validates the ID token, and stores the credential")
    func signIn() async throws {
        let signer = TestSigner()
        let store = InMemorySecretStore()
        var config = SIWCConfiguration()
        config.preferredPort = 0
        let nonceBox = Box<String>("")
        RoutedURLProtocol.install { request, body in
            let path = request.url?.path ?? ""
            if let route = discoveryRoutes(signer, path: path) { return route }
            if path == "/api/accounts/oauth/token" {
                let idToken = signer.token(claims(aud: "oaiapp_test", nonce: nonceBox.value))
                return (200, #"{"access_token":"access-1","refresh_token":"refresh-1","id_token":"\#(idToken)","token_type":"Bearer","expires_in":3600,"scope":"\#(fullScope)"}"#)
            }
            return (404, "{}")
        }
        let session = ChatGPTSession(config: config, store: store, session: RoutedURLProtocol.session, openURL: { url in
            // 模拟浏览器：用户同意后，授权服务重定向到本机回调地址。
            let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            nonceBox.value = q["nonce"] ?? ""
            var callback = URLComponents(string: q["redirect_uri"]!)!
            callback.queryItems = [
                URLQueryItem(name: "code", value: "auth-code"),
                URLQueryItem(name: "state", value: q["state"]),
                URLQueryItem(name: "client_id", value: "oaiapp_test"),
            ]
            Task { _ = try? await URLSession(configuration: .ephemeral).data(from: callback.url!) }
        })

        let status = try await session.signIn(timeout: 20)
        #expect(status.signedIn && status.planUsageGranted && status.needsWelcome)
        #expect(status.email == "test@example.com")

        let exchange = try #require(RoutedURLProtocol.requests("/api/accounts/oauth/token").first)
        let fields = form(exchange.body)
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["client_id"] == "oaiapp_test")
        #expect(fields["code"] == "auth-code")
        #expect(fields["resource"] == "https://api.openai.com/v1")
        #expect((fields["code_verifier"] ?? "").count >= 43)
        #expect(fields["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)

        #expect(store.data(ChatGPTSession.credentialName) != nil)
        let host = try await session.hostId()
        #expect(host.hasPrefix("urn:uuid:"))
        try await session.markWelcomed()
        #expect(await session.status.needsWelcome == false)
    }

    @Test("a callback with the wrong state is rejected")
    func wrongState() async throws {
        var config = SIWCConfiguration()
        config.preferredPort = 0
        RoutedURLProtocol.install { _, _ in (404, "{}") }
        let session = ChatGPTSession(config: config, store: InMemorySecretStore(), session: RoutedURLProtocol.session, openURL: { url in
            let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            var callback = URLComponents(string: q["redirect_uri"]!)!
            callback.queryItems = [URLQueryItem(name: "code", value: "c"), URLQueryItem(name: "state", value: "forged")]
            Task { _ = try? await URLSession(configuration: .ephemeral).data(from: callback.url!) }
        })
        await #expect(throws: CloudError.signInRequired("授权回调的 state 不匹配，已中止")) {
            try await session.signIn(timeout: 20)
        }
        #expect(RoutedURLProtocol.requests("/api/accounts/oauth/token").isEmpty)
    }

    @Test("expiring tokens are refreshed once, serialized, and the rotated refresh token is saved")
    func refresh() async throws {
        let store = try storeWith(signedInCredential(expiresIn: 60))
        RoutedURLProtocol.install { request, _ in
            request.url?.path == "/api/accounts/oauth/token"
                ? (200, #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600}"#)
                : (404, "{}")
        }
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        async let a = session.accessTokenForInference()
        async let b = session.accessTokenForInference()
        let tokens = try await [a, b]
        #expect(tokens == ["access-2", "access-2"])
        let refreshes = RoutedURLProtocol.requests("/api/accounts/oauth/token")
        #expect(refreshes.count == 1)
        let fields = form(refreshes[0].body)
        #expect(fields["grant_type"] == "refresh_token" && fields["client_id"] == "oaiapp_test")
        #expect(fields["refresh_token"] == "refresh-1" && fields["scope"] == nil)
        #expect(String(decoding: store.data(ChatGPTSession.credentialName)!, as: UTF8.self).contains("refresh-2"))
    }

    @Test("a terminal refresh error clears tokens but keeps the issued client ID")
    func terminalRefresh() async throws {
        let store = try storeWith(signedInCredential(expiresIn: 10))
        RoutedURLProtocol.install { _, _ in (400, #"{"error":"invalid_grant"}"#) }
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        await #expect(throws: CloudError.signInRequired("ChatGPT 登录已失效（invalid_grant），请重新登录")) {
            try await session.accessTokenForInference()
        }
        #expect(await session.status.signedIn == false)
        let saved = String(decoding: store.data(ChatGPTSession.credentialName)!, as: UTF8.self)
        #expect(saved.contains("oaiapp_test") && !saved.contains("refresh-1"))
    }

    @Test("without the plan scope, inference is refused")
    func missingScope() async throws {
        let store = try storeWith(signedInCredential(scopes: "openid profile email offline_access"))
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        await #expect(throws: CloudError.planNotEligible("登录时没有授予 ChatGPT 套餐用量，请重新登录并允许")) {
            try await session.accessTokenForInference()
        }
    }

    @Test("sign-out revokes the refresh token and keeps the client and host IDs")
    func signOut() async throws {
        let signer = TestSigner()
        let store = try storeWith(signedInCredential())
        try store.setData(Data("urn:uuid:host".utf8), for: ChatGPTSession.hostIdName)
        RoutedURLProtocol.install { request, _ in discoveryRoutes(signer, path: request.url?.path ?? "") ?? (404, "{}") }
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        #expect(await session.signOut())
        let revoke = try #require(RoutedURLProtocol.requests("/test-revoke").first)
        let fields = form(revoke.body)
        #expect(fields["token"] == "refresh-1" && fields["token_type_hint"] == "refresh_token" && fields["client_id"] == "oaiapp_test")
        #expect(await session.status.signedIn == false)
        #expect(try await session.hostId() == "urn:uuid:host")
        #expect(String(decoding: store.data(ChatGPTSession.credentialName)!, as: UTF8.self).contains("oaiapp_test"))
    }

    @Test("model list keeps only visible models")
    func models() async throws {
        let store = try storeWith(signedInCredential())
        RoutedURLProtocol.install { _, _ in
            (200, #"{"models":[{"slug":"gpt-a","display_name":"GPT A","visibility":"list"},{"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide"}]}"#)
        }
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        let models = try await session.listModels()
        #expect(models == [ChatGPTModel(slug: "gpt-a", displayName: "GPT A")])
        #expect(RoutedURLProtocol.requests("/v1/models").first?.auth == "Bearer access-1")
    }

    // MARK: Plan client

    static let sse = """
    event: response.created
    data: {"type":"response.created","response":{"id":"r1"}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"{\\"summary\\":"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"\\"ok\\"}"}

    event: response.completed
    data: {"type":"response.completed","response":{"model":"gpt-a","usage":{"input_tokens":50,"output_tokens":7}}}

    """

    static let request = CloudRequest(system: "sys", user: "hello", maxTokens: 500, schemaName: "daily_digest",
                                      schemaJSON: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}"#)

    @Test("Responses request carries instructions, store:false, stream:true and a strict schema; SSE is assembled")
    func planRequest() async throws {
        let store = try storeWith(signedInCredential())
        RoutedURLProtocol.install { _, _ in (200, Self.sse) }
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        let client = ChatGPTPlanClient(session: session, model: "gpt-a", http: RoutedURLProtocol.session, sleep: { _ in })
        let response = try await client.generate(Self.request)
        #expect(response.text == #"{"summary":"ok"}"#)
        #expect(response.inputTokens == 50 && response.outputTokens == 7)
        #expect(client.identifier == "chatgpt-plan:gpt-a")

        let sent = try #require(RoutedURLProtocol.requests("/v1/responses").first)
        #expect(sent.auth == "Bearer access-1")
        let body = try #require(try JSONSerialization.jsonObject(with: Data(sent.body.utf8)) as? [String: Any])
        #expect(body["instructions"] as? String == "sys")
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
        #expect(body["temperature"] == nil && body["max_output_tokens"] == nil)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.first?["role"] as? String == "user")
        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema" && format["strict"] as? Bool == true && format["name"] as? String == "daily_digest")
    }

    @Test("an unsupported schema falls back to plain text for the rest of the run")
    func schemaFallback() async throws {
        let store = try storeWith(signedInCredential())
        RoutedURLProtocol.install { _, body in
            String(decoding: body, as: UTF8.self).contains("json_schema")
                ? (400, #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"text.format","message":"unsupported"}}"#)
                : (200, Self.sse)
        }
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        let client = ChatGPTPlanClient(session: session, model: "gpt-a", http: RoutedURLProtocol.session, sleep: { _ in })
        #expect(try await client.generate(Self.request).text == #"{"summary":"ok"}"#)
        #expect(await session.structuredOutputUnsupported)
        _ = try await client.generate(Self.request)
        #expect(RoutedURLProtocol.requests("/v1/responses").count == 3)
    }

    @Test("usage limits map to planUsageLimit, before or during the stream")
    func usageLimit() async throws {
        let store = try storeWith(signedInCredential())
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        let client = ChatGPTPlanClient(session: session, model: "gpt-a", http: RoutedURLProtocol.session, sleep: { _ in })
        RoutedURLProtocol.install { _, _ in (429, #"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}"#) }
        await #expect(throws: CloudError.planUsageLimit("已达到 ChatGPT 套餐在 Amai 中的用量上限，可在 ChatGPT 设置的 Usage 中查看")) {
            try await client.generate(Self.request)
        }
        RoutedURLProtocol.install { _, _ in
            (200, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"{\"}\n\ndata: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n")
        }
        do {
            _ = try await client.generate(Self.request)
            Issue.record("expected usage limit")
        } catch let error as CloudError {
            guard case .planUsageLimit = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test("a stream that ends without response.completed is a failure; incomplete means truncated")
    func incompleteStreams() async throws {
        let store = try storeWith(signedInCredential())
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        let client = ChatGPTPlanClient(session: session, model: "gpt-a", http: RoutedURLProtocol.session, sleep: { _ in })
        RoutedURLProtocol.install { _, _ in (200, "data: {\"type\":\"response.incomplete\",\"response\":{}}\n\n") }
        await #expect(throws: CloudError.truncated) { try await client.generate(Self.request) }
        RoutedURLProtocol.install { _, _ in (200, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}\n\n") }
        do {
            _ = try await client.generate(Self.request)
            Issue.record("expected failure")
        } catch let error as CloudError {
            guard case .network = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test("a 401 triggers one token refresh and a retry")
    func unauthorizedRetry() async throws {
        let store = try storeWith(signedInCredential())
        let calls = Box(0)
        RoutedURLProtocol.install { request, _ in
            if request.url?.path == "/api/accounts/oauth/token" {
                return (200, #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600}"#)
            }
            calls.value += 1
            return calls.value == 1 ? (401, #"{"detail":"unauthorized"}"#) : (200, Self.sse)
        }
        let session = ChatGPTSession(store: store, session: RoutedURLProtocol.session, openURL: { _ in })
        let client = ChatGPTPlanClient(session: session, model: "gpt-a", http: RoutedURLProtocol.session, sleep: { _ in })
        #expect(try await client.generate(Self.request).text == #"{"summary":"ok"}"#)
        #expect(RoutedURLProtocol.requests("/v1/responses").last?.auth == "Bearer access-2")
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - Claude Code

final class FakeRunner: ProcessRunning, @unchecked Sendable {
    struct Call { let executable: URL; let arguments: [String]; let environment: [String: String]; let stdin: String; let cwd: URL }
    private let lock = NSLock()
    var responses: [ProcessResult] = []
    private(set) var calls: [Call] = []

    func run(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL, stdin: Data, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock {
            calls.append(Call(executable: executable, arguments: arguments, environment: environment,
                              stdin: String(decoding: stdin, as: UTF8.self), cwd: workingDirectory))
            return responses.isEmpty ? ProcessResult(status: 1, stdout: Data(), stderr: Data(), timedOut: false) : responses.removeFirst()
        }
    }
}

func output(_ json: String, status: Int32 = 0, stderr: String = "") -> ProcessResult {
    ProcessResult(status: status, stdout: Data(json.utf8), stderr: Data(stderr.utf8), timedOut: false)
}

@Suite("Claude Code client")
struct ClaudeCodeClientTests {
    let exe = URL(fileURLWithPath: "/opt/fake/bin/claude")
    let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("amai-claude-test")
    let request = CloudRequest(system: "整理规则", user: "当天记录", maxTokens: 700, schemaName: "daily_digest",
                               schemaJSON: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}"#)

    @Test("runs claude -p text-only and isolated, prompt on stdin, without API key variables")
    func invocation() async throws {
        let runner = FakeRunner()
        runner.responses = [output(#"{"type":"result","is_error":false,"result":"","structured_output":{"summary":"ok"},"modelUsage":{"claude-opus-5-5":{"inputTokens":3,"outputTokens":20,"cacheCreationInputTokens":100,"cacheReadInputTokens":0}}}"#)]
        let client = ClaudeCodeClient(executable: exe, model: "opus", workingDirectory: cwd, runner: runner)
        let response = try await client.generate(request)
        #expect(response.text == #"{"summary":"ok"}"#)
        #expect(response.model == "claude-opus-5-5" && response.inputTokens == 103 && response.outputTokens == 20)
        #expect(client.identifier == "claude-code:opus")

        let call = try #require(runner.calls.first)
        let a = call.arguments
        #expect(a.first == "-p")
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        #expect(value("--output-format") == "json")
        #expect(value("--model") == "opus")
        #expect(value("--system-prompt") == "整理规则")
        #expect(value("--tools") == "")
        #expect(value("--setting-sources") == "project")
        #expect(value("--json-schema") == request.schemaJSON)
        #expect(a.contains("--no-session-persistence") && a.contains("--strict-mcp-config") && a.contains("--disable-slash-commands"))
        #expect(!a.contains("当天记录"))
        #expect(call.stdin == "当天记录")
        #expect(call.cwd == cwd)

        let env = ClaudeCodeClient.environment(from: ["HOME": "/Users/x", "USER": "x", "ANTHROPIC_API_KEY": "sk-secret", "CLAUDE_CODE_SESSION_ID": "s"], executable: exe)
        #expect(env["ANTHROPIC_API_KEY"] == nil && env["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(env["HOME"] == "/Users/x")
        #expect(env["PATH"]?.hasPrefix("/opt/fake/bin:") == true)
        #expect(call.environment["ANTHROPIC_API_KEY"] == nil)
    }

    @Test("falls back to result text when there is no structured output")
    func resultText() throws {
        let r = try ClaudeCodeClient.parse(output("diagnostic line\n" + #"{"is_error":false,"result":"{\"summary\":\"x\"}"}"#), model: "sonnet")
        #expect(r.text == #"{"summary":"x"}"#)
    }

    @Test("errors are classified: not logged in, usage limit, unknown model, crash")
    func errors() {
        #expect(throws: CloudError.signInRequired("请在终端运行 claude 并执行 /login")) {
            try ClaudeCodeClient.parse(output(#"{"is_error":true,"result":"Not logged in · Please run /login"}"#), model: "opus")
        }
        do {
            _ = try ClaudeCodeClient.parse(output(#"{"is_error":true,"result":"Claude usage limit reached. Your limit will reset at 5pm"}"#), model: "opus")
            Issue.record("expected usage limit")
        } catch let error as CloudError {
            guard case .planUsageLimit = error else { Issue.record("got \(error)"); return }
        } catch { Issue.record("\(error)") }
        do {
            _ = try ClaudeCodeClient.parse(output(#"{"is_error":true,"result":""}"#, stderr: #"[claude-code:unrecognized_model] {"model":"x"}"#), model: "x")
            Issue.record("expected bad model")
        } catch let error as CloudError {
            guard case .badRequest(let m) = error, m.hasPrefix("模型不可用") else { Issue.record("got \(error)"); return }
        } catch { Issue.record("\(error)") }
        #expect(throws: CloudError.local("Claude Code 退出码 139")) {
            try ClaudeCodeClient.parse(output("", status: 139), model: "opus")
        }
    }

    @Test("status reads only login state from auth status output")
    func status() async throws {
        let runner = FakeRunner()
        runner.responses = [
            output("2.1.302 (Claude Code)\n"),
            output(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"a@b.c"}"#),
        ]
        let status = try await ClaudeCodeClient.status(executable: exe, runner: runner, workingDirectory: cwd)
        #expect(status.version == "2.1.302 (Claude Code)")
        #expect(status.usesSubscription && status.subscriptionType == "max")
        #expect(runner.calls.map(\.arguments) == [["--version"], ["auth", "status"]])
    }

    @Test("locator prefers the configured path and finds nvm installs, newest first")
    func locator() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("amai-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["v18.0.0", "v24.21.0"] {
            let bin = home.appendingPathComponent(".nvm/versions/node/\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let file = bin.appendingPathComponent("claude")
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let found = ClaudeCodeLocator.locate(configured: nil, home: home)
        #expect(found?.path.contains("v24.21.0") == true)
        #expect(ClaudeCodeLocator.locate(configured: "/nonexistent/claude", home: home) == nil)
    }
}

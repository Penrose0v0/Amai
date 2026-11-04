import Foundation

/// 一个 ChatGPT 账户的 SIWC 会话：登录、令牌刷新、退出登录、模型列表（ADR-0005）。
/// 令牌记录与本机 host ID 存在 `SecretStore`（App 中为钥匙串）。所有令牌操作在 actor 内串行，
/// 满足"同一会话的刷新必须串行，避免轮换令牌竞争"的要求。
public actor ChatGPTSession {
    public static let credentialName = "chatgpt.credential"
    public static let hostIdName = "chatgpt.host-id"

    public struct Status: Sendable, Equatable {
        public var signedIn: Bool
        public var email: String?
        public var planUsageGranted: Bool
        public var needsWelcome: Bool
    }

    public let config: SIWCConfiguration
    private let store: any SecretStore
    private let endpoints: SIWCEndpoints
    private let openURL: @Sendable (URL) async -> Void
    private let now: @Sendable () -> Date
    private var credential: ChatGPTCredential?
    private var refreshTask: Task<ChatGPTCredential, Error>?
    /// SIWC 路由不支持 JSON Schema 时置位，本次运行内不再发送 `text.format`。
    public private(set) var structuredOutputUnsupported = false

    public init(
        config: SIWCConfiguration = .init(),
        store: any SecretStore,
        session: URLSession = .shared,
        openURL: @escaping @Sendable (URL) async -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.store = store
        self.endpoints = SIWCEndpoints(config: config, session: session)
        self.openURL = openURL
        self.now = now
        self.credential = store.data(Self.credentialName).flatMap { try? Self.decoder.decode(ChatGPTCredential.self, from: $0) }
    }

    public var status: Status {
        Status(
            signedIn: credential?.isSignedIn ?? false,
            email: credential?.email,
            planUsageGranted: credential?.scopes.contains(config.planScope) ?? false,
            needsWelcome: (credential?.isSignedIn ?? false) && !(credential?.welcomed ?? true)
        )
    }

    /// 本机稳定的 `ext_agent_host_id`（`urn:uuid:…`）：首次登录前生成并永久保存，退出登录也不变。
    public func hostId() throws -> String {
        if let data = store.data(Self.hostIdName), let id = String(data: data, encoding: .utf8), !id.isEmpty { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        try store.setData(Data(id.utf8), for: Self.hostIdName)
        return id
    }

    // MARK: - Sign in

    /// 浏览器授权流程：启动回调服务 → 打开授权页 → 校验 state / client ID → 用 PKCE 换令牌 →
    /// 验证 ID token → 检查是否授予套餐用量 → 保存到钥匙串。
    @discardableResult
    public func signIn(timeout: TimeInterval = 300) async throws -> Status {
        let host = try hostId()
        let existingClient = credential?.clientId
        let verifier = PKCE.randomURLSafe(bytes: 48)
        let state = PKCE.randomURLSafe()
        let nonce = PKCE.randomURLSafe()

        let server = try await LoopbackServer.start(preferredPort: config.preferredPort, path: config.callbackPath)
        defer { server.stop() }
        let url = endpoints.authorizeURL(.init(
            clientId: existingClient,
            hostId: host,
            redirectURI: server.redirectURI,
            state: state,
            nonce: nonce,
            codeChallenge: PKCE.challenge(for: verifier),
            idTokenHint: existingClient == nil ? nil : credential?.idToken,
            loginHint: existingClient == nil ? nil : credential?.email
        ))
        await openURL(url)
        let callback = try await server.waitForCallback(timeout: timeout)

        guard callback["state"] == state else { throw CloudError.signInRequired(String(localized: "授权回调的 state 不匹配，已中止")) }
        if let error = callback["error"] {
            throw CloudError.signInRequired(error == "access_denied" ? String(localized: "你在浏览器中取消了授权") : String(localized: "授权失败：\(String(describing: error))"))
        }
        guard let code = callback["code"], !code.isEmpty else { throw CloudError.signInRequired(String(localized: "授权回调缺少 code")) }

        let clientId: String
        if let existingClient {
            if let returned = callback["client_id"], !returned.isEmpty, returned != existingClient {
                throw CloudError.signInRequired(String(localized: "授权返回了不同的 client ID，已拒绝"))
            }
            clientId = existingClient
        } else {
            guard let issued = callback["client_id"], !issued.isEmpty, issued != config.dynamicClientID else {
                throw CloudError.signInRequired(String(localized: "首次注册没有返回 client ID"))
            }
            clientId = issued
        }

        let tokens = try await endpoints.exchange(code: code, verifier: verifier, clientId: clientId, redirectURI: server.redirectURI)
        guard let idToken = tokens.id_token, let refresh = tokens.refresh_token else { throw CloudError.invalidResponse }
        let claims: IDTokenClaims
        do {
            claims = try IDTokenValidator.validate(
                idToken, keys: try await endpoints.jwks(), issuer: config.issuer,
                audience: clientId, nonce: nonce, now: now()
            )
        } catch let error as IDTokenValidator.ValidationError {
            throw CloudError.signInRequired(String(localized: "ID token 校验失败（\(String(describing: error))）"))
        }

        let previous = credential
        credential = ChatGPTCredential(
            email: claims.email,
            subject: claims.subject,
            clientId: clientId,
            hostId: host,
            idToken: idToken,
            accessToken: tokens.access_token,
            refreshToken: refresh,
            expiresAt: now().addingTimeInterval(TimeInterval(tokens.expires_in ?? 3600)),
            scopes: (tokens.scope ?? "").split(separator: " ").map(String.init),
            savedAt: now(),
            welcomed: previous?.subject == claims.subject ? (previous?.welcomed ?? false) : false
        )
        try save()
        return status
    }

    /// 首次登录说明已被用户关闭（"Got it"）。
    public func markWelcomed() throws {
        guard credential != nil else { return }
        credential?.welcomed = true
        try save()
    }

    // MARK: - Tokens

    /// 用于推理的访问令牌：到期前 5 分钟内自动刷新；未授予套餐用量时报错。
    public func accessTokenForInference() async throws -> String {
        guard let current = credential, current.isSignedIn else {
            throw CloudError.signInRequired(String(localized: "尚未登录 ChatGPT"))
        }
        guard current.scopes.contains(config.planScope) else {
            throw CloudError.planNotEligible(String(localized: "登录时没有授予 ChatGPT 套餐用量，请重新登录并允许"))
        }
        if current.expiresAt.timeIntervalSince(now()) > 300 { return current.accessToken }
        return try await refreshed().accessToken
    }

    /// 强制刷新（收到 401 后使用一次）。
    public func forceRefresh() async throws -> String {
        try await refreshed().accessToken
    }

    private func refreshed() async throws -> ChatGPTCredential {
        if let refreshTask { return try await refreshTask.value }
        guard let current = credential, current.isSignedIn else { throw CloudError.signInRequired(String(localized: "尚未登录 ChatGPT")) }
        let endpoints = self.endpoints
        let now = self.now
        let task = Task<ChatGPTCredential, Error> {
            let tokens = try await endpoints.refresh(clientId: current.clientId, refreshToken: current.refreshToken)
            var next = current
            next.accessToken = tokens.access_token
            if let rotated = tokens.refresh_token { next.refreshToken = rotated }
            if let id = tokens.id_token { next.idToken = id }
            if let scope = tokens.scope { next.scopes = scope.split(separator: " ").map(String.init) }
            next.expiresAt = now().addingTimeInterval(TimeInterval(tokens.expires_in ?? 3600))
            next.savedAt = now()
            return next
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let next = try await task.value
            credential = next
            try save()
            return next
        } catch let error as CloudError {
            if case .signInRequired = error {
                // 终止性刷新错误：清除不可用的令牌，保留 client ID 与 host ID 供重新授权。
                credential?.accessToken = ""
                credential?.refreshToken = ""
                try? save()
            }
            throw error
        }
    }

    // MARK: - Sign out

    /// 撤销刷新令牌并清除本地令牌（保留签发的 client ID 以便下次登录复用）。
    /// 返回 false 表示撤销未确认，界面需提示用户到 ChatGPT 设置中断开 Amai。
    @discardableResult
    public func signOut() async -> Bool {
        guard let current = credential else { return true }
        var revoked = !current.isSignedIn
        if current.isSignedIn {
            for attempt in 0..<3 {
                do {
                    try await endpoints.revoke(clientId: current.clientId, refreshToken: current.refreshToken)
                    revoked = true
                    break
                } catch {
                    if attempt < 2 { try? await Task.sleep(for: .seconds(Double(attempt + 1))) }
                }
            }
        }
        credential?.accessToken = ""
        credential?.refreshToken = ""
        try? save()
        return revoked
    }

    // MARK: - Models

    /// `GET /v1/models`，保留 `visibility == "list"` 的模型。
    public func listModels(session: URLSession = .shared) async throws -> [ChatGPTModel] {
        let token = try await accessTokenForInference()
        var request = URLRequest(url: config.apiBase.appendingPathComponent("models"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 30
        let (data, response) = try await endpoints.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ChatGPTPlanClient.mapError(status: status, data: data) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let list = (obj["models"] as? [[String: Any]]) ?? (obj["data"] as? [[String: Any]]) ?? []
        return list.compactMap { m in
            guard let slug = (m["slug"] as? String) ?? (m["id"] as? String) else { return nil }
            if let visibility = m["visibility"] as? String, visibility != "list" { return nil }
            return ChatGPTModel(slug: slug, displayName: (m["display_name"] as? String) ?? slug)
        }
    }

    func markStructuredOutputUnsupported() { structuredOutputUnsupported = true }

    // MARK: - Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func save() throws {
        guard let credential else { return }
        try store.setData(Self.encoder.encode(credential), for: Self.credentialName)
    }
}

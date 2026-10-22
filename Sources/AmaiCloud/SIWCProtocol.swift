import CryptoKit
import Foundation
import Security

// Sign in with ChatGPT（SIWC）的 ChatGPT plan usage 协议细节（ADR-0005）。
// 依据：developers.openai.com/siwc/token-sharing-open-source/ 下的 sign-in、profiles-and-sessions、
// token-reference、models-and-inference、preview-limitations、errors-and-recovery 各页（2026-10-22 核对）。

public struct SIWCConfiguration: Sendable, Equatable {
    public var issuer = "https://auth.openai.com"
    public var authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public var tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public var openIDConfigurationURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public var resource = "https://api.openai.com/v1"
    public var apiBase = URL(string: "https://api.openai.com/v1")!
    public var scopes = ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    public var planScope = "chatgpt.tokens.use.direct"
    public var dynamicClientID = "dynamic_agent_client"
    public var appName = "Amai"
    public var callbackPath = "/auth/callback"
    public var preferredPort: UInt16 = 1455
    /// 官方 UI 规范要求提供 "Manage usage" 入口，指向 ChatGPT 设置中的用量页面。
    public var manageUsageURL = URL(string: "https://chatgpt.com/#settings")!

    public init() {}
}

/// 保存在钥匙串中的令牌记录。字段与官方示例记录一致。
public struct ChatGPTCredential: Codable, Sendable, Equatable {
    public var email: String?
    public var subject: String
    /// 签发的 `oaiapp_…` client ID，按账户保存并在之后的登录中复用。
    public var clientId: String
    public var hostId: String
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]
    public var savedAt: Date
    /// 是否已显示过首次登录说明（"You're using your ChatGPT plan"）。
    public var welcomed: Bool

    public var isSignedIn: Bool { !refreshToken.isEmpty }
}

public struct ChatGPTModel: Sendable, Equatable, Identifiable {
    public let slug: String
    public let displayName: String
    public var id: String { slug }
}

// MARK: - PKCE & randomness

public enum PKCE {
    public static func randomURLSafe(bytes count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    /// `code_challenge = base64url(SHA256(verifier))`，无填充（RFC 7636，S256）。
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

// MARK: - Token endpoint

public struct SIWCTokenResponse: Decodable, Sendable, Equatable {
    public let access_token: String
    public let refresh_token: String?
    public let id_token: String?
    public let token_type: String?
    public let expires_in: Int?
    public let scope: String?
}

/// 授权请求、令牌交换、刷新与撤销。
public struct SIWCEndpoints: Sendable {
    public let config: SIWCConfiguration
    public let session: URLSession

    public init(config: SIWCConfiguration = .init(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public struct AuthorizeParameters: Sendable {
        public var clientId: String?
        public var hostId: String
        public var redirectURI: String
        public var state: String
        public var nonce: String
        public var codeChallenge: String
        public var idTokenHint: String?
        public var loginHint: String?
    }

    /// 首次注册用 `dynamic_agent_client` 并带 `agent_name_hint`；之后用签发的 client ID。
    public func authorizeURL(_ p: AuthorizeParameters) -> URL {
        let registering = p.clientId == nil
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: p.clientId ?? config.dynamicClientID),
            URLQueryItem(name: "ext_agent_host_id", value: p.hostId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: p.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "resource", value: config.resource),
            URLQueryItem(name: "state", value: p.state),
            URLQueryItem(name: "nonce", value: p.nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: p.codeChallenge),
        ]
        if registering {
            items.append(URLQueryItem(name: "agent_name_hint", value: config.appName))
        } else {
            if let hint = p.idTokenHint { items.append(URLQueryItem(name: "id_token_hint", value: hint)) }
            if let login = p.loginHint { items.append(URLQueryItem(name: "login_hint", value: login)) }
        }
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        // URLComponents 不转义 "+"，空格已编码为 %20，按 RFC 3986 处理即可。
        return components.url!
    }

    public func exchange(code: String, verifier: String, clientId: String, redirectURI: String) async throws -> SIWCTokenResponse {
        try await postForm(config.tokenURL, [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "resource": config.resource,
        ])
    }

    /// 刷新：不带 scope 以保留原授权；返回新的轮换刷新令牌。
    public func refresh(clientId: String, refreshToken: String) async throws -> SIWCTokenResponse {
        try await postForm(config.tokenURL, [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
            "resource": config.resource,
        ])
    }

    /// 撤销刷新令牌。空的 200 视为成功（包括令牌已失效）。
    public func revoke(clientId: String, refreshToken: String) async throws {
        let endpoint = try await openIDConfiguration().revocationEndpoint
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = Self.formBody(["token": refreshToken, "token_type_hint": "refresh_token", "client_id": clientId])
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public struct OpenIDConfiguration: Sendable {
        public let jwksURI: URL
        public let revocationEndpoint: URL
    }

    public func openIDConfiguration() async throws -> OpenIDConfiguration {
        let (data, _) = try await session.data(from: config.openIDConfigurationURL)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jwks = (obj["jwks_uri"] as? String).flatMap(URL.init(string:)),
              let revoke = (obj["revocation_endpoint"] as? String).flatMap(URL.init(string:))
        else { throw CloudError.invalidResponse }
        return OpenIDConfiguration(jwksURI: jwks, revocationEndpoint: revoke)
    }

    public func jwks() async throws -> [JWK] {
        let uri = try await openIDConfiguration().jwksURI
        let (data, _) = try await session.data(from: uri)
        struct Set: Decodable { let keys: [JWK] }
        guard let set = try? JSONDecoder().decode(Set.self, from: data) else { throw CloudError.invalidResponse }
        return set.keys
    }

    private func postForm(_ url: URL, _ fields: [String: String]) async throws -> SIWCTokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = Self.formBody(fields)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudError.network("无法连接 ChatGPT 授权服务")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.tokenError(status: status, data: data) }
        guard let token = try? JSONDecoder().decode(SIWCTokenResponse.self, from: data) else {
            throw CloudError.invalidResponse
        }
        return token
    }

    /// 刷新错误中的终止性错误：清除令牌，用已保存的 client ID 重新授权。
    static let terminalRefreshErrors: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
    ]

    static func tokenError(status: Int, data: Data) -> CloudError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (obj["error"] as? String) ?? ((obj["error"] as? [String: Any])?["code"] as? String) ?? ""
        if terminalRefreshErrors.contains(code) { return .signInRequired("ChatGPT 登录已失效（\(code)），请重新登录") }
        if code == "invalid_client" { return .badRequest("invalid_client：客户端配置错误") }
        if status >= 500 { return .server(status) }
        return .badRequest(code.isEmpty ? "HTTP \(status)" : code)
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - ID token validation (RS256 against OpenAI JWKS)

public struct JWK: Decodable, Sendable, Equatable {
    public let kty: String
    public let kid: String?
    public let n: String?
    public let e: String?
    public let alg: String?
}

public struct IDTokenClaims: Sendable, Equatable {
    public let subject: String
    public let email: String?
}

public enum IDTokenValidator {
    public enum ValidationError: Error, Equatable {
        case malformed
        case unsupportedAlgorithm
        case unknownKey
        case badSignature
        case wrongIssuer
        case wrongAudience
        case expired
        case nonceMismatch
    }

    /// 验证签名、issuer、audience（签发的 client ID）、有效期与 nonce。
    public static func validate(
        _ token: String, keys: [JWK], issuer: String, audience: String, nonce: String, now: Date = Date()
    ) throws -> IDTokenClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = PKCE.base64URLDecode(parts[0]),
              let payloadData = PKCE.base64URLDecode(parts[1]),
              let signature = PKCE.base64URLDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw ValidationError.malformed }

        guard header["alg"] as? String == "RS256" else { throw ValidationError.unsupportedAlgorithm }
        let kid = header["kid"] as? String
        guard let jwk = keys.first(where: { $0.kty == "RSA" && (kid == nil || $0.kid == kid) }),
              let key = rsaPublicKey(jwk)
        else { throw ValidationError.unknownKey }

        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else {
            throw ValidationError.badSignature
        }
        guard claims["iss"] as? String == issuer else { throw ValidationError.wrongIssuer }
        let aud = claims["aud"]
        let audOK = (aud as? String) == audience || ((aud as? [String])?.contains(audience) ?? false)
        guard audOK else { throw ValidationError.wrongAudience }
        guard let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp) > now.addingTimeInterval(-60) else {
            throw ValidationError.expired
        }
        guard claims["nonce"] as? String == nonce else { throw ValidationError.nonceMismatch }
        guard let sub = claims["sub"] as? String else { throw ValidationError.malformed }
        return IDTokenClaims(subject: sub, email: claims["email"] as? String)
    }

    /// 从 JWK 的 n / e 构造 PKCS#1 RSAPublicKey DER，交给 Security 框架。
    static func rsaPublicKey(_ jwk: JWK) -> SecKey? {
        guard let nData = jwk.n.flatMap(PKCE.base64URLDecode), let eData = jwk.e.flatMap(PKCE.base64URLDecode) else { return nil }
        let der = derSequence(derInteger(nData) + derInteger(eData))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    static func derLength(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func derInteger(_ raw: Data) -> Data {
        var bytes = Array(raw.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return Data([0x02]) + derLength(bytes.count) + Data(bytes)
    }

    static func derSequence(_ content: Data) -> Data {
        Data([0x30]) + derLength(content.count) + content
    }
}

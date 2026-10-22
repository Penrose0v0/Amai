import Foundation
import Security

/// 按名称存取的小块机密数据。钥匙串实现用于 App，内存实现用于测试。
public protocol SecretStore: Sendable {
    func data(_ name: String) -> Data?
    func setData(_ data: Data, for name: String) throws
    func delete(_ name: String) throws
}

/// macOS 钥匙串（通用密码）。API Key、ChatGPT 令牌记录与本机 ID 都存这里，
/// 不写配置文件、不进日志（ADR-0004 / ADR-0005）。
public struct KeychainStore: SecretStore {
    public let servicePrefix: String

    public init(servicePrefix: String = "com.amai.app") {
        self.servicePrefix = servicePrefix
    }

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(Int32)
    }

    private func query(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(name)",
            kSecAttrAccount as String: name.hasPrefix("chatgpt") ? "credential" : "api-key",
        ]
    }

    public func data(_ name: String) -> Data? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public func setData(_ data: Data, for name: String) throws {
        let status = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(name)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Amai \(name)"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: API keys (ADR-0004)

    public func apiKey(for provider: CloudProvider) -> String? {
        guard let data = data(provider.rawValue), let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    public func setAPIKey(_ key: String, for provider: CloudProvider) throws {
        try setData(Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8), for: provider.rawValue)
    }

    public func deleteAPIKey(for provider: CloudProvider) throws {
        try delete(provider.rawValue)
    }

    /// 界面只显示末 4 位。
    public static func masked(_ key: String) -> String {
        key.count > 4 ? "••••" + key.suffix(4) : "••••"
    }
}

/// 测试用的内存实现。
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func data(_ name: String) -> Data? { lock.withLock { items[name] } }
    public func setData(_ data: Data, for name: String) throws { lock.withLock { items[name] = data } }
    public func delete(_ name: String) throws { _ = lock.withLock { items.removeValue(forKey: name) } }
}

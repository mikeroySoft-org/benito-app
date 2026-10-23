import Foundation
#if canImport(Security)
import Security
#endif

/// Persists session bearer tokens, keyed per server origin.
public protocol SessionTokenStore: Sendable {
    func token(for server: URL) throws -> String?
    func setToken(_ token: String, for server: URL) throws
    func deleteToken(for server: URL) throws
}

public enum SessionTokenStoreError: Error, Sendable, Equatable {
    /// Keychain call failed with this `OSStatus` (an `Int32`).
    case keychain(Int32)
}

public enum SessionTokenStoreKey {
    /// Normalized origin used as the storage key: lowercased scheme + host, port only when
    /// non-default, no path/query/fragment. `https://Host.Example:443/api/` → `https://host.example`.
    public static func account(for server: URL) -> String {
        guard
            let components = URLComponents(url: server, resolvingAgainstBaseURL: true),
            let scheme = components.scheme?.lowercased(),
            var host = components.host?.lowercased(),
            !host.isEmpty
        else {
            var raw = server.absoluteString
            while raw.hasSuffix("/") { raw.removeLast() }
            return raw
        }
        if host.contains(":"), !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        var origin = "\(scheme)://\(host)"
        if let port = components.port, port != defaultPort(for: scheme) {
            origin += ":\(port)"
        }
        return origin
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }
}

/// Process-local token store for tests, previews, and platforms without Keychain.
public final class InMemorySessionTokenStore: SessionTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    public init() {}

    public func token(for server: URL) throws -> String? {
        let key = SessionTokenStoreKey.account(for: server)
        lock.lock()
        defer { lock.unlock() }
        return tokens[key]
    }

    public func setToken(_ token: String, for server: URL) throws {
        let key = SessionTokenStoreKey.account(for: server)
        lock.lock()
        defer { lock.unlock() }
        tokens[key] = token
    }

    public func deleteToken(for server: URL) throws {
        let key = SessionTokenStoreKey.account(for: server)
        lock.lock()
        defer { lock.unlock() }
        tokens[key] = nil
    }
}

#if canImport(Security)
/// Keychain-backed token store (generic passwords, `AfterFirstUnlockThisDeviceOnly`,
/// never synced). One item per server origin under `service`.
public struct KeychainSessionTokenStore: SessionTokenStore {
    public let service: String

    public init(service: String = "com.mikeroysoft.benito.session") {
        self.service = service
    }

    public func token(for server: URL) throws -> String? {
        var query = baseQuery(for: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw failure(status, operation: "read")
        }
    }

    public func setToken(_ token: String, for server: URL) throws {
        let data = Data(token.utf8)
        let query = baseQuery(for: server)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw failure(addStatus, operation: "add")
            }
        default:
            throw failure(updateStatus, operation: "update")
        }
    }

    public func deleteToken(for server: URL) throws {
        let status = SecItemDelete(baseQuery(for: server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure(status, operation: "delete")
        }
    }

    private func baseQuery(for server: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: SessionTokenStoreKey.account(for: server),
        ]
    }

    private func failure(_ status: OSStatus, operation: String) -> SessionTokenStoreError {
        BenitoLog.api.error("keychain \(operation, privacy: .public) failed status=\(status, privacy: .public)")
        return .keychain(status)
    }
}
#endif

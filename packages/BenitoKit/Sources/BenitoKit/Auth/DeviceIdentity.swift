import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// This phone's P-256 signing key: the passwordless identity behind device sessions.
///
/// Secure Enclave when the hardware has one (the private key never leaves it); otherwise
/// (Simulator, some Macs) a software key kept in the Keychain, this-device-only.
public protocol DeviceIdentity: Sendable {
    /// Base64 X9.63 uncompressed public key, as `POST /devices` expects.
    func publicKeyBase64() throws -> String
    /// Base64 DER ECDSA-SHA256 signature.
    func sign(_ message: Data) throws -> String
}

public enum DeviceAuthMessage {
    /// The exact bytes the server verifies for `POST /auth/device/session`.
    public static func make(deviceId: String, timestamp: Int) -> Data {
        Data("benito-device-auth:v1:\(deviceId):\(timestamp)".utf8)
    }
}

/// Process-local key for tests and previews.
public final class EphemeralDeviceIdentity: DeviceIdentity, @unchecked Sendable {
    private let key = P256.Signing.PrivateKey()

    public init() {}

    public func publicKeyBase64() throws -> String {
        key.publicKey.x963Representation.base64EncodedString()
    }

    public func sign(_ message: Data) throws -> String {
        try key.signature(for: message).derRepresentation.base64EncodedString()
    }
}

#if canImport(Security)
public enum DeviceIdentityError: Error, Sendable {
    case keychain(Int32)
}

public final class KeychainDeviceIdentity: DeviceIdentity, @unchecked Sendable {
    private enum StoredKey {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private let service: String
    private let account = "device-signing-key"
    private let lock = NSLock()
    private var cached: StoredKey?

    public init(service: String = "com.benito.device-identity") {
        self.service = service
    }

    /// True when the key lives in the Secure Enclave.
    public var isHardwareBacked: Bool {
        if case .enclave = try? loadOrCreate() { return true }
        return false
    }

    public func publicKeyBase64() throws -> String {
        switch try loadOrCreate() {
        case .enclave(let key): key.publicKey.x963Representation.base64EncodedString()
        case .software(let key): key.publicKey.x963Representation.base64EncodedString()
        }
    }

    public func sign(_ message: Data) throws -> String {
        switch try loadOrCreate() {
        case .enclave(let key): try key.signature(for: message).derRepresentation.base64EncodedString()
        case .software(let key): try key.signature(for: message).derRepresentation.base64EncodedString()
        }
    }

    /// Forgets the key (Account › Reset). The server-side device row should be revoked too.
    public func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceIdentityError.keychain(status)
        }
    }

    private func loadOrCreate() throws -> StoredKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let key: StoredKey
        if let stored = try readBlob() {
            // First byte tags the representation: 1 = enclave handle, 2 = software raw key.
            let body = stored.dropFirst()
            switch stored.first {
            case 1: key = .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body))
            default: key = .software(try P256.Signing.PrivateKey(rawRepresentation: body))
            }
        } else if SecureEnclave.isAvailable, let enclave = try? SecureEnclave.P256.Signing.PrivateKey() {
            try writeBlob(Data([1]) + enclave.dataRepresentation)
            key = .enclave(enclave)
        } else {
            let software = P256.Signing.PrivateKey()
            try writeBlob(Data([2]) + software.rawRepresentation)
            key = .software(software)
        }
        cached = key
        return key
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readBlob() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw DeviceIdentityError.keychain(status)
        }
    }

    private func writeBlob(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceIdentityError.keychain(status) }
    }
}
#endif

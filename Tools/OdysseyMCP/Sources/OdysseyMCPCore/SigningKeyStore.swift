import Foundation
import CryptoKit
import Security

// The key this Mac signs change batches with. The phone auto-applies only batches signed by
// a key the user paired there, after comparing fingerprints.
public protocol SigningKeyStore: Sendable {
    func loadOrCreate() throws -> P256.Signing.PrivateKey
}

public enum SigningKeyError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    public var description: String {
        if case .keychain(let status) = self {
            return "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
        return "Keychain error"
    }
}

// In the login Keychain, never synced: another Mac on the account needs its own pairing.
public struct KeychainSigningKeyStore: SigningKeyStore {
    private let service = "com.uliseis.odysseyfinance.bridge"
    private let account = "mac-signing-key"

    public init() {}

    public func loadOrCreate() throws -> P256.Signing.PrivateKey {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound else { throw SigningKeyError.keychain(status) }

        let key = P256.Signing.PrivateKey()
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrLabel: "Odyssey Finance bridge signing key", kSecValueData: key.rawRepresentation,
            kSecAttrSynchronizable: false,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw SigningKeyError.keychain(added) }
        return key
    }
}

// Tests, and ODYSSEY_BRIDGE_KEY=ephemeral: a key that lives as long as the process.
public struct EphemeralSigningKeyStore: SigningKeyStore {
    private let key: P256.Signing.PrivateKey
    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) { self.key = key }
    public func loadOrCreate() -> P256.Signing.PrivateKey { key }
}

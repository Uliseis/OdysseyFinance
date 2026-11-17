import Foundation
import Security

public enum MarketKeyError: Error, Equatable {
    case notFound
    case keychain(OSStatus)
}

// What the live-value refresh reads, so its tests can stand in for the Keychain.
public protocol MarketKeys: Sendable {
    func loadTrading212() throws -> Trading212Credentials
    func loadEODHD() throws -> String
}

// Same storage shape as EBKeychain (iCloud-synced generic passwords, readable from the first
// unlock after boot, biometrics provided by the app's Face ID gate) for the market-data API
// credentials.
public struct MarketKeychain: MarketKeys, Sendable {
    public let service: String
    public init(service: String = "com.uliseis.odysseyfinance.market") {
        self.service = service
    }

    private static let t212Key = "trading212-api-key"
    private static let t212Secret = "trading212-api-secret"
    private static let eodhdKey = "eodhd-api-key"

    public func storeTrading212(key: String, secret: String) throws {
        try store(Self.t212Key, key)
        try store(Self.t212Secret, secret)
    }

    public func loadTrading212() throws -> Trading212Credentials {
        Trading212Credentials(key: try load(Self.t212Key), secret: try load(Self.t212Secret))
    }

    public var hasTrading212: Bool { (try? loadTrading212()) != nil }

    public func removeTrading212() {
        remove(Self.t212Key)
        remove(Self.t212Secret)
    }

    public func storeEODHD(apiKey: String) throws {
        try store(Self.eodhdKey, apiKey)
    }

    public func loadEODHD() throws -> String {
        try load(Self.eodhdKey)
    }

    public var hasEODHD: Bool { (try? loadEODHD()) != nil }

    public func removeEODHD() {
        remove(Self.eodhdKey)
    }

    private func remove(_ account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny as Any,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func store(_ account: String, _ value: String) throws {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanTrue as Any,
        ]
        SecItemDelete(base as CFDictionary)
        let status = SecItemAdd(KeyProtection.add(Data(value.utf8), to: base) as CFDictionary, nil)
        guard status == errSecSuccess else { throw MarketKeyError.keychain(status) }
    }

    private func load(_ account: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny as Any,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? MarketKeyError.notFound : MarketKeyError.keychain(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw MarketKeyError.notFound
        }
        return value
    }
}

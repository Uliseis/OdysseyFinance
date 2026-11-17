import XCTest
@testable import CoreIntegrations

final class KeyProtectionTests: XCTestCase {
    private let service = "com.example.tests"

    private func item(synchronizable: Bool) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: "api-key", kSecAttrSynchronizable: synchronizable]
    }

    private func accessible(_ dict: [CFString: Any]) -> String? {
        dict[kSecAttrAccessible] as? String
    }

    // MARK: Saving

    func testASyncedKeyIsSavedReadableAfterTheFirstUnlock() {
        let add = KeyProtection.add(Data("value".utf8), to: item(synchronizable: true))
        XCTAssertEqual(accessible(add), kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(add[kSecAttrSynchronizable] as? Bool, true)
        XCTAssertEqual(add[kSecValueData] as? Data, Data("value".utf8))
        XCTAssertNil(add[kSecAttrAccessControl])
    }

    func testAKeyThatDoesntSyncIsSavedForThisDeviceOnly() {
        let add = KeyProtection.add(Data("value".utf8), to: item(synchronizable: false))
        XCTAssertEqual(accessible(add), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(add[kSecAttrSynchronizable] as? Bool, false)
    }

    // MARK: Upgrading saved keys

    func testTheUpgradeListsEveryItemOfTheServiceByItsAttributesNeverItsSecret() {
        let query = KeyProtection.listing(service: service)
        XCTAssertEqual(query[kSecAttrService] as? String, service)
        XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrSynchronizable] as? String, kSecAttrSynchronizableAny as String)
        XCTAssertEqual(query[kSecReturnAttributes] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit] as? String, kSecMatchLimitAll as String)
        XCTAssertNil(query[kSecReturnData])
        XCTAssertNil(query[kSecAttrAccount])
    }

    func testASyncedKeyReadableOnlyWhileUnlockedIsReprotected() throws {
        let saved: [String: Any] = [
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
            kSecAttrSynchronizable as String: NSNumber(value: 1),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked as String,
        ]
        let upgrade = try XCTUnwrap(KeyProtection.upgrade(for: saved))
        XCTAssertEqual(upgrade.match[kSecClass] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(upgrade.match[kSecAttrService] as? String, service)
        XCTAssertEqual(upgrade.match[kSecAttrAccount] as? String, "api-key")
        XCTAssertEqual(upgrade.match[kSecAttrSynchronizable] as? Bool, true)
        XCTAssertNil(upgrade.match[kSecReturnData])
        XCTAssertEqual(upgrade.changes.count, 1)
        XCTAssertEqual(accessible(upgrade.changes), kSecAttrAccessibleAfterFirstUnlock as String)
    }

    func testAKeyThatDoesntSyncIsReprotectedForThisDeviceOnly() throws {
        let saved: [String: Any] = [
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
            kSecAttrSynchronizable as String: NSNumber(value: 0),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked as String,
        ]
        let upgrade = try XCTUnwrap(KeyProtection.upgrade(for: saved))
        XCTAssertEqual(upgrade.match[kSecAttrSynchronizable] as? Bool, false)
        XCTAssertEqual(upgrade.changes.count, 1)
        XCTAssertEqual(accessible(upgrade.changes), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testAnUpgradedKeyIsLeftAlone() {
        let synced: [String: Any] = [
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
            kSecAttrSynchronizable as String: NSNumber(value: 1),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock as String,
        ]
        var local = synced
        local[kSecAttrSynchronizable as String] = NSNumber(value: 0)
        local[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        XCTAssertNil(KeyProtection.upgrade(for: synced))
        XCTAssertNil(KeyProtection.upgrade(for: local))
    }

    // MARK: Keychain

    private func savedAccessibility(_ service: String) throws -> String? {
        var query = KeyProtection.listing(service: service)
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &found), errSecSuccess)
        return try XCTUnwrap(found as? [String: Any])[kSecAttrAccessible as String] as? String
    }

    func testASavedKeyIsReadableAfterTheFirstUnlock() throws {
        let keychain = MarketKeychain(service: "\(service).\(UUID())")
        defer { keychain.removeEODHD() }
        do {
            try keychain.storeEODHD(apiKey: "test-key")
        } catch MarketKeyError.keychain(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("synced keychain items need a signed host")
        }
        XCTAssertEqual(try savedAccessibility(keychain.service), kSecAttrAccessibleAfterFirstUnlock as String)
    }

    func testTheUpgradeReprotectsAKeySavedReadableOnlyWhileUnlockedAndKeepsItsValue() throws {
        let keychain = MarketKeychain(service: "\(service).\(UUID())")
        defer { keychain.removeEODHD() }
        let old: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: keychain.service,
            kSecAttrAccount: "eodhd-api-key", kSecAttrSynchronizable: true,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked, kSecValueData: Data("test-key".utf8),
        ]
        let added = SecItemAdd(old as CFDictionary, nil)
        if added == errSecMissingEntitlement { throw XCTSkip("synced keychain items need a signed host") }
        XCTAssertEqual(added, errSecSuccess)

        XCTAssertEqual(KeyProtection.upgrade(service: keychain.service), errSecSuccess)
        XCTAssertEqual(try savedAccessibility(keychain.service), kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(try keychain.loadEODHD(), "test-key")
        // Nothing left to change: a second run is a no-op.
        XCTAssertEqual(KeyProtection.upgrade(service: keychain.service), errSecSuccess)
    }
}

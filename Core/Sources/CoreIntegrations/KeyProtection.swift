import Foundation
import Security

// D18: the keys are readable from the first unlock after boot, so the background bank sync
// and price refresh work while the iPhone is locked. A synced item can't be ThisDeviceOnly.
public enum KeyProtection {
    static func accessible(synchronizable: Bool) -> CFString {
        synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    static func add(_ data: Data, to item: [CFString: Any]) -> [CFString: Any] {
        var add = item
        add[kSecValueData] = data
        add[kSecAttrAccessible] = accessible(synchronizable: item[kSecAttrSynchronizable] as? Bool ?? false)
        return add
    }

    // Attributes only: the upgrade never reads a secret.
    static func listing(service: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrSynchronizable: kSecAttrSynchronizableAny,
         kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
    }

    // nil once the item has the right class, so a run with nothing to change writes nothing
    // (and syncs nothing through iCloud Keychain).
    static func upgrade(for item: [String: Any]) -> (match: [CFString: Any], changes: [CFString: Any])? {
        guard let service = item[kSecAttrService as String] as? String,
              let account = item[kSecAttrAccount as String] as? String else { return nil }
        let synchronizable = item[kSecAttrSynchronizable as String] as? Bool ?? false
        let wanted = accessible(synchronizable: synchronizable)
        guard item[kSecAttrAccessible as String] as? String != wanted as String else { return nil }
        return ([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                 kSecAttrAccount: account, kSecAttrSynchronizable: synchronizable],
                [kSecAttrAccessible: wanted])
    }

    // Changing an item's class re-wraps it, which needs the phone unlocked.
    static func upgrade(service: String) -> OSStatus {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(listing(service: service) as CFDictionary, &found)
        guard status == errSecSuccess else { return status == errSecItemNotFound ? errSecSuccess : status }
        for item in found as? [[String: Any]] ?? [] {
            guard let (match, changes) = upgrade(for: item) else { continue }
            let updated = SecItemUpdate(match as CFDictionary, changes as CFDictionary)
            guard updated == errSecSuccess else { return updated }
        }
        return errSecSuccess
    }

    // Keys saved before D18 were readable only while unlocked. Returns the first failure.
    public static func upgradeSavedKeys() -> OSStatus {
        let statuses = [EBKeychain().service, MarketKeychain().service].map { upgrade(service: $0) }
        return statuses.first { $0 != errSecSuccess } ?? errSecSuccess
    }
}

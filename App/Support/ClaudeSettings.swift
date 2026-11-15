import Foundation
import CryptoKit
import CoreBridge

// Per-device switches for Claude's change batches (docs/decisions.md D13). Per device on
// purpose: an iPad left on the same iCloud account must not apply the same batch twice.
enum ClaudeSettings {
    static let acceptKey = "claude.acceptChanges"
    static let autoApplyKey = "claude.autoApply"
    static let trustedKeysKey = "claude.trustedKeys"
    static let processedKey = "claude.processedBatches"

    static var acceptsChanges: Bool { UserDefaults.standard.bool(forKey: acceptKey) }

    static var autoApply: Set<AutoApplyKind> {
        get { Set((UserDefaults.standard.stringArray(forKey: autoApplyKey) ?? []).compactMap(AutoApplyKind.init)) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: autoApplyKey) }
    }

    // Public keys of the Macs paired here, by key id. Public, so UserDefaults is enough:
    // only this app can write them.
    static var trustedKeys: [String: BridgePublicKey] {
        get {
            guard let data = UserDefaults.standard.data(forKey: trustedKeysKey) else { return [:] }
            return (try? JSONDecoder().decode([String: BridgePublicKey].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: trustedKeysKey) }
    }

    static var verifiers: [String: P256.Signing.PublicKey] {
        trustedKeys.compactMapValues { try? BridgeSigning.publicKey($0) }
    }

    static func isProcessed(_ id: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: processedKey) ?? []).contains(id.uuidString)
    }

    static func markProcessed(_ id: UUID) {
        let recent = (UserDefaults.standard.stringArray(forKey: processedKey) ?? []).suffix(199)
        UserDefaults.standard.set(Array(recent) + [id.uuidString], forKey: processedKey)
    }

    static var snapshotState: BridgeAppState.Claude {
        .init(acceptsChanges: acceptsChanges, trustedKeyIds: trustedKeys.keys.sorted(),
              autoApply: autoApply.sorted { $0.rawValue < $1.rawValue })
    }

    static func title(_ kind: AutoApplyKind) -> String {
        switch kind {
        case .categorizeUncategorized: "Categorize Uncategorized Rows"
        case .createCategory: "Create Categories"
        case .createRule: "Create Rules"
        case .applyRules: "Re-run Rules"
        case .recordValuation: "Record Valuations"
        case .requestBankSync: "Sync Banks on Request"
        }
    }
}

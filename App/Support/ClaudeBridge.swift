import Foundation
import SwiftData
import CoreModel
import CoreLogic
import CoreBridge

// Files shared with Claude's MCP server on the Mac through the app's iCloud Drive container
// (docs/decisions.md D13). The Mac sees them under
// ~/Library/Mobile Documents/iCloud~com~uliseis~odysseyfinance/bridge/.
enum ClaudeBridge {
    static let containerId = "iCloud.com.uliseis.odysseyfinance"
    @MainActor private static var lastExport = Date.distantPast

    // nil when iCloud Drive is off. The container lookup can block, so it never runs on main.
    static func root() async -> URL? {
        #if DEBUG
        // Simulator runs point this at a local folder instead of iCloud.
        if let dir = ProcessInfo.processInfo.environment["OFBRIDGE_DIR"] {
            return URL(filePath: dir, directoryHint: .isDirectory)
        }
        #endif
        return await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: containerId)?
                .appending(path: "bridge", directoryHint: .isDirectory)
        }.value
    }

    // On foreground, after a bank sync and after applying commands. Calls within 30 seconds
    // of the last export are dropped: a foreground usually triggers more than one of these.
    @MainActor
    static func exportSnapshot(_ ctx: ModelContext) async {
        guard Date().timeIntervalSince(lastExport) > 30 else { return }
        lastExport = Date()
        guard let root = await root() else {
            print("[ClaudeBridge] no iCloud Drive container; snapshot skipped")
            return
        }
        do {
            let snapshot = try BridgeExport.make(in: ctx, appState: appState, redact: true)
            let url = root.appending(path: "snapshot.json")
            try await Task.detached(priority: .utility) {
                try write(try BridgeCoding.encoder().encode(snapshot), to: url)
            }.value
            print("[ClaudeBridge] snapshot written to \(url.path)")
        } catch {
            print("[ClaudeBridge] snapshot export failed: \(error)")
        }
    }

    // Coordinated so iCloud never uploads a half-written file.
    nonisolated static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    @MainActor
    private static var appState: BridgeAppState {
        let d = UserDefaults.standard
        let cycle = CycleSettings.current
        let since = d.double(forKey: AutomationSettings.pensionSinceKey)
        return BridgeAppState(
            cycleStartDay: cycle.startDay,
            cycleStartsEarlyOnWeekends: cycle.startsEarlyOnWeekends,
            currentSpaceId: d.string(forKey: SpaceSelection.key).flatMap(UUID.init(uuidString:)),
            automation: .init(
                recurringEnabled: AutomationSettings.recurringEnabled,
                recurringMuted: AutomationSettings.muted.sorted(),
                recurringDeclined: AutomationSettings.declinedRecurring.sorted(),
                recurringPins: AutomationSettings.pins,
                pensionEnabled: d.bool(forKey: AutomationSettings.pensionEnabledKey),
                pensionSourceAccountId: d.string(forKey: AutomationSettings.pensionSourceKey).flatMap(UUID.init(uuidString:)),
                pensionTargetAccountId: d.string(forKey: AutomationSettings.pensionTargetKey).flatMap(UUID.init(uuidString:)),
                pensionAmount: d.string(forKey: AutomationSettings.pensionAmountKey).flatMap(CoreLogic.Transactions.parseAmount),
                pensionSince: since > 0 ? Date(timeIntervalSince1970: since) : nil,
                pensionDeclinedArrivals: AutomationSettings.declinedSplits.sorted()))
    }
}

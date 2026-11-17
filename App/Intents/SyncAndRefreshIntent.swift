import AppIntents
import SwiftData
import CoreSync

// Syncs the banks and refreshes investment values without opening the app, so a daily personal
// automation in Shortcuts can keep the numbers fresh: iOS runs background tasks only when it
// decides to. Unlike Log Card Charge, it writes straight away: it uses the app's own container
// and main context (registered in App.init, same process), starting sync first if this launch
// hasn't, so its saves reach CloudKit through SaveObserver like any other.
struct SyncAndRefreshIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync & Refresh"
    static let description = IntentDescription(
        "Syncs your bank accounts and refreshes the value of investments priced live. Banks are skipped if they were tried in the last 15 minutes.")
    static let openAppWhenRun = false

    @Dependency private var container: ModelContainer
    @Dependency private var engine: CloudKitSyncEngine

    // Awaits all of it: iOS keeps the app running only until perform returns.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if CloudKitGate.isAvailable { try? engine.start() }
        let summary = await ForegroundBankSync.syncAndRefresh(container.mainContext, engine: engine)
        return .result(dialog: "\(summary)")
    }
}

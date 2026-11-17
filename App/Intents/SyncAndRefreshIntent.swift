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
    // iOS gives an action about 30 seconds, counted from before perform starts. A bank still
    // syncing then carries on in the background (LongRunningIntent needs the iOS 27 SDK).
    static let answerWithin: Duration = .seconds(25)

    @Dependency private var container: ModelContainer
    @Dependency private var engine: CloudKitSyncEngine

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deadline = ContinuousClock.now + Self.answerWithin
        if CloudKitGate.isAvailable { try? engine.start() }
        let summary = await ForegroundBankSync.syncAndRefresh(
            container.mainContext, engine: engine, answeringBy: deadline)
        return .result(dialog: "\(summary)")
    }
}

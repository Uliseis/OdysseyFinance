import AppIntents
import SwiftData
import CoreLogic
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
    // Before iOS 27 an action gets about 30 seconds, counted from before perform starts. A bank
    // still syncing then carries on in the background.
    static let answerWithin: Duration = .seconds(25)

    @Dependency private var container: ModelContainer
    @Dependency private var engine: CloudKitSyncEngine

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deadline = ContinuousClock.now + Self.answerWithin
        if CloudKitGate.isAvailable { try? engine.start() }
        // A bank this run cuts short records why, starting with the extra time iOS refused.
        let cutOff = CoreLogic.CutOff()
        if #available(iOS 27, *) {
            switch await runToTheEnd() {
            case .success(let summary): return .result(dialog: "\(summary)")
            case .failure(let refusal): cutOff.note("iOS refused the Shortcuts action the time to finish (\(refusal))")
            }
        }
        let summary = await CoreLogic.CutOff.$reason.withValue(cutOff) {
            await ForegroundBankSync.syncAndRefresh(container.mainContext, engine: engine, answeringBy: deadline)
        }
        return .result(dialog: "\(summary)")
    }
}

// CancellableIntent is what lets performBackgroundTask take onCancel.
@available(iOS 27, *)
extension SyncAndRefreshIntent: LongRunningIntent, CancellableIntent {
    // Fails with iOS's refusal when it doesn't give the extra time, which it refuses to an action
    // run from inside the app: the 25-second answer takes over. Ended early, it answers with what
    // got done.
    @MainActor
    fileprivate func runToTheEnd() async -> Result<String, any Error> {
        let steps = ForegroundBankSync.Steps(showing: progress)
        do {
            return .success(try await inBackgroundTask(steps))
        } catch {
            guard steps.started || steps.cancelled || Task.isCancelled else { return .failure(error) }
            return .success(await steps.stop())
        }
    }

    // performBackgroundTask isn't main-actor isolated, and Swift 6 won't let the main actor hand it
    // a closure. Called from off the main actor, the closure holds only Sendable values and
    // reaches the main context from inside.
    private nonisolated func inBackgroundTask(_ steps: ForegroundBankSync.Steps) async throws -> String {
        let container = container, engine = engine
        return try await performBackgroundTask { @MainActor in
            await ForegroundBankSync.syncAndRefresh(container.mainContext, engine: engine, steps: steps)
        } onCancel: { reason in
            steps.cutOff.note(Self.why(reason))
            Task { @MainActor in steps.cancel() }
        }
    }

    private nonisolated static func why(_ reason: IntentCancellationReason) -> String {
        switch reason {
        case .timeout: "iOS ended the Shortcuts action: it ran out of time"
        case .userCancelled: "the Shortcuts action was cancelled"
        default: "iOS ended the Shortcuts action (\(reason.debugDescription))"
        }
    }
}

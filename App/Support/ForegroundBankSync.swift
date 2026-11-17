import Foundation
import SwiftData
import UIKit
import CoreLogic
import CoreModel
import CoreIntegrations
import CoreSync

// Bank data used to refresh only from the Connections screen (a manual tap) or from the
// BGProcessingTask — and iOS runs processing tasks opportunistically, typically only while
// charging and idle, so in practice the app never refreshed itself. This pulls Enable
// Banking whenever the app comes to the foreground, and from the Sync & Refresh Shortcuts
// action, throttled (CoreLogic.BankSyncThrottle) so opening the app twice in a row doesn't
// hammer the API.
enum ForegroundBankSync {
    // The steps done so far, for the Shortcuts action's answer at its deadline.
    @MainActor
    final class Progress {
        var investments: CoreLogic.InvestmentRefresh.Outcome?
        var banks: CoreLogic.SyncSummary.Banks?
    }

    @MainActor
    static func runIfDue(_ ctx: ModelContext, engine: CloudKitSyncEngine?) async {
        // The Wallet automation launches the app in the background to run the quick-add
        // intent; a bank sync started there is suspended seconds later and shows up as an
        // "abandoned" run, having also burned the 15-minute window for the real foreground.
        guard UIApplication.shared.applicationState != .background else { return }
        let pace = CoreLogic.ForegroundSyncPace()
        guard pace.isDue(), CoreLogic.BankSyncThrottle().isDue(), !CoreLogic.BankSync.isRunning else { return }
        pace.record()
        await withBackgroundTask("ForegroundBankSync") {
            _ = await refresh(ctx, engine: engine)
        }
    }

    // App Intents get about 30 seconds and one bank can take longer, so the Shortcuts action
    // answers by the deadline with what's done. The run isn't a child of the action's task, so
    // answering doesn't cancel it: it carries on in the background time iOS gives the app, then
    // writes the Claude bridge snapshot so its runs can be checked from the Mac.
    @MainActor
    static func syncAndRefresh(
        _ ctx: ModelContext, engine: CloudKitSyncEngine?, answeringBy deadline: ContinuousClock.Instant
    ) async -> String {
        let progress = Progress()
        let run = Task { @MainActor in
            await withBackgroundTask("SyncAndRefresh") {
                let summary = await refresh(ctx, engine: engine, progress: progress)
                // Forced past the export's 30-second pause, which the write at the deadline started;
                // an unchanged snapshot is still skipped.
                if !Task.isCancelled { await ClaudeBridge.exportSnapshot(ctx, force: true) }
                return summary
            }
        }
        if let summary = await CoreLogic.Deadline.value(of: run, by: deadline) { return summary }
        // What's done so far reaches the Mac now, in case iOS stops the rest.
        Task { await ClaudeBridge.exportSnapshot(ctx) }
        return CoreLogic.SyncSummary.soFar(banks: progress.banks, investments: progress.investments)
    }

    // The foreground hook and the Shortcuts action share this: investments, then banks unless
    // they were tried in the last 15 minutes, the automations that follow every sync, and a push.
    // Returns what it did in a line, for the action's answer.
    @MainActor
    private static func refresh(_ ctx: ModelContext, engine: CloudKitSyncEngine?, progress: Progress? = nil) async -> String {
        // First, and pushed straight away, so the values leave the phone even when a bank runs
        // long. Independent of Enable Banking: brokers and crypto have their own sources, and an
        // unconfigured bank connection shouldn't stop them refreshing.
        let investments = await CoreLogic.InvestmentRefresh.run(in: ctx)
        progress?.investments = investments
        // SaveObserver has queued the values; the nudge doesn't hold the banks up on CloudKit.
        Task { await engine?.sendPendingChanges() }
        // Out of background time: the rest waits for the next run.
        guard !Task.isCancelled else { return CoreLogic.SyncSummary.soFar(banks: nil, investments: investments) }
        let banks = await CoreLogic.BankSync.runIfDue(in: ctx)
        progress?.banks = banks
        if !Task.isCancelled {
            await AutomationRunner.run(ctx)
            // Rows inserted on the main context push via SaveObserver, but nudge the engine so
            // they leave the device on this run rather than the next save.
            await engine?.sendPendingChanges()
        }
        return CoreLogic.SyncSummary.text(banks: banks, investments: investments)
    }

    // Claude asked for it and the user (or an auto-apply switch) agreed: skip the interval, but
    // not a sync already out, which runs the automations itself.
    @MainActor
    static func runNow(_ ctx: ModelContext, connectionIds: [UUID]?) async {
        guard let signer = try? EBKeychain().loadSigner() else { return }
        let api = EBClient(tokenProvider: signer)
        await withBackgroundTask("ClaudeBankSync") {
            let ran: Void? = await CoreLogic.BankSync.runNow {
                if let connectionIds {
                    let wanted = Set(connectionIds)
                    for connection in (try? ctx.fetch(FetchDescriptor<Connection>())) ?? [] where wanted.contains(connection.id) {
                        _ = try? await CoreLogic.EBSync.sync(connection: connection, api: api, in: ctx)
                    }
                } else {
                    _ = await CoreLogic.EBSync.syncAll(api: api, in: ctx)
                }
            }
            if ran != nil { await AutomationRunner.run(ctx) }
        }
    }
}

// A foreground sync that the user backgrounds mid-run was suspended within seconds and left
// its rows un-post-processed; the assertion buys ~30s to finish. The work runs as a task of its
// own so that, when that time runs out, it can be cancelled and record the bank runs it cut
// short as cut off instead of leaving them running. Cancelling the caller cancels it too.
@MainActor
func withBackgroundTask<T: Sendable, E: Error>(
    _ name: String, _ body: @escaping @MainActor () async throws(E) -> T
) async throws(E) -> T {
    let work = Task { @MainActor () -> Result<T, E> in
        do throws(E) { return .success(try await body()) } catch { return .failure(error) }
    }
    let assertion = BackgroundAssertion(name) { work.cancel() }
    defer { assertion.end() }
    let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    return try result.get()
}

@MainActor
private final class BackgroundAssertion {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String, onExpiry: @escaping @MainActor @Sendable () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            onExpiry()
            // A moment on the main thread for the cancelled work to save what it cut short, ending
            // well inside the time left: an assertion held past it gets the app killed.
            let grace = min(1, UIApplication.shared.backgroundTimeRemaining - 1)
            guard grace > 0 else { return end() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(grace))
                end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

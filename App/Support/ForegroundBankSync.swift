import Foundation
import SwiftData
import Synchronization
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
    // The steps done so far, for the Shortcuts action's answer when it can't wait for the rest,
    // and on iOS 27 what the action shows on the Lock Screen while it runs.
    @MainActor
    final class Steps {
        var investments: CoreLogic.InvestmentRefresh.Outcome?
        var banks: CoreLogic.SyncSummary.Banks?
        var snapshotAtDeadline: Task<Void, Never>?
        let shown: ShownProgress?
        let cutOff = CoreLogic.CutOff()
        private(set) var started = false
        private(set) var cancelled = false
        private var run: Task<String, Never>?

        init(showing progress: Foundation.Progress? = nil) {
            shown = progress.map(ShownProgress.init)
        }

        var soFar: String { CoreLogic.SyncSummary.soFar(banks: banks, investments: investments) }

        // iOS can end the action before the run starts, which then starts cancelled.
        func cancel() {
            cancelled = true
            run?.cancel()
        }

        // Cancels the run and gives it a second to record the banks it cut off, like the grace on
        // the 25-second path. Answers with the run's own summary if it ends in time.
        func stop() async -> String {
            if !cancelled { cutOff.note("iOS ended the Shortcuts action") }
            cancel()
            guard let run else { return soFar }
            return await CoreLogic.Deadline.value(of: run, by: .now + .seconds(1)) ?? soFar
        }

        fileprivate func start(_ run: Task<String, Never>) {
            started = true
            self.run = run
            if cancelled { run.cancel() }
        }
    }

    // iOS 27 lets the action run to the end while it reports its progress, which iOS shows on the
    // Lock Screen, and can end one whose progress stalls. One bank can take a minute or more, so
    // besides each step the bar inches on every few seconds while a step is out, never past where
    // that step ends.
    @MainActor
    final class ShownProgress {
        private let progress: Foundation.Progress
        private var ceiling: Int64 = 0
        private var ticker: Task<Void, Never>?

        init(_ progress: Foundation.Progress) { self.progress = progress }

        func investments() { step("Refreshing investments", from: 0, to: 30) }

        // The banks run side by side, so the slowest sets how long this lasts: the bar can inch
        // through the whole stretch, and each bank that finishes moves it at least to its share.
        func banks(done: Int, of total: Int) {
            guard total > 0 else { return }
            step("Syncing banks", detail: "\(done) of \(total)", from: Int64(30 + 60 * done / total), to: 90)
        }

        func saving() { step("Saving", from: 90, to: 100) }

        func finish() {
            guard let ticker else { return }
            ticker.cancel()
            progress.completedUnitCount = progress.totalUnitCount
        }

        // Started by the first step, so an action refused the extra time never shows a bar.
        private func step(_ what: String, detail: String? = nil, from: Int64, to: Int64) {
            if ticker == nil {
                progress.totalUnitCount = 100
                ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        guard let self else { return }
                        self.inch()
                    }
                }
            }
            progress.localizedDescription = what
            progress.localizedAdditionalDescription = detail
            progress.completedUnitCount = max(from, progress.completedUnitCount)
            ceiling = to - 1
        }

        private func inch() {
            if progress.completedUnitCount < ceiling { progress.completedUnitCount += 1 }
        }
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
        let steps = Steps()
        let run = Task { @MainActor in
            await withBackgroundTask("SyncAndRefresh") {
                let summary = await refresh(ctx, engine: engine, steps: steps)
                if !Task.isCancelled {
                    // After the write at the deadline, so the older snapshot can't land last; forced
                    // past the 30-second pause that write started. An unchanged one is still skipped.
                    await steps.snapshotAtDeadline?.value
                    await ClaudeBridge.exportSnapshot(ctx, force: true)
                }
                return summary
            }
        }
        if let summary = await CoreLogic.Deadline.value(of: run, by: deadline) { return summary }
        // What's done so far reaches the Mac now, in case iOS stops the rest.
        steps.snapshotAtDeadline = Task { await ClaudeBridge.exportSnapshot(ctx) }
        return steps.soFar
    }

    // iOS 27: the whole run inside the action, so its answer covers the banks too. No UIKit
    // background task: its 30 seconds would cut the run short. iOS ending the action cancels the
    // run through `steps`, which then records the banks it cut off, as at the deadline.
    @MainActor
    static func syncAndRefresh(_ ctx: ModelContext, engine: CloudKitSyncEngine?, steps: Steps) async -> String {
        let run = CoreLogic.CutOff.$reason.withValue(steps.cutOff) {
            Task { @MainActor in await refresh(ctx, engine: engine, steps: steps) }
        }
        steps.start(run)
        let cutOff = steps.cutOff
        let summary = await withTaskCancellationHandler { await run.value } onCancel: {
            cutOff.note("the Shortcuts action's task was cancelled")
            run.cancel()
        }
        steps.shown?.finish()
        await ClaudeBridge.exportSnapshot(ctx, force: true)
        return summary
    }

    // The foreground hook and the Shortcuts action share this: investments, then banks unless
    // they were tried in the last 15 minutes, the automations that follow every sync, and a push.
    // Returns what it did in a line, for the action's answer.
    @MainActor
    private static func refresh(_ ctx: ModelContext, engine: CloudKitSyncEngine?, steps: Steps? = nil) async -> String {
        // First, and pushed straight away, so the values leave the phone even when a bank runs
        // long. Independent of Enable Banking: brokers and crypto have their own sources, and an
        // unconfigured bank connection shouldn't stop them refreshing. The refresh is a task of its
        // own that outlives its callers, so running out of background time stops it explicitly.
        steps?.shown?.investments()
        let investments = await withTaskCancellationHandler {
            await CoreLogic.InvestmentRefresh.run(in: ctx)
        } onCancel: {
            Task { @MainActor in CoreLogic.InvestmentRefresh.cancel() }
        }
        steps?.investments = investments
        // SaveObserver has queued the values; the nudge doesn't hold the banks up on CloudKit.
        Task { await engine?.sendPendingChanges() }
        // Out of background time: the rest waits for the next run.
        guard !Task.isCancelled else { return CoreLogic.SyncSummary.soFar(banks: nil, investments: investments) }
        let banks = await CoreLogic.BankSync.runIfDue(in: ctx, banksDone: { steps?.shown?.banks(done: $0, of: $1) })
        steps?.banks = banks
        if !Task.isCancelled {
            steps?.shown?.saving()
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
// short as cut off, and why, instead of leaving them running. Cancelling the caller cancels it too.
@MainActor
func withBackgroundTask<T: Sendable, E: Error>(
    _ name: String, _ body: @escaping @MainActor () async throws(E) -> T
) async throws(E) -> T {
    let cutOff = CoreLogic.CutOff.reason ?? CoreLogic.CutOff()
    let work = CoreLogic.CutOff.$reason.withValue(cutOff) {
        Task { @MainActor () -> Result<T, E> in
            do throws(E) { return .success(try await body()) } catch { return .failure(error) }
        }
    }
    let assertion = BackgroundAssertion(name) {
        cutOff.note("iOS ended the app's background time")
        work.cancel()
    }
    defer { assertion.end() }
    let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    return try result.get()
}

// Ended once, by whichever comes first: the work finishing or the grace after expiry.
private final class BackgroundAssertion: Sendable {
    private let app: UIApplication
    private let id = Mutex(UIBackgroundTaskIdentifier.invalid)

    @MainActor
    init(_ name: String, onExpiry: @escaping @MainActor @Sendable () -> Void) {
        app = UIApplication.shared
        let begun = app.beginBackgroundTask(withName: name) { [self] in
            onExpiry()
            // A moment for the cancelled work to save what it cut short. Timed off the main thread,
            // so a busy main thread can't hold the assertion past its time, which gets the app killed.
            let grace = min(1, app.backgroundTimeRemaining - 2)
            guard grace > 0 else { return end() }
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { self.end() }
        }
        id.withLock { $0 = begun }
    }

    func end() {
        let ending = id.withLock { current in
            defer { current = .invalid }
            return current
        }
        if ending != .invalid { app.endBackgroundTask(ending) }
    }
}

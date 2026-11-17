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
    @MainActor
    static func runIfDue(_ ctx: ModelContext, engine: CloudKitSyncEngine?) async {
        // The Wallet automation launches the app in the background to run the quick-add
        // intent; a bank sync started there is suspended seconds later and shows up as an
        // "abandoned" run, having also burned the 15-minute window for the real foreground.
        guard UIApplication.shared.applicationState != .background else { return }
        guard CoreLogic.BankSyncThrottle().isDue(), !CoreLogic.BankSync.isRunning else { return }
        await syncAndRefresh(ctx, engine: engine)
    }

    // The foreground hook and the Shortcuts action share this: banks unless they synced in the
    // last 15 minutes, then investments, the automations that follow every sync, and a push.
    // Returns what it did in a line, for the action's answer.
    @MainActor @discardableResult
    static func syncAndRefresh(_ ctx: ModelContext, engine: CloudKitSyncEngine?) async -> String {
        await withBackgroundTask("ForegroundBankSync") {
            let banks = await CoreLogic.BankSync.runIfDue(in: ctx)
            // Independent of Enable Banking: brokers and crypto have their own sources, and an
            // unconfigured bank connection shouldn't stop them refreshing.
            let investments = await CoreLogic.InvestmentRefresh.run(in: ctx)
            await AutomationRunner.run(ctx)
            // Rows inserted on the main context push via SaveObserver, but nudge the engine so
            // they leave the device on this run rather than the next save.
            await engine?.sendPendingChanges()
            return CoreLogic.SyncSummary.text(banks: banks, investments: investments)
        }
    }

    // Claude asked for it and the user (or an auto-apply switch) agreed: skip the throttle,
    // but count the run against it.
    @MainActor
    static func runNow(_ ctx: ModelContext, connectionIds: [UUID]?) async {
        guard let signer = try? EBKeychain().loadSigner() else { return }
        CoreLogic.BankSyncThrottle().record()
        let api = EBClient(tokenProvider: signer)
        await withBackgroundTask("ClaudeBankSync") {
            if let connectionIds {
                let wanted = Set(connectionIds)
                for connection in (try? ctx.fetch(FetchDescriptor<Connection>())) ?? [] where wanted.contains(connection.id) {
                    _ = try? await CoreLogic.EBSync.sync(connection: connection, api: api, in: ctx)
                }
            } else {
                _ = await CoreLogic.EBSync.syncAll(api: api, in: ctx)
            }
            await AutomationRunner.run(ctx)
        }
    }
}

// A foreground sync that the user backgrounds mid-run was suspended within seconds and left
// its rows un-post-processed; the assertion buys ~30s to finish.
@MainActor
func withBackgroundTask<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
    nonisolated(unsafe) var id = UIBackgroundTaskIdentifier.invalid
    id = UIApplication.shared.beginBackgroundTask(withName: name) {
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
    defer { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
    return try await body()
}

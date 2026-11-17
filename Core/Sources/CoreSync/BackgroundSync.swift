import Foundation

#if os(iOS) || os(visionOS)
import BackgroundTasks
import SwiftData
import CoreLogic

public enum BackgroundSync {
    public static let taskIdentifier = "com.uliseis.odysseyfinance.refresh"
    // An app refresh task: about 30 seconds, but iOS runs those far more often than processing
    // tasks, which mostly wait for the phone to be charging. Investments only.
    public static let investmentsTaskIdentifier = "com.uliseis.odysseyfinance.investments"

    // App-level work that should follow a background bank sync (automations). CoreSync
    // can't see the App target, so the App installs it at launch.
    @MainActor public static var afterSync: (@MainActor (ModelContainer) async -> Void)?

    @MainActor
    public static func register(engine: CloudKitSyncEngine) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { @Sendable task in
            // Runs on BGTaskScheduler's queue; a closure inheriting register's MainActor
            // isolation trapped there on every launch. handle hops to the main actor itself.
            handle(task: task, engine: engine)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: investmentsTaskIdentifier,
            using: nil
        ) { @Sendable task in
            handleInvestments(task: task, engine: engine)
        }
    }

    public static func schedule(earliestBeginIn seconds: TimeInterval = 3_600) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    public static func scheduleInvestments() {
        let request = BGAppRefreshTaskRequest(identifier: investmentsTaskIdentifier)
        request.earliestBeginDate = CoreLogic.InvestmentRefresh.nextBackgroundRun(after: .now)
        try? BGTaskScheduler.shared.submit(request)
    }

    // BGTask is non-Sendable but its methods are safe to call across threads; carry it
    // over the actor hop explicitly. setTaskCompleted is reported from a single MainActor
    // site (exactly once); expirationHandler captures only the Sendable work handle.
    private struct TaskBox: @unchecked Sendable { let task: BGTask }

    // A background launch may never show the scene whose task starts sync, and saves made
    // before the engine starts are never queued for CloudKit. Each handler starts it first
    // (the App only registers these when CloudKit is available, so start can't trap).
    private static func handle(task: BGTask, engine: CloudKitSyncEngine) {
        let box = TaskBox(task: task)
        let work = Task { @MainActor in
            try? engine.start()
            await syncEnableBanking(engine.modelContainer)
            // Same order as the foreground sync, so the push below carries the valuations too.
            await refreshInvestments(engine.modelContainer)
            await afterSync?(engine.modelContainer)
            await engine.fetchOnLaunch()
            await engine.sendPendingChanges()
            schedule()
            box.task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    private static func handleInvestments(task: BGTask, engine: CloudKitSyncEngine) {
        let box = TaskBox(task: task)
        let work = Task { @MainActor in
            // First, so a run that expires still has the next one booked.
            scheduleInvestments()
            try? engine.start()
            await refreshInvestments(engine.modelContainer)
            await engine.sendPendingChanges()
            box.task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    // The refresh runs as a task of its own that outlives its callers, so an expiring
    // background task stops it explicitly; otherwise setTaskCompleted would wait for it.
    @MainActor
    private static func refreshInvestments(_ container: ModelContainer) async {
        guard !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            _ = await CoreLogic.InvestmentRefresh.run(in: container.mainContext)
        } onCancel: {
            Task { @MainActor in CoreLogic.InvestmentRefresh.cancel() }
        }
    }

    // Pull bank transactions before the CloudKit push so new ones ride out the same run.
    // Writes to mainContext → SaveObserver enqueues the inserts for push. Dedupe is on
    // (accountId, externalId) in EBSync, so replays insert nothing. Skips banks synced in the
    // last 6 hours, and quietly when the key is absent or unreadable (not yet unlocked since
    // boot): the next run that can read it syncs.
    @MainActor
    private static func syncEnableBanking(_ container: ModelContainer) async {
        _ = await CoreLogic.BankSync.runIfDue(
            in: container.mainContext, every: CoreLogic.BankSyncThrottle.backgroundInterval)
    }
}

#else

public enum BackgroundSync {
    public static let taskIdentifier = "com.uliseis.odysseyfinance.refresh"
    public static let investmentsTaskIdentifier = "com.uliseis.odysseyfinance.investments"

    @MainActor
    public static func register(engine: CloudKitSyncEngine) {}

    public static func schedule(earliestBeginIn seconds: TimeInterval = 3_600) {}

    public static func scheduleInvestments() {}
}

#endif

import SwiftUI
import SwiftData
import UserNotifications
import CoreModel
import CoreLogic
import CoreSync

private let iCloudContainerID = "iCloud.com.uliseis.odysseyfinance"

@main
struct OdysseyFinanceApp: App {
    let modelContainer: ModelContainer
    @State private var syncEngine: CloudKitSyncEngine

    init() {
        // SwiftData's default store lives in Application Support, which doesn't exist on a
        // fresh install — SwiftData recovers but logs a wall of CoreData errors first.
        // Create it up front so first launch is clean.
        _ = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)

        let container: ModelContainer
        do {
            let schema = Schema(CoreModelSchema.allTypes)
            // DO NOT change cloudKitDatabase. SwiftData drops @Attribute(.unique) the moment
            // CloudKit mirroring is enabled, which would force a destructive migration on
            // every model. Sync to iCloud is handled out-of-band by CoreSync (CKSyncEngine).
            let config: ModelConfiguration
            #if DEBUG
            if let dev = DevStore.url {
                config = ModelConfiguration(schema: schema, url: dev, cloudKitDatabase: .none)
            } else {
                config = ModelConfiguration(
                    schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none
                )
            }
            #else
            config = ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none
            )
            #endif
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer init failed: \(error)")
        }
        self.modelContainer = container

        let store: SyncStateStore
        do {
            store = SyncStateStore(fileURL: try SyncStateStore.defaultLocation())
        } catch {
            fatalError("CoreSync state store init failed: \(error)")
        }
        let engine = CloudKitSyncEngine(
            containerIdentifier: iCloudContainerID,
            modelContainer: container,
            stateStore: store
        )
        _syncEngine = State(initialValue: engine)

        // BGTaskScheduler.register MUST be called exactly once per identifier before the
        // app finishes launching. Done here, in init, before Scene body is evaluated.
        // Skip when CloudKit is unavailable (unsigned dev build) — see CloudKitGate.
        if CloudKitGate.isAvailable {
            BackgroundSync.register(engine: engine)
        }
        BackgroundSync.afterSync = { container in
            await AutomationRunner.run(container.mainContext)
            await ClaudeBridge.exchange(container.mainContext)
        }
        NotificationResponder.shared.container = container
        NotificationResponder.shared.engine = engine
        UNUserNotificationCenter.current().delegate = NotificationResponder.shared
        AutomationNotifications.registerCategories()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(syncEngine)
                .task {
                    // CKContainer init traps without the iCloud entitlement (unsigned dev
                    // builds). Only start sync when CloudKit is actually provisioned; the app
                    // runs fully locally otherwise.
                    // Cold-launch drain of App Intent captures; foreground-resume is handled
                    // separately in RootView.onChange(scenePhase == .active).
                    guard CloudKitGate.isAvailable else {
                        QuickAddDrain.run(modelContainer.mainContext, engine: nil)
                        // These mutate data, so they get a dry run against a copy of the real
                        // store in the simulator before they are ever pointed at the phone.
                        // Behind the CloudKit gate they could only ever be tested in anger.
                        runDebugRoutines()
                        await ClaudeBridge.exchange(modelContainer.mainContext)
                        return
                    }
                    do {
                        try syncEngine.start()
                        // After start() so the created rows enqueue for CloudKit push.
                        QuickAddDrain.run(modelContainer.mainContext, engine: syncEngine)
                        // Data cutover: a store copied into the app container fires no save
                        // events, so its rows must be enqueued explicitly, once. Set this env
                        // var on the single cutover launch only (devicectl --environment-variables).
                        if ProcessInfo.processInfo.environment["OFSYNC_SEED_INITIAL_PUSH"] == "1" {
                            syncEngine.seedInitialPush()
                        }
                        // One-time repair after the cleared-fields fix: re-push every record
                        // so CloudKit drops values the device cleared, with ties going to the device.
                        if ProcessInfo.processInfo.environment["OFSYNC_REPAIR_PUSH"] == "1" {
                            syncEngine.seedInitialPush(preferLocalOnTie: true)
                        }
                        // After start() so anything they write enqueues for CloudKit push.
                        runDebugRoutines()
                    } catch {
                        // Engine may fail to start if iCloud isn't available; the app still works
                        // locally. Log and carry on; next launch retries.
                        print("CoreSync start failed: \(error)")
                    }
                    BackgroundSync.schedule()
                    BackgroundSync.scheduleInvestments()
                    // Cold launch: scenePhase never transitions into the initial .active.
                    await ForegroundBankSync.runIfDue(
                        modelContainer.mainContext, engine: syncEngine)
                    await ClaudeBridge.exchange(modelContainer.mainContext)
                }
        }
        .modelContainer(modelContainer)
    }

    // Env-gated one-shot data routines. Each checks its own flag and is idempotent.
    @MainActor
    private func runDebugRoutines() {
        #if DEBUG
        EBWatermarkRewind.runIfRequested(modelContainer)
        // OFOPEN_TX=<uuid>: exercise the notification deep link without a notification.
        if let raw = ProcessInfo.processInfo.environment["OFOPEN_TX"], let id = UUID(uuidString: raw) {
            PendingNavigation.shared.transactionId = id
        }
        #endif
    }
}

// DEBUG-only screenshot/UI-test hook: launch with UITEST_DISABLE_AUTH=1 to skip the
// biometric gate. Never compiled into release builds.
#if DEBUG
let authGateBypassed = ProcessInfo.processInfo.environment["UITEST_DISABLE_AUTH"] == "1"
// Show the locked screen without firing biometrics, so the lock UI can be captured.
let authShowLockOnly = ProcessInfo.processInfo.environment["UITEST_SHOW_LOCK"] == "1"
#else
let authGateBypassed = false
let authShowLockOnly = false
#endif

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(CloudKitSyncEngine.self) private var syncEngine
    @AppStorage(SecuritySettings.requireUnlockKey) private var requireUnlock = true
    @State private var appLock = AppLock()
    @State private var returningFromBackground = false
    @State private var bankLinkMessage: String?
    @State private var claudeInbox = ClaudeInbox.shared

    private var lockEnabled: Bool { requireUnlock && !authGateBypassed }

    var body: some View {
        // Stays mounted while locked, so coming back lands where you left off.
        RootTabView()
            .onAppear {
                guard lockEnabled else { return }
                appLock.lock()
                if !authShowLockOnly { appLock.authenticate() }
            }
            .task(id: appLock.isLocked) {
                if !appLock.isLocked { await syncEngine.fetchOnLaunch() }
            }
            // Bank redirects that came back through Safari. Handled here, at the root, so
            // the result shows wherever the user is once they unlock.
            .onOpenURL { url in Task { await completeBankLink(url) } }
            .alert(
                "Bank Connection",
                isPresented: Binding(get: { bankLinkMessage != nil }, set: { if !$0 { bankLinkMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(bankLinkMessage ?? "")
            }
            .sheet(item: $claudeInbox.current) { ClaudeReviewView(item: $0) }
            .onChange(of: scenePhase) { _, phase in
                // Materialize charges captured by the App Intent while the app was suspended.
                // Only once the engine is up, so we don't race start() on cold launch (the
                // launch-time drain handles that case).
                if phase == .active, syncEngine.isRunning {
                    QuickAddDrain.run(modelContext, engine: syncEngine)
                }
                // Refresh bank data on every foreground (throttled). The BGProcessingTask alone
                // left the app showing stale transactions until Connections was tapped by hand.
                if phase == .active {
                    Task {
                        await ForegroundBankSync.runIfDue(modelContext, engine: syncEngine)
                        await ClaudeBridge.exchange(modelContext)
                    }
                }
                // Face ID's own prompt also takes the scene inactive and back; only a return
                // from the background asks again, so a cancelled prompt doesn't loop.
                if phase == .active, returningFromBackground {
                    returningFromBackground = false
                    if !authShowLockOnly { appLock.authenticate() }
                }
                if phase == .background {
                    returningFromBackground = true
                    if lockEnabled { appLock.lock() }
                }
            }
    }

    private func completeBankLink(_ url: URL) async {
        do {
            guard let outcome = try await BankLink.completeExternal(url, in: modelContext) else { return }
            bankLinkMessage = outcome.authorized
                ? "\(outcome.institution) connected. \(pluralized(outcome.accountCount, "account")) authorized."
                : "\(outcome.institution): authorization is still pending at the bank."
        } catch CoreLogic.EBConnect.CallbackError.bankReported(let reason) {
            bankLinkMessage = "The bank declined the connection (\(reason))."
        } catch {
            bankLinkMessage = "Couldn’t finish connecting the bank.\n\n\(error)"
        }
    }
}

struct LockScreen: View {
    let error: String?
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Theme.heroFill.ignoresSafeArea()

            VStack(spacing: Theme.Space.l) {
                Spacer()
                CompassMark(size: 96, tint: Theme.heroAccent)
                VStack(spacing: Theme.Space.xs) {
                    Text("Odyssey Finance")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Label("Locked", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                Spacer()
                Button("Unlock", systemImage: "faceid", action: onUnlock)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.prominentFill)
                    .controlSize(.large)
            }
            .padding(Theme.Space.l)
            .padding(.bottom, Theme.Space.xl)
        }
    }
}


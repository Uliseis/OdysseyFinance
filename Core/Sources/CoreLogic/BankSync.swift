import Foundation
import SwiftData
import CoreModel
import CoreIntegrations

extension CoreLogic {
    // One throttle for every bank sync: the foreground, the Shortcuts action and the background
    // task. EBClient sends no PSU headers, so each call counts against the banks' allowance of
    // about four unattended accesses a day per account.
    public struct BankSyncThrottle {
        // Opening the app twice in a row syncs once.
        public static let interval: TimeInterval = 15 * 60
        // iOS picks when the background task runs; a few runs a day would use up the allowance.
        public static let backgroundInterval: TimeInterval = 6 * 3600
        // Where ForegroundBankSync kept it, so an update doesn't reset the pace.
        static let lastRunKey = "ForegroundBankSync.lastRunAt"

        private let defaults: UserDefaults

        public init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        public var lastRun: Date? {
            let t = defaults.double(forKey: Self.lastRunKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }

        public func isDue(every interval: TimeInterval = Self.interval, now: Date = .now) -> Bool {
            guard let lastRun else { return true }
            return now.timeIntervalSince(lastRun) >= interval
        }

        public func record(_ now: Date = .now) {
            defaults.set(now.timeIntervalSince1970, forKey: Self.lastRunKey)
        }
    }

    public enum BankSync {
        // While a sync is out, so no second one starts over it.
        @MainActor public private(set) static var isRunning = false

        // Only a sync that reached the banks and wasn't cut short uses up the interval: one that
        // couldn't read the key or was cancelled leaves it to the next caller.
        @MainActor
        public static func runIfDue(
            in ctx: ModelContext, every interval: TimeInterval = BankSyncThrottle.interval,
            throttle: BankSyncThrottle = BankSyncThrottle(),
            api makeAPI: () throws -> any EBSyncAPI = { EBClient(tokenProvider: try EBKeychain().loadSigner()) }
        ) async -> SyncSummary.Banks {
            let connections = (try? ctx.fetch(FetchDescriptor<Connection>())) ?? []
            guard connections.contains(where: { $0.connector == .enablebanking }) else {
                // Nothing to sync counts as a run, so the foreground keeps its 15-minute pace.
                throttle.record()
                return .notConnected
            }
            guard !isRunning else { return .busy }
            guard throttle.isDue(every: interval) else { return .recent }
            let api: any EBSyncAPI
            do {
                api = try makeAPI()
            } catch {
                return .noKey(locked: error as? EBKeyError == .keychain(errSecInteractionNotAllowed))
            }
            isRunning = true
            defer { isRunning = false }
            let results = await EBSync.syncAll(api: api, in: ctx)
            if !Task.isCancelled { throttle.record() }
            return .synced(EBSync.report(results, in: ctx))
        }
    }
}

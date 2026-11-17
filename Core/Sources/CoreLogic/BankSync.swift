import Foundation
import Security
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
        // Marked when a sync starts, so one killed mid-way doesn't have every later launch retry
        // straight away; one that finishes marks the full interval.
        static let provisional: TimeInterval = 5 * 60
        // Where ForegroundBankSync kept it, so an update doesn't reset the pace.
        static let lastRunKey = "ForegroundBankSync.lastRunAt"
        static let startedKey = "BankSyncThrottle.startedAt"

        private let defaults: UserDefaults

        public init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        public var lastRun: Date? { date(Self.lastRunKey) }

        public func isDue(every interval: TimeInterval = Self.interval, now: Date = .now) -> Bool {
            if let started = date(Self.startedKey), now.timeIntervalSince(started) < Self.provisional {
                return false
            }
            guard let lastRun else { return true }
            return now.timeIntervalSince(lastRun) >= interval
        }

        public func markStarted(_ now: Date = .now) {
            defaults.set(now.timeIntervalSince1970, forKey: Self.startedKey)
        }

        public func record(_ now: Date = .now) {
            defaults.set(now.timeIntervalSince1970, forKey: Self.lastRunKey)
        }

        private func date(_ key: String) -> Date? {
            let t = defaults.double(forKey: key)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
    }

    public enum BankSync {
        // While a sync is out, so no second one starts over it.
        @MainActor public private(set) static var isRunning = false

        // Only a sync that reached the banks and wasn't cut short uses up the interval: one that
        // couldn't read the key leaves it to the next caller, one cut short to a caller a few
        // minutes later.
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
                return .noKey(keyProblem(error))
            }
            guard let results = await runNow(throttle: throttle, { await EBSync.syncAll(api: api, in: ctx) })
            else { return .busy }
            return .synced(EBSync.report(results, in: ctx))
        }

        // A sync someone asked for (a tap in Settings, or Claude with the user's go-ahead) skips
        // the interval, but never starts over one already out: nil then. A run that wasn't cut
        // short counts for the others, even when the bank failed it.
        @MainActor
        public static func runNow<T>(
            throttle: BankSyncThrottle = BankSyncThrottle(), _ sync: () async throws -> T
        ) async rethrows -> T? {
            guard !isRunning else { return nil }
            isRunning = true
            defer { isRunning = false }
            throttle.markStarted()
            defer { if !Task.isCancelled { throttle.record() } }
            return try await sync()
        }

        // Worded like the investments' key problems: only a key that isn't there needs adding.
        static func keyProblem(_ error: any Error) -> String {
            switch error as? EBKeyError {
            case .notFound: "Add the Enable Banking key in Settings"
            case .keychain(errSecInteractionNotAllowed): "The bank key can't be read while the iPhone is locked"
            default: "The bank key couldn't be read (\(error))"
            }
        }
    }
}

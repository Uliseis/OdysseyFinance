import XCTest
import SwiftData
import CoreModel
@testable import CoreLogic
@testable import CoreIntegrations

@MainActor
final class BankSyncTests: XCTestCase {
    private typealias Throttle = CoreLogic.BankSyncThrottle
    private typealias S = TransferTestSupport

    private var suite = ""
    private var defaults: UserDefaults!
    private var throttle: Throttle { Throttle(defaults: defaults) }

    override func setUp() async throws {
        suite = "BankSyncTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    // A bank that answers with an authorized session holding no accounts.
    private final class StubAPI: EBSyncAPI, @unchecked Sendable {
        var sessions = 0
        var whileSessionInFlight: (@MainActor () async -> Void)?

        func getSession(_ sessionId: String) async throws -> SessionResponse {
            sessions += 1
            if let whileSessionInFlight { await whileSessionInFlight() }
            return try EBJSON.decoder.decode(SessionResponse.self, from: Data("""
            {"status": "AUTHORIZED", "accounts": [], "accounts_data": [],
             "access": {"accounts": null, "balances": true, "transactions": true,
                        "valid_until": "2026-09-08T10:00:00Z"},
             "aspsp": {"name": "Example Bank", "country": "ES"}, "closed": null}
            """.utf8))
        }
        func getAccountDetails(_ accountUid: String) async throws -> AccountDetails { fatalError() }
        func getAccountBalances(_ accountUid: String) async throws -> BalancesResponse { fatalError() }
        func getAccountTransactions(_ accountUid: String, query: EBTransactionQuery) async throws -> TransactionsResponse {
            fatalError()
        }
    }

    private func connectedContext() throws -> ModelContext {
        let ctx = try S.makeContext()
        ctx.insert(Connection(connector: .enablebanking, institutionName: "Example Bank",
                              sessionId: "session", status: .active))
        try ctx.save()
        return ctx
    }

    private func run(_ ctx: ModelContext, every interval: TimeInterval = Throttle.interval,
                     api: StubAPI = StubAPI()) async -> CoreLogic.SyncSummary.Banks {
        await CoreLogic.BankSync.runIfDue(in: ctx, every: interval, throttle: throttle, api: { api })
    }

    // MARK: Throttle

    func testTheForegroundWaitsAQuarterOfAnHourAndTheBackgroundSixHours() {
        // Whole seconds, so the stored mark reads back exactly.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(throttle.isDue(now: now))
        throttle.record(now)
        XCTAssertFalse(throttle.isDue(now: now.addingTimeInterval(14 * 60)))
        XCTAssertTrue(throttle.isDue(now: now.addingTimeInterval(15 * 60)))
        XCTAssertFalse(throttle.isDue(every: Throttle.backgroundInterval, now: now.addingTimeInterval(5 * 3600)))
        XCTAssertTrue(throttle.isDue(every: Throttle.backgroundInterval, now: now.addingTimeInterval(6 * 3600)))
    }

    func testASyncThatStartsHoldsTheBanksOffForAFewMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        throttle.markStarted(now)
        XCTAssertFalse(throttle.isDue(now: now.addingTimeInterval(4 * 60)))
        XCTAssertTrue(throttle.isDue(now: now.addingTimeInterval(5 * 60)),
                      "a run killed mid-way doesn't hold them off for the full interval")
        XCTAssertTrue(throttle.isDue(every: Throttle.backgroundInterval, now: now.addingTimeInterval(5 * 60)))
        throttle.record(now.addingTimeInterval(60))
        XCTAssertFalse(throttle.isDue(now: now.addingTimeInterval(10 * 60)), "finishing extends it to the full interval")
        XCTAssertTrue(throttle.isDue(now: now.addingTimeInterval(16 * 60)))
    }

    func testItKeepsThePaceTheForegroundSyncAlreadySet() throws {
        let now = Date.now
        defaults.set(now.timeIntervalSince1970, forKey: "ForegroundBankSync.lastRunAt")
        XCTAssertEqual(try XCTUnwrap(throttle.lastRun).timeIntervalSince(now), 0, accuracy: 0.001)
    }

    // MARK: Running

    func testASyncThatReachedTheBanksUsesUpTheInterval() async throws {
        let ctx = try connectedContext()
        let api = StubAPI()
        api.whileSessionInFlight = { [self] in
            XCTAssertNil(throttle.lastRun)
            XCTAssertFalse(throttle.isDue(every: 0), "marked as started before the first call to a bank")
        }
        let banks = await run(ctx, api: api)
        XCTAssertEqual(banks, .synced(CoreLogic.EBSync.Report(synced: 1)))
        XCTAssertEqual(api.sessions, 1)
        XCTAssertNotNil(throttle.lastRun)
        XCTAssertFalse(throttle.isDue())
    }

    func testARecentSyncSkipsTheBanks() async throws {
        let ctx = try connectedContext()
        throttle.record(.now.addingTimeInterval(-5 * 60))
        let api = StubAPI()
        let banks = await run(ctx, api: api)
        XCTAssertEqual(banks, .recent)
        XCTAssertEqual(api.sessions, 0)
    }

    func testTheBackgroundSkipsBanksSyncedInTheLastSixHours() async throws {
        let ctx = try connectedContext()
        throttle.record(.now.addingTimeInterval(-2 * 3600))
        let api = StubAPI()
        let background = await run(ctx, every: Throttle.backgroundInterval, api: api)
        XCTAssertEqual(background, .recent)
        XCTAssertEqual(api.sessions, 0)
        let foreground = await run(ctx, api: api)
        XCTAssertEqual(foreground, .synced(CoreLogic.EBSync.Report(synced: 1)),
                       "the foreground's quarter of an hour has passed")
    }

    func testASyncAlreadyOutIsNotStartedAgain() async throws {
        let ctx = try connectedContext()
        let api = StubAPI()
        var second: CoreLogic.SyncSummary.Banks?
        api.whileSessionInFlight = { [self] in
            second = await CoreLogic.BankSync.runIfDue(in: ctx, every: 0, throttle: throttle, api: { StubAPI() })
        }
        _ = await run(ctx, api: api)
        XCTAssertEqual(second, .busy)
    }

    func testAKeyThatCantBeReadLeavesTheSyncToTheNextCaller() async throws {
        let ctx = try connectedContext()
        let banks = await CoreLogic.BankSync.runIfDue(in: ctx, throttle: throttle, api: { throw EBKeyError.notFound })
        XCTAssertEqual(banks, .noKey("Add the Enable Banking key in Settings"))
        XCTAssertNil(throttle.lastRun)
        XCTAssertTrue(throttle.isDue())
    }

    func testAKeyThatCantBeReadSaysWhy() {
        XCTAssertEqual(CoreLogic.BankSync.keyProblem(EBKeyError.notFound),
                       "Add the Enable Banking key in Settings")
        XCTAssertEqual(CoreLogic.BankSync.keyProblem(EBKeyError.keychain(errSecInteractionNotAllowed)),
                       "The bank key can't be read until the iPhone is unlocked after a restart")
        XCTAssertEqual(CoreLogic.BankSync.keyProblem(EBKeyError.keychain(errSecAuthFailed)),
                       "The bank key couldn't be read (keychain(-25293))", "not a key to add again")
        XCTAssertEqual(CoreLogic.BankSync.keyProblem(EBKeyError.badPEM),
                       "The bank key couldn't be read (badPEM)")
    }

    func testACancelledSyncLeavesTheSyncToTheNextCaller() async throws {
        let ctx = try connectedContext()
        let task = Task { await run(ctx) }
        task.cancel()
        _ = await task.value
        XCTAssertNil(throttle.lastRun)
        XCTAssertTrue(throttle.isDue(now: .now.addingTimeInterval(5 * 60)))
    }

    func testNoBankConnectionStillKeepsThePace() async throws {
        let ctx = try S.makeContext()
        let banks = await run(ctx)
        XCTAssertEqual(banks, .notConnected)
        XCTAssertFalse(throttle.isDue())
    }

    // MARK: Asked for (a tap in Settings, or Claude with the user's go-ahead)

    func testASyncAskedForSkipsTheIntervalAndCountsAsARun() async {
        // Whole seconds, so the stored mark reads back exactly.
        let earlier = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 - 60).rounded())
        throttle.record(earlier)
        let result = await CoreLogic.BankSync.runNow(throttle: throttle) { [self] in
            XCTAssertTrue(CoreLogic.BankSync.isRunning)
            XCTAssertFalse(throttle.isDue(every: 0), "marked as started before the first call to a bank")
            XCTAssertEqual(throttle.lastRun, earlier)
            return 7
        }
        XCTAssertEqual(result, 7)
        XCTAssertFalse(CoreLogic.BankSync.isRunning)
        XCTAssertGreaterThan(try XCTUnwrap(throttle.lastRun), earlier)
    }

    func testASyncAskedForWhileOneIsOutDoesntStart() async throws {
        let ctx = try connectedContext()
        let api = StubAPI()
        var asked: Int? = 0
        var started = false
        api.whileSessionInFlight = { [self] in
            asked = await CoreLogic.BankSync.runNow(throttle: throttle) {
                started = true
                return 1
            }
        }
        _ = await run(ctx, api: api)
        XCTAssertNil(asked, "it says the banks are already syncing")
        XCTAssertFalse(started)
    }

    func testTheOthersSeeASyncAskedForAsOut() async throws {
        let ctx = try connectedContext()
        let api = StubAPI()
        var banks: CoreLogic.SyncSummary.Banks?
        _ = await CoreLogic.BankSync.runNow(throttle: throttle) { [self] in
            banks = await CoreLogic.BankSync.runIfDue(in: ctx, every: 0, throttle: throttle, api: { api })
        }
        XCTAssertEqual(banks, .busy)
        XCTAssertEqual(api.sessions, 0)
    }

    func testASyncAskedForThatFailsStillCountsAsARun() async {
        struct BankDown: Error {}
        do {
            _ = try await CoreLogic.BankSync.runNow(throttle: throttle) { () async throws -> Int in throw BankDown() }
            XCTFail("expected the error to come through")
        } catch {
            XCTAssertTrue(error is BankDown)
        }
        XCTAssertNotNil(throttle.lastRun)
        XCTAssertFalse(CoreLogic.BankSync.isRunning)
    }

    func testACancelledSyncAskedForOnlyHoldsTheOthersOffBriefly() async {
        let task = Task { [self] in await CoreLogic.BankSync.runNow(throttle: throttle) { 1 } }
        task.cancel()
        _ = await task.value
        XCTAssertNil(throttle.lastRun)
        XCTAssertFalse(throttle.isDue())
        XCTAssertTrue(throttle.isDue(now: .now.addingTimeInterval(5 * 60)))
    }
}

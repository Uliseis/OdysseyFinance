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

    func testItKeepsThePaceTheForegroundSyncAlreadySet() throws {
        let now = Date.now
        defaults.set(now.timeIntervalSince1970, forKey: "ForegroundBankSync.lastRunAt")
        XCTAssertEqual(try XCTUnwrap(throttle.lastRun).timeIntervalSince(now), 0, accuracy: 0.001)
    }

    // MARK: Running

    func testASyncThatReachedTheBanksUsesUpTheInterval() async throws {
        let ctx = try connectedContext()
        let api = StubAPI()
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
        guard case .noKey = banks else { return XCTFail("expected noKey, got \(banks)") }
        XCTAssertNil(throttle.lastRun)
    }

    func testACancelledSyncLeavesTheSyncToTheNextCaller() async throws {
        let ctx = try connectedContext()
        let task = Task { await run(ctx) }
        task.cancel()
        _ = await task.value
        XCTAssertTrue(throttle.isDue())
    }

    func testNoBankConnectionStillKeepsThePace() async throws {
        let ctx = try S.makeContext()
        let banks = await run(ctx)
        XCTAssertEqual(banks, .notConnected)
        XCTAssertFalse(throttle.isDue())
    }
}

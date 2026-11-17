import XCTest
import SwiftData
@testable import CoreLogic
@testable import CoreModel
@testable import CoreIntegrations

// Stubbed EBSyncAPI driving the full sync orchestration without network.
@MainActor
final class EBSyncTests: XCTestCase {
    typealias S = TransferTestSupport
    typealias Sync = CoreLogic.EBSync

    private static let uid = "11111111-2222-3333-4444-555555555555"

    private final class StubAPI: EBSyncAPI, @unchecked Sendable {
        var session: SessionResponse
        var details: [String: AccountDetails] = [:]
        var balances: [String: BalancesResponse] = [:]
        var txPages: [String: [TransactionsResponse]] = [:]
        var sessionError: Error?
        var txError: Error?
        // What a request answers once its task is cancelled, as URLSession does.
        var sessionErrorIfCancelled: Error?
        var txErrorIfCancelled: Error?
        var lastTxQuery: EBTransactionQuery?
        var whileSessionInFlight: (@MainActor () -> Void)?

        init(session: SessionResponse) { self.session = session }

        func getSession(_ sessionId: String) async throws -> SessionResponse {
            if let whileSessionInFlight { await whileSessionInFlight() }
            if let sessionError { throw sessionError }
            if Task.isCancelled, let sessionErrorIfCancelled { throw sessionErrorIfCancelled }
            return session
        }
        func getAccountDetails(_ accountUid: String) async throws -> AccountDetails {
            details[accountUid]!
        }
        func getAccountBalances(_ accountUid: String) async throws -> BalancesResponse {
            balances[accountUid] ?? decode(#"{"balances": []}"#)
        }
        func getAccountTransactions(
            _ accountUid: String, query: EBTransactionQuery
        ) async throws -> TransactionsResponse {
            lastTxQuery = query
            if let txError { throw txError }
            if Task.isCancelled, let txErrorIfCancelled { throw txErrorIfCancelled }
            var pages = txPages[accountUid] ?? []
            guard !pages.isEmpty else { return decode(#"{"transactions": []}"#) }
            let page = pages.removeFirst()
            txPages[accountUid] = pages
            return page
        }
    }

    // MARK: - fixtures

    nonisolated private static func decode<T: Decodable>(_ json: String) -> T {
        try! EBJSON.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func decode<T: Decodable>(_ json: String) -> T { Self.decode(json) }

    // Mirrors the real GET /sessions/{id} shape: no session_id, slim accounts_data.
    private func makeSession(status: String = "AUTHORIZED",
                             uids: [String] = [EBSyncTests.uid]) -> SessionResponse {
        decode("""
        {
          "status": "\(status)",
          "accounts": [\(uids.map { #""\#($0)""# }.joined(separator: ","))],
          "accounts_data": [\(uids.map { #"{"uid": "\#($0)", "identification_hash": "h"}"# }.joined(separator: ","))],
          "access": {"accounts": null, "balances": true, "transactions": true,
                     "valid_until": "2026-09-08T10:00:00Z"},
          "aspsp": {"name": "Revolut", "country": "ES"},
          "closed": null
        }
        """)
    }

    private func details(iban: String? = "ES1234", name: String = "Main",
                         currency: String = "EUR") -> AccountDetails {
        decode("""
        {
          "name": "\(name)", "currency": "\(currency)"
          \(iban.map { #", "account_id": {"iban": "\#($0)"}"# } ?? "")
        }
        """)
    }

    private func balances(_ amount: String) -> BalancesResponse {
        decode("""
        {"balances": [{"name": "x", "balance_amount": {"currency": "EUR", "amount": "\(amount)"},
                       "balance_type": "CLBD"}]}
        """)
    }

    private func txPage(_ entries: [(ref: String, amount: String, indicator: String)],
                        continuation: String? = nil) -> TransactionsResponse {
        let txs = entries.map {
            """
            {"entry_reference": "\($0.ref)",
             "transaction_amount": {"currency": "EUR", "amount": "\($0.amount)"},
             "credit_debit_indicator": "\($0.indicator)",
             "status": "BOOK", "booking_date": "2026-06-01",
             "remittance_information": ["REF \($0.ref)"]}
            """
        }.joined(separator: ",")
        let cont = continuation.map { #", "continuation_key": "\#($0)""# } ?? ""
        return decode(#"{"transactions": [\#(txs)]\#(cont)}"#)
    }

    private func makeConnection(_ ctx: ModelContext, sessionId: String? = "sess-1") -> Connection {
        let conn = Connection(connector: .enablebanking, institutionName: "Revolut",
                              sessionId: sessionId, status: .active)
        ctx.insert(conn)
        try? ctx.save()
        return conn
    }

    private func makeLinkedAccount(_ ctx: ModelContext, connection: Connection,
                                   uid: String = EBSyncTests.uid) -> Account {
        let account = Account(connection: connection, externalId: uid, type: .bank,
                              institution: "Revolut", name: "Old Name", currency: "EUR",
                              iban: "ES1234")
        ctx.insert(account)
        try? ctx.save()
        return account
    }

    // MARK: - pure helpers

    func testComputeDateFrom() {
        let now = ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!
        XCTAssertEqual(Sync.computeDateFrom(lastSyncAt: nil, now: now), "2024-06-10")
        let recent = now.addingTimeInterval(-86_400)
        XCTAssertEqual(Sync.computeDateFrom(lastSyncAt: recent, now: now), "2026-06-02")
        let ancient = now.addingTimeInterval(-Double(900) * 86_400)
        XCTAssertEqual(Sync.computeDateFrom(lastSyncAt: ancient, now: now), "2024-06-10")
    }

    func testIsValidUid() {
        XCTAssertTrue(Sync.isValidUid(Self.uid))
        XCTAssertFalse(Sync.isValidUid(nil))
        XCTAssertFalse(Sync.isValidUid(""))
        XCTAssertFalse(Sync.isValidUid("undefined"))
        XCTAssertFalse(Sync.isValidUid("not-a-uuid"))
    }

    func testReapStaleRuns() throws {
        let ctx = try S.makeContext()
        let now = Date.now
        let stale = SyncRun(connector: .enablebanking, startedAt: now.addingTimeInterval(-1200))
        let fresh = SyncRun(connector: .enablebanking, startedAt: now.addingTimeInterval(-60))
        ctx.insert(stale); ctx.insert(fresh)
        try ctx.save()
        XCTAssertEqual(try Sync.reapStaleRuns(in: ctx, now: now), 1)
        XCTAssertEqual(stale.status, .error)
        XCTAssertEqual(stale.error, "abandoned")
        XCTAssertEqual(fresh.status, .running)
    }

    // MARK: - sync paths

    func testHappyPathInsertsAndDedupesTransactions() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        let account = makeLinkedAccount(ctx, connection: conn)

        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()
        api.balances[Self.uid] = balances("123.45")
        api.txPages[Self.uid] = [
            txPage([("r1", "10.00", "CRDT"), ("zero", "0", "CRDT")], continuation: "k1"),
            txPage([("r2", "-25.50", "DBIT")]),
        ]

        let result = try await Sync.sync(connection: conn, api: api, in: ctx)
        XCTAssertEqual(result.transactionsInserted, 2)
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.accountsTouched, 1)
        XCTAssertEqual(account.name, "Main")
        XCTAssertEqual(account.balance, Decimal(string: "123.45"))
        XCTAssertEqual(conn.status, .active)
        XCTAssertNotNil(conn.lastSyncAt)
        XCTAssertEqual(conn.expiresAt, ISO8601DateFormatter().date(from: "2026-09-08T10:00:00Z"))

        let runs = try ctx.fetch(FetchDescriptor<SyncRun>())
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .ok)
        XCTAssertEqual(runs.first?.insertedTransactions, 2)

        // EUR transactions get amountEur backfilled at rate 1.
        let txs = try ctx.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(txs.count, 2)
        XCTAssertTrue(txs.allSatisfy { $0.amountEur != nil })
        XCTAssertEqual(result.postProcess?.fxBackfilled, 2)

        // Re-run with the same pages: everything dedupes on (account, externalId).
        api.txPages[Self.uid] = [txPage([("r1", "10.00", "CRDT"), ("r2", "-25.50", "DBIT")])]
        let second = try await Sync.sync(connection: conn, api: api, in: ctx)
        XCTAssertEqual(second.transactionsInserted, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Transaction>()).count, 2)
    }

    // A timed-out account must not advance the watermark, or its missed window is skipped
    // for good once the failure outlasts the 7-day overlap.
    func testTimedOutAccountHoldsWatermarkSoNextRunRefetches() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        _ = makeLinkedAccount(ctx, connection: conn)
        conn.lastSyncAt = ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z")

        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()
        api.txError = URLError(.timedOut)

        let now = ISO8601DateFormatter().date(from: "2026-06-20T12:00:00Z")!
        let failed = try await Sync.sync(connection: conn, api: api, in: ctx, now: now)
        XCTAssertEqual(failed.errors.count, 1)
        XCTAssertEqual(conn.status, .error)
        XCTAssertEqual(conn.lastSyncAt, ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z"))

        api.txError = nil
        api.txPages[Self.uid] = [txPage([("r1", "10.00", "CRDT")])]
        let recovered = try await Sync.sync(connection: conn, api: api, in: ctx, now: now)
        XCTAssertEqual(recovered.errors, [])
        // Window still starts from the held watermark (2026-06-01 − 7d), not from `now`.
        XCTAssertEqual(api.lastTxQuery?.dateFrom, "2026-05-25")
        XCTAssertEqual(recovered.transactionsInserted, 1)
        XCTAssertEqual(conn.lastSyncAt, now)
    }

    func testRevokedSessionMarksConnectionExpired() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        let api = StubAPI(session: makeSession(status: "REVOKED"))
        let result = try await Sync.sync(connection: conn, api: api, in: ctx)
        XCTAssertEqual(conn.status, .expired)
        XCTAssertEqual(result.errors, ["session REVOKED"])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SyncRun>()).first?.status, .error)
    }

    // A reconnect that lands while the sync is still checking the old session must survive it.
    func testReauthDuringSessionCheckIsNotMarkedExpired() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx, sessionId: "old-sess")
        let api = StubAPI(session: makeSession(status: "CLOSED"))
        api.whileSessionInFlight = { conn.sessionId = "new-sess" }
        let result = try await Sync.sync(connection: conn, api: api, in: ctx)
        XCTAssertEqual(conn.status, .active)
        XCTAssertNil(conn.lastError)
        XCTAssertEqual(result.errors, ["session CLOSED"])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SyncRun>()).first?.status, .error)
    }

    func testReauthDuringFailedSessionCheckIsNotMarkedExpired() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx, sessionId: "old-sess")
        let api = StubAPI(session: makeSession())
        api.whileSessionInFlight = { conn.sessionId = "new-sess" }
        api.sessionError = EnableBankingError(status: 401, body: "")
        _ = try? await Sync.sync(connection: conn, api: api, in: ctx)
        XCTAssertEqual(conn.status, .active)
        XCTAssertNil(conn.lastError)
    }

    func testBadUidRecordsErrorAndMetadata() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        let api = StubAPI(session: makeSession(uids: ["undefined"]))
        let result = try await Sync.sync(connection: conn, api: api, in: ctx)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].hasPrefix("bad-uid:"))
        let meta = try JSONSerialization.jsonObject(
            with: XCTUnwrap(conn.metadataJSON)) as? [String: Any]
        XCTAssertNotNil(meta?["lastBadAccountAt"])
        XCTAssertEqual(conn.status, .error)
    }

    func testDiscoveredAccountParkedArchivedWithoutTransactions() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()
        api.balances[Self.uid] = balances("50")
        api.txPages[Self.uid] = [txPage([("r1", "10.00", "CRDT")])]

        let result = try await Sync.sync(connection: conn, api: api, in: ctx)
        XCTAssertEqual(result.transactionsInserted, 0)
        let account = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Account>()).first)
        XCTAssertTrue(account.archived)
        XCTAssertNil(account.balance)
        let meta = try JSONSerialization.jsonObject(
            with: XCTUnwrap(account.metadataJSON)) as? [String: Any]
        XCTAssertEqual(meta?["pendingApproval"] as? Bool, true)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Transaction>()).isEmpty)
    }

    func testArchivedAccountSkippedButStamped() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        let account = makeLinkedAccount(ctx, connection: conn)
        account.archived = true
        try ctx.save()

        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()
        api.txPages[Self.uid] = [txPage([("r1", "10.00", "CRDT")])]
        let result = try await Sync.sync(connection: conn, api: api, in: ctx)
        XCTAssertEqual(result.transactionsInserted, 0)
        let meta = try JSONSerialization.jsonObject(
            with: XCTUnwrap(account.metadataJSON)) as? [String: Any]
        XCTAssertNotNil(meta?["lastDiscoveredAt"])
    }

    func testIbanRepointFromOldConnectionRevokesIt() async throws {
        let ctx = try S.makeContext()
        let old = makeConnection(ctx, sessionId: "old-sess")
        let account = makeLinkedAccount(ctx, connection: old, uid: UUID().uuidString)
        let current = makeConnection(ctx)

        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()  // same ES1234 iban as the existing account
        api.balances[Self.uid] = balances("9.99")

        let result = try await Sync.sync(connection: current, api: api, in: ctx)
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(account.connection?.id, current.id)
        XCTAssertEqual(account.externalId, Self.uid)
        XCTAssertEqual(old.status, .revoked)
        let meta = try JSONSerialization.jsonObject(
            with: XCTUnwrap(old.metadataJSON)) as? [String: Any]
        XCTAssertEqual(meta?["replacedBy"] as? String, current.id.uuidString)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
    }

    func testAmbiguousIbanRefusesRepoint() async throws {
        let ctx = try S.makeContext()
        let other = makeConnection(ctx, sessionId: "other")
        _ = makeLinkedAccount(ctx, connection: other, uid: UUID().uuidString)
        _ = makeLinkedAccount(ctx, connection: other, uid: UUID().uuidString)
        let current = makeConnection(ctx)

        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()
        let result = try await Sync.sync(connection: current, api: api, in: ctx)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].hasPrefix("iban-ambiguous:"))
    }

    func testCurrencyOverridePreserved() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        let account = makeLinkedAccount(ctx, connection: conn)
        account.currency = "USD"
        account.metadataJSON = try JSONSerialization.data(
            withJSONObject: ["currencyOverride": true])
        try ctx.save()

        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details(currency: "EUR")
        _ = try await Sync.sync(connection: conn, api: api, in: ctx)
        XCTAssertEqual(account.currency, "USD")
        let meta = try JSONSerialization.jsonObject(
            with: XCTUnwrap(account.metadataJSON)) as? [String: Any]
        XCTAssertEqual(meta?["currencyOverride"] as? Bool, true)
    }

    func testUnauthorizedAPIErrorMarksExpiredAndThrows() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        let api = StubAPI(session: makeSession())
        api.sessionError = EnableBankingError(status: 401, body: "expired")

        do {
            _ = try await Sync.sync(connection: conn, api: api, in: ctx)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual((error as? EnableBankingError)?.status, 401)
        }
        XCTAssertEqual(conn.status, .expired)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SyncRun>()).first?.status, .error)
    }

    func testSyncAllSkipsRevokedAndExpired() async throws {
        let ctx = try S.makeContext()
        let active = makeConnection(ctx)
        let revoked = makeConnection(ctx)
        revoked.status = .revoked
        let expired = makeConnection(ctx)
        expired.status = .expired
        try ctx.save()

        let api = StubAPI(session: makeSession(uids: []))
        let results = await Sync.syncAll(api: api, in: ctx)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].connectionId, active.id)
    }

    // Each bank answers after its own delay, with one account and one new row per connection.
    private struct PacedAPI: EBSyncAPI {
        var delays: [String: Duration] = [:]
        var sessions: [String: SessionResponse] = [:]
        var failing: Set<String> = []
        var details: [String: AccountDetails] = [:]
        var pages: [String: TransactionsResponse] = [:]

        func getSession(_ sessionId: String) async throws -> SessionResponse {
            try await Task.sleep(for: delays[sessionId] ?? .zero)
            if failing.contains(sessionId) { throw EnableBankingError(status: 500, body: "down") }
            return sessions[sessionId]!
        }
        func getAccountDetails(_ accountUid: String) async throws -> AccountDetails { details[accountUid]! }
        func getAccountBalances(_ accountUid: String) async throws -> BalancesResponse {
            decode(#"{"balances": []}"#)
        }
        func getAccountTransactions(_ accountUid: String, query: EBTransactionQuery) async throws -> TransactionsResponse {
            pages[accountUid]!
        }
    }

    private func pacedBanks(_ ctx: ModelContext, delays: [Duration], failing: Set<String> = []) throws -> ([Connection], PacedAPI) {
        var api = PacedAPI(failing: failing)
        var connections: [Connection] = []
        for (i, delay) in delays.enumerated() {
            let uid = UUID().uuidString
            let conn = Connection(connector: .enablebanking, institutionName: "Bank \(i)",
                                  sessionId: "sess-\(i)", status: .active)
            ctx.insert(conn)
            ctx.insert(Account(connection: conn, externalId: uid, type: .bank, institution: "Bank \(i)",
                               name: "Main", currency: "EUR", iban: "ES00\(i)"))
            api.delays["sess-\(i)"] = delay
            api.sessions["sess-\(i)"] = makeSession(uids: [uid])
            api.details[uid] = details(iban: "ES00\(i)")
            api.pages[uid] = txPage([("r\(i)", "10.00", "CRDT")])
            connections.append(conn)
        }
        try ctx.save()
        return (connections, api)
    }

    // A run waited for each bank in turn, so it took as long as all of them together, past the
    // 30 seconds a Shortcuts action gets. Only the waits overlap: the results and run records
    // read as they did.
    func testSyncAllWaitsForTheBanksAtOnce() async throws {
        let ctx = try S.makeContext()
        let (connections, api) = try pacedBanks(ctx, delays: [.milliseconds(600), .milliseconds(200), .milliseconds(400)])

        let clock = ContinuousClock()
        let start = clock.now
        let results = await Sync.syncAll(api: api, in: ctx)
        let elapsed = clock.now - start

        XCTAssertLessThan(elapsed, .milliseconds(1000), "about the slowest bank, not the three in turn")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(600))
        XCTAssertEqual(results.map(\.connectionId), connections.map(\.id), "in the order the connections were made, not the order they finished")
        XCTAssertEqual(results.map(\.transactionsInserted), [1, 1, 1])
        XCTAssertEqual(results.map(\.errors), [[], [], []])
        XCTAssertTrue(connections.allSatisfy { $0.status == .active && $0.lastSyncAt != nil })
        let runs = try ctx.fetch(FetchDescriptor<SyncRun>())
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(Set(runs.compactMap { $0.connection?.id }), Set(connections.map(\.id)))
        XCTAssertTrue(runs.allSatisfy { $0.status == .ok && $0.insertedTransactions == 1 && $0.finishedAt != nil })
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Transaction>()), 3)
    }

    func testABankFailingAlongsideTheOthersIsRecordedAsBefore() async throws {
        let ctx = try S.makeContext()
        let (connections, api) = try pacedBanks(ctx, delays: [.milliseconds(100), .zero, .milliseconds(50)], failing: ["sess-1"])

        let results = await Sync.syncAll(api: api, in: ctx)

        XCTAssertEqual(results.map(\.connectionId), connections.map(\.id))
        XCTAssertEqual(results.map(\.errors), [[], ["500 down"], []])
        XCTAssertEqual(connections.map(\.status), [.active, .error, .active])
        XCTAssertEqual(connections[1].lastError, "500 down")
        XCTAssertNil(connections[1].lastSyncAt)
        let failedId = connections[1].id
        let failedRun = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SyncRun>()).first { $0.connection?.id == failedId })
        XCTAssertEqual(failedRun.status, .error)
        XCTAssertEqual(failedRun.error, "500 down")
    }

    // A bank's own connections still run in turn: one that takes over another's account revokes
    // it, and a revoked connection must not then sync and take the account back.
    func testConnectionsToTheSameBankRunInTurn() async throws {
        let ctx = try S.makeContext()
        let first = makeConnection(ctx)
        let second = makeConnection(ctx, sessionId: "second-sess")
        let account = makeLinkedAccount(ctx, connection: second, uid: UUID().uuidString)

        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()  // same ES1234 iban as the second connection's account

        let results = await Sync.syncAll(api: api, in: ctx)

        XCTAssertEqual(results.map(\.connectionId), [first.id], "the connection it revoked is skipped")
        XCTAssertEqual(account.connection?.id, first.id)
        XCTAssertEqual(second.status, .revoked)
        XCTAssertEqual(first.status, .active)
    }

    // iOS ending the time a sync was given cancels it. The run it cut short says so, rather than
    // sitting as "running" until a later sync calls it abandoned.
    func testARunCutShortAtTheBankIsRecordedAsCutOff() async throws {
        for cancelled in [URLError(.cancelled), CancellationError()] as [any Error] {
            let ctx = try S.makeContext()
            let conn = makeConnection(ctx)
            let api = StubAPI(session: makeSession())
            api.details[Self.uid] = details()
            api.sessionErrorIfCancelled = cancelled
            let task = Task { await Sync.syncAll(api: api, in: ctx) }
            api.whileSessionInFlight = { task.cancel() }

            let results = await task.value

            XCTAssertEqual(results.map(\.errors), [[Sync.cutOff]], "\(cancelled)")
            let run = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SyncRun>()).first)
            XCTAssertEqual(run.status, .error)
            XCTAssertEqual(run.error, Sync.cutOff)
            XCTAssertNotNil(run.finishedAt)
            XCTAssertEqual(conn.lastError, Sync.cutOff)
        }
    }

    func testARunCutShortBetweenAccountsIsAnErrorNotPartial() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        _ = makeLinkedAccount(ctx, connection: conn)
        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()
        api.txErrorIfCancelled = URLError(.cancelled)
        let task = Task { await Sync.syncAll(api: api, in: ctx) }
        api.whileSessionInFlight = { task.cancel() }

        let results = await task.value

        XCTAssertEqual(results.map(\.errors), [[Sync.cutOff]])
        let run = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SyncRun>()).first)
        XCTAssertEqual(run.status, .error)
        XCTAssertEqual(run.error, Sync.cutOff)
        XCTAssertNil(conn.lastSyncAt, "the next run fetches the window again")
    }

    // A request cancelled while the sync itself carries on is an account's error, as before.
    func testACancelledRequestWithoutTheSyncCancelledIsNotCutOff() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        _ = makeLinkedAccount(ctx, connection: conn)
        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()
        api.txError = URLError(.cancelled)

        let results = await Sync.syncAll(api: api, in: ctx)

        let errors = try XCTUnwrap(results.first?.errors)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].hasPrefix("\(Self.uid): "), errors[0])
        XCTAssertNotEqual(errors[0], Sync.cutOff)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SyncRun>()).first?.status, .partial)
    }

    // Banks still waiting when the sync is cancelled are all cut off; one already done stays done.
    func testCancellingTheBanksAtOnceCutsOffEveryRunStillOut() async throws {
        let ctx = try S.makeContext()
        let (connections, api) = try pacedBanks(ctx, delays: [.seconds(30), .zero, .seconds(30)])
        let task = Task { await Sync.syncAll(api: api, in: ctx) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let results = await task.value

        XCTAssertEqual(results.map(\.errors), [[Sync.cutOff], [], [Sync.cutOff]])
        let runs = try ctx.fetch(FetchDescriptor<SyncRun>())
        XCTAssertEqual(runs.count, 3)
        XCTAssertFalse(runs.contains { $0.status == .running || $0.finishedAt == nil }, "none left running")
        for (connection, expected) in zip(connections, [SyncRunStatus.error, .ok, .error]) {
            let id = connection.id
            let run = try XCTUnwrap(runs.first { $0.connection?.id == id })
            XCTAssertEqual(run.status, expected)
            XCTAssertEqual(run.error, expected == .error ? Sync.cutOff : nil)
        }
    }

    // A prior run that was suspended after saving its rows never post-processed them; the
    // next run must mirror them even though it inserts nothing itself.
    func testPostProcessCatchesUpRowsFromSuspendedRun() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        let account = makeLinkedAccount(ctx, connection: conn)
        let card = S.makeAccount(ctx, name: "Card")
        try CoreLogic.TransferRoutes.createRoute(pattern: "CARD PAYOFF", target: card, in: ctx)
        let orphan = S.makeTx(ctx, account: account, amount: -50, direction: .debit,
                              bookedAt: .now.addingTimeInterval(-2 * 86_400),
                              description: "CARD PAYOFF")
        try ctx.save()

        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()
        let result = try await Sync.sync(connection: conn, api: api, in: ctx)

        XCTAssertEqual(result.transactionsInserted, 0)
        XCTAssertEqual(result.postProcess?.routedMirrors, 1)
        XCTAssertTrue(orphan.isTransfer)
        let orphanId = orphan.id
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.routedFromTx?.id == orphanId })), 1)
    }

    func testPostProcessDaysCoversTheFetchedWindow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func days(_ d: Double?) -> Int {
            Sync.postProcessDays(lastSyncAt: d.map { now.addingTimeInterval(-$0 * 86_400) }, now: now)
        }
        XCTAssertEqual(days(1), 30)
        XCTAssertEqual(days(46), 53)
        XCTAssertEqual(days(nil), 730)
        XCTAssertEqual(days(1_000), 730)
    }

    // An expired consent leaves a gap longer than 30 days; the rows fetched on reconnect
    // must still be routed.
    func testPostProcessReachesBackAcrossALongSyncGap() async throws {
        let ctx = try S.makeContext()
        let conn = makeConnection(ctx)
        conn.lastSyncAt = .now.addingTimeInterval(-46 * 86_400)
        let account = makeLinkedAccount(ctx, connection: conn)
        let card = S.makeAccount(ctx, name: "Card")
        try CoreLogic.TransferRoutes.createRoute(pattern: "CARD PAYOFF", target: card, in: ctx)
        let old = S.makeTx(ctx, account: account, amount: -50, direction: .debit,
                           bookedAt: .now.addingTimeInterval(-40 * 86_400),
                           description: "CARD PAYOFF")
        try ctx.save()

        let api = StubAPI(session: makeSession())
        api.details[Self.uid] = details()
        let result = try await Sync.sync(connection: conn, api: api, in: ctx)

        XCTAssertEqual(result.postProcess?.routedMirrors, 1)
        XCTAssertTrue(old.isTransfer)
    }
}

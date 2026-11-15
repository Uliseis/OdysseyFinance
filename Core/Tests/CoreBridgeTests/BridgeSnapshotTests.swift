import XCTest
import SwiftData
@testable import CoreBridge
@testable import CoreLogic
@testable import CoreModel
@testable import CoreSync

@MainActor
final class BridgeSnapshotTests: XCTestCase {
    private func export(_ ctx: ModelContext, redact: Bool) throws -> BridgeSnapshot {
        try BridgeExport.make(in: ctx, appState: BridgeFixture.appState, redact: redact, now: BridgeFixture.now)
    }

    func test_unredactedExport_rebuildsAnIdenticalStore() throws {
        let f = try BridgeFixture()
        let original = try export(f.ctx, redact: false)
        let replica = try BridgeReplica(original)
        XCTAssertEqual(try export(replica.context, redact: false).normalized(), original.normalized())
    }

    func test_snapshot_survivesJSON() throws {
        let f = try BridgeFixture()
        let snapshot = try export(f.ctx, redact: true)
        let data = try BridgeCoding.encoder().encode(snapshot)
        XCTAssertEqual(try BridgeCoding.decoder().decode(BridgeSnapshot.self, from: data), snapshot)
    }

    func test_redactedExport_dropsSecretsAndBankPayloads_keepsWhatLogicReads() throws {
        let f = try BridgeFixture()
        let s = try export(f.ctx, redact: true)

        let connection = try XCTUnwrap(s.connections.first)
        XCTAssertNil(connection.sessionId)
        XCTAssertNil(connection.accessTokenEnc)
        XCTAssertNil(connection.refreshTokenEnc)
        XCTAssertNotNil(connection.metadataJSON)

        let bankRow = try XCTUnwrap(s.transactions.first { $0.id == f.bankRow.id })
        XCTAssertNil(bankRow.rawJSON)
        XCTAssertEqual(s.bankDetails, [BankDetail(
            txId: f.bankRow.id, code: "CARD_PAYMENT", codeDescription: "Card payment",
            creditor: "SAMPLE MARKET", debtor: nil)])

        XCTAssertNotNil(s.transactions.first { $0.id == f.splitLeg.id }?.rawJSON, "split marker is read by Automations.splitSource")
        XCTAssertNotNil(s.accounts.first { $0.id == f.card.id }?.metadataJSON, "feedSince is read by TransferRoutes.createMirror")
        XCTAssertTrue(s.syncRuns.allSatisfy { $0.rawJSON == nil })
        XCTAssertTrue(s.redacted)
    }

    func test_replicaFromRedactedFile_keepsSplitSourceAndRelationships() throws {
        let f = try BridgeFixture()
        let replica = try BridgeReplica(try export(f.ctx, redact: true))
        let ctx = replica.context

        let leg = try XCTUnwrap(ModelSnapshots.find(transaction: f.splitLeg.id, in: ctx))
        XCTAssertEqual(try CoreLogic.Automations.splitSource(of: leg, in: ctx), "arrival-1")

        let mirror = try XCTUnwrap(ctx.fetch(FetchDescriptor<Transaction>()).first { $0.routedFromTx != nil })
        XCTAssertEqual(mirror.routedFromTx?.id, f.mirroredSource.id)
        XCTAssertEqual(mirror.account?.id, f.card.id)
        XCTAssertEqual(ModelSnapshots.find(category: f.restaurants.id, in: ctx)?.parent?.name, "Food")

        let group = try XCTUnwrap(ctx.fetch(FetchDescriptor<SharedExpenseGroup>()).first)
        XCTAssertEqual(group.primaryTx?.transactionDescription, "GROUP DINNER")
        XCTAssertEqual(group.members.count, 2)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<TransferGroup>()).allSatisfy { $0.transactions.count == 2 })
    }

    func test_replica_givesTheSameBalancesAndCashFlowAsTheStore() throws {
        let f = try BridgeFixture()
        let replica = try BridgeReplica(try export(f.ctx, redact: true))
        let cycle = BridgeFixture.appState.cycle

        func figures(_ ctx: ModelContext) throws -> ([UUID: Decimal], [CoreLogic.Dashboard.MonthlyFlow], [CoreLogic.Dashboard.CategorySpend]) {
            let accounts = try ctx.fetch(FetchDescriptor<Account>())
            let ids = Set(accounts.map(\.id))
            return (
                try CoreLogic.Accounts.displayBalancesEur(accounts, in: ctx),
                try CoreLogic.Dashboard.monthlyCashFlow(
                    months: 3, accountIds: ids, incomeAccountIds: CoreLogic.Dashboard.incomeAccountIds(from: accounts),
                    now: BridgeFixture.now, cycle: cycle, in: ctx),
                try CoreLogic.Dashboard.categoryBreakdown(accountIds: ids, now: BridgeFixture.now, cycle: cycle, in: ctx)
            )
        }
        let source = try figures(f.ctx)
        let copy = try figures(replica.context)
        XCTAssertEqual(source.0, copy.0)
        XCTAssertEqual(source.1, copy.1)
        XCTAssertEqual(source.2, copy.2)
        XCTAssertEqual(source.0[f.usd.id], 80, "110 USD opening at 1.10, less a 20 EUR row: needs the exported FX rate")
    }

    func test_replicaLoad_scalesToSeveralYearsOfRows() throws {
        let ctx = try BridgeFixture.makeContext()
        let account = Account(externalId: "a", type: .bank, institution: "Example", name: "Bulk", currency: "EUR")
        let category = CoreModel.Category(name: "Bulk")
        ctx.insert(account); ctx.insert(category)
        for i in 0..<5_000 {
            ctx.insert(Transaction(
                account: account, externalId: "bulk-\(i)", bookedAt: BridgeFixture.day(-i / 5),
                amount: -10, currency: "EUR", amountEur: -10, direction: .debit,
                description: "ROW \(i)", category: i.isMultiple(of: 3) ? category : nil))
        }
        try ctx.save()
        let snapshot = try export(ctx, redact: true)

        let start = Date()
        let replica = try BridgeReplica(snapshot)
        let elapsed = Date().timeIntervalSince(start)
        print("[bridge] replica load of 5000 rows: \(String(format: "%.2f", elapsed))s")
        XCTAssertEqual(try replica.context.fetchCount(FetchDescriptor<Transaction>()), 5_000)
        XCTAssertLessThan(elapsed, 10)
    }

    func test_appStateWithoutClaudeSettings_stillDecodes() throws {
        let old = #"{"cycleStartDay":20,"cycleStartsEarlyOnWeekends":true,"automation":{"recurringEnabled":false,"recurringMuted":[],"recurringDeclined":[],"recurringPins":[],"pensionEnabled":false,"pensionDeclinedArrivals":[]}}"#
        let state = try BridgeCoding.decoder().decode(BridgeAppState.self, from: Data(old.utf8))
        XCTAssertEqual(state.cycleStartDay, 20)
        XCTAssertNil(state.claude)
    }
}

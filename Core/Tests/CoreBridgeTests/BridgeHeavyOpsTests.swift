import XCTest
import SwiftData
@testable import CoreBridge
@testable import CoreLogic
@testable import CoreModel

// Statement import, deletes, feed adoption, pension-split undo, routes and requests to the
// phone. All always need review, except a bank sync request when its switch is on.
@MainActor
final class BridgeHeavyOpsTests: XCTestCase {
    private let now = BridgeFixture.now

    private func run(_ ops: [BridgeOp], _ f: BridgeFixture) -> BatchOutcome {
        BridgeExecutor.run(BridgeBatch(summary: "test", ops: ops), in: f.ctx, now: now)
    }

    private func count<M: PersistentModel>(_ type: M.Type, _ f: BridgeFixture) throws -> Int {
        try f.ctx.fetchCount(FetchDescriptor<M>())
    }

    private let statement = """
    Type,Started Date,Completed Date,Description,Amount,Fee,Balance
    CARD_PAYMENT,2026-03-02 12:00:00,2026-03-03 10:00:00,SAMPLE CAFE,-6.50,0.00,-6.50
    CARD_PAYMENT,2026-03-04 18:00:00,2026-03-05 10:00:00,SAMPLE BOOKSHOP,-20.00,0.00,-26.50
    TRANSFER,2026-03-06 09:00:00,2026-03-06 09:00:00,Top up,30.00,0.00,3.50
    """

    func test_importStatement_previewsOnTheReplica_andReplaysAsNoChange() throws {
        let f = try BridgeFixture()
        let rowsBefore = try count(Transaction.self, f)
        let replica = try BridgeReplica(BridgeExport.make(in: f.ctx, appState: BridgeFixture.appState, redact: false, now: now))
        let preview = try replica.preview(BridgeBatch(summary: "", ops: [.importStatement(accountId: f.card.id, csv: statement)]), now: now)
        XCTAssertEqual(preview.outcome.ops.first?.status, .applied, "\(preview.outcome.ops)")
        XCTAssertEqual(preview.outcome.ops.first?.changes.filter { $0.after == "new row" }.count, 2)
        XCTAssertTrue(preview.outcome.ops.first?.message.contains("1 transfers skipped") ?? false)
        XCTAssertNil(preview.outcome.autoApplyKinds)
        XCTAssertEqual(try count(Transaction.self, f), rowsBefore, "a preview must not touch the real store")

        XCTAssertEqual(run([.importStatement(accountId: f.card.id, csv: statement)], f).ops.first?.status, .applied)
        XCTAssertEqual(try count(Transaction.self, f), rowsBefore + 2)
        XCTAssertEqual(run([.importStatement(accountId: f.card.id, csv: statement)], f).ops.first?.status, .skipped)
        XCTAssertEqual(try count(Transaction.self, f), rowsBefore + 2)
    }

    func test_importIntoABankFedAccount_fails() throws {
        let f = try BridgeFixture()
        XCTAssertEqual(run([.importStatement(accountId: f.checking.id, csv: statement)], f).ops.first?.status, .failed)
    }

    func test_deletes_refuseTransferLegs_untilUnpaired() throws {
        let f = try BridgeFixture()
        let before = try count(Transaction.self, f)
        let refused = run([.deleteTransactions(txIds: [f.mirroredSource.id])], f)
        XCTAssertEqual(refused.ops.first?.status, .failed)
        XCTAssertEqual(try count(Transaction.self, f), before)

        let unknown = try XCTUnwrap(f.ctx.fetch(FetchDescriptor<Transaction>()).first { $0.transactionDescription == "UNKNOWN CREDIT" })
        let deleted = run([.deleteTransactions(txIds: [unknown.id])], f)
        XCTAssertEqual(deleted.ops.first?.status, .applied)
        XCTAssertNil(deleted.undo, "deletes can't be undone")
        XCTAssertNil(deleted.autoApplyKinds)
        XCTAssertEqual(try count(Transaction.self, f), before - 1)
    }

    func test_routes_reportTheMirrorsTheyBookAndRemove() throws {
        let f = try BridgeFixture()
        let route = try XCTUnwrap(f.ctx.fetch(FetchDescriptor<TransferRoute>()).first)

        let disabled = run([.updateRoute(routeId: route.id, pattern: nil, targetAccountId: nil, sourceAccountId: nil,
                                         field: nil, match: nil, direction: nil, enabled: false)], f)
        XCTAssertEqual(disabled.ops.first?.status, .applied, "\(disabled.ops)")
        XCTAssertEqual(disabled.ops.first?.changes.filter { $0.after == "deleted" }.count, 1)
        XCTAssertTrue(f.mirroredSource.mirrors.isEmpty)

        let deleted = run([.deleteRoute(routeId: route.id)], f)
        XCTAssertEqual(deleted.ops.first?.status, .applied)
        XCTAssertEqual(try count(TransferRoute.self, f), 0)

        let created = run([.createRoute(pattern: "To Card", targetAccountId: f.card.id, sourceAccountId: f.checking.id,
                                        field: .description, match: .contains, direction: .debit, priority: 5)], f)
        XCTAssertEqual(created.ops.first?.changes.filter { $0.after == "mirror" }.count, 1, "\(created.ops)")
        XCTAssertEqual(f.mirroredSource.mirrors.count, 1)
        XCTAssertNil(created.autoApplyKinds)
    }

    func test_undoPensionSplit_removesTheLegs_andRefusesOtherRows() throws {
        let f = try BridgeFixture()
        let splitId = f.splitLeg.id
        XCTAssertEqual(run([.undoPensionSplit(debitTxId: splitId)], f).ops.first?.status, .applied)
        XCTAssertNil(try f.ctx.fetch(FetchDescriptor<Transaction>()).first { $0.id == splitId })
        XCTAssertEqual(run([.undoPensionSplit(debitTxId: f.bankRow.id)], f).ops.first?.status, .failed)
    }

    func test_adoptFeed_mergesTheDiscoveredAccountIntoTheManualOne() throws {
        let f = try BridgeFixture()
        let feed = Account(connection: f.checking.connection, group: f.card.group, space: f.card.space,
                           externalId: "uid-card-feed", type: .bank, institution: "Example Bank", name: "Card feed", currency: "EUR")
        f.ctx.insert(feed)
        f.ctx.insert(Transaction(account: feed, externalId: "feed-1", bookedAt: BridgeFixture.day(-7).addingTimeInterval(3_600),
                                 amount: -40, currency: "EUR", amountEur: -40, direction: .debit, description: "EXAMPLE BISTRO"))
        try f.ctx.save()
        let feedId = feed.id

        let outcome = run([.adoptFeed(feedAccountId: feedId, manualAccountId: f.card.id)], f)
        XCTAssertEqual(outcome.ops.first?.status, .applied, "\(outcome.ops)")
        XCTAssertTrue(outcome.ops.first?.message.hasPrefix("1 rows matched") ?? false, outcome.ops.first?.message ?? "")
        XCTAssertNil(try f.ctx.fetch(FetchDescriptor<Account>()).first { $0.id == feedId })
        XCTAssertNotNil(f.card.connection)
    }

    func test_bankRequests_changeNoData_andOnlyTheSyncCanAutoApply() throws {
        let f = try BridgeFixture()
        let connection = try XCTUnwrap(f.checking.connection)
        let snapshot = try BridgeExport.make(in: f.ctx, appState: BridgeFixture.appState, redact: false, now: now).normalized()

        let sync = run([.requestBankSync(connectionIds: nil), .categorize(txIds: [f.splitLeg.id], category: "Groceries")], f)
        XCTAssertEqual(sync.ops.first?.status, .applied)
        XCTAssertEqual(sync.autoApplyKinds, [.categorizeUncategorized, .requestBankSync])
        XCTAssertNotNil(sync.undo, "a sync request doesn't stop the rest of the batch being undoable")

        let reconnect = run([.requestReconnect(connectionId: connection.id)], f)
        XCTAssertEqual(reconnect.ops.first?.status, .applied)
        XCTAssertNil(reconnect.autoApplyKinds)

        f.splitLeg.category = nil
        f.splitLeg.categorySource = .bank
        try f.ctx.save()
        let after = try BridgeExport.make(in: f.ctx, appState: BridgeFixture.appState, redact: false, now: now).normalized()
        XCTAssertEqual(after.connections, snapshot.connections)
        XCTAssertEqual(after.transactions.count, snapshot.transactions.count)
    }

    func test_oneOpWithoutUndo_takesUndoAwayFromTheBatch_andIsUndoableSaysSo() throws {
        let f = try BridgeFixture()
        let connection = try XCTUnwrap(f.checking.connection)
        let undoable: [BridgeOp] = [.categorize(txIds: [f.splitLeg.id], category: "Groceries"),
                                    .requestReconnect(connectionId: connection.id)]
        XCTAssertTrue(undoable.allSatisfy(\.isUndoable))
        XCTAssertNotNil(run(undoable, f).undo)

        let out = try XCTUnwrap(f.ctx.fetch(FetchDescriptor<Transaction>()).first { $0.transactionDescription == "To Savings" })
        let mixed: [BridgeOp] = [.categorize(txIds: [f.bankRow.id], category: "Restaurants"), .unpairTransfer(txId: out.id)]
        XCTAssertFalse(mixed[1].isUndoable)
        XCTAssertNil(run(mixed, f).undo)
    }

    func test_createTransaction_onManualAccountsOnly_runsRules_replaysAsNoChange_andUndoes() throws {
        let f = try BridgeFixture()
        let op = BridgeOp.createTransaction(accountId: f.card.id, amount: -12, bookedAt: BridgeFixture.day(-1),
                                            description: "SAMPLE MARKET 02", counterparty: nil, category: nil)
        let created = run([op], f)
        XCTAssertEqual(created.ops.first?.status, .applied, "\(created.ops)")
        let row = try XCTUnwrap(f.ctx.fetch(FetchDescriptor<Transaction>()).first { $0.transactionDescription == "SAMPLE MARKET 02" })
        XCTAssertEqual(row.amount, -12)
        XCTAssertEqual(row.direction, .debit)
        XCTAssertEqual(row.category?.name, "Groceries", "the existing rule files it")
        XCTAssertTrue(row.externalId.hasPrefix("manual-tx:"), "statement imports match quick-add rows")

        XCTAssertEqual(run([op], f).ops.first?.status, .skipped)
        XCTAssertEqual(run([.createTransaction(accountId: f.checking.id, amount: 5, bookedAt: BridgeFixture.day(0),
                                               description: "x", counterparty: nil, category: nil)], f).ops.first?.status, .failed)

        let reverted = run(try XCTUnwrap(created.undo), f)
        XCTAssertEqual(reverted.failedCount, 0)
        XCTAssertNil(try f.ctx.fetch(FetchDescriptor<Transaction>()).first { $0.transactionDescription == "SAMPLE MARKET 02" })
    }

    func test_mirrorTransfer_booksALegOnAManualAccount_andUndoRemovesIt() throws {
        let f = try BridgeFixture()
        let outcome = run([.mirrorTransfer(sourceTxId: f.bankRow.id, targetAccountId: f.savings.id)], f)
        XCTAssertEqual(outcome.ops.first?.status, .applied, "\(outcome.ops)")
        XCTAssertEqual(f.bankRow.mirrors.count, 1)
        XCTAssertTrue(f.bankRow.isTransfer)
        XCTAssertEqual(run([.mirrorTransfer(sourceTxId: f.bankRow.id, targetAccountId: f.savings.id)], f).ops.first?.status, .skipped)

        _ = run(try XCTUnwrap(outcome.undo), f)
        XCTAssertTrue(f.bankRow.mirrors.isEmpty)
        XCTAssertFalse(f.bankRow.isTransfer)
    }

    func test_sharedGroupFromCredit_andArchiving() throws {
        let f = try BridgeFixture()
        let credit = try XCTUnwrap(f.ctx.fetch(FetchDescriptor<Transaction>()).first { $0.transactionDescription == "UNKNOWN CREDIT" })
        let expense = try XCTUnwrap(f.ctx.fetch(FetchDescriptor<Transaction>()).first { $0.transactionDescription == "EXAMPLE BISTRO" })
        let grouped = run([.createSharedGroupFromCredit(label: "Bistro split", creditTxId: credit.id, expenseTxIds: [expense.id])], f)
        XCTAssertEqual(grouped.ops.first?.status, .applied, "\(grouped.ops)")
        XCTAssertNotNil(credit.sharedExpenseGroup)
        XCTAssertNil(grouped.undo)

        let archived = run([.archiveAccount(accountId: f.broker.id, archived: true)], f)
        XCTAssertEqual(archived.ops.first?.status, .applied)
        XCTAssertTrue(f.broker.archived)
        _ = run(try XCTUnwrap(archived.undo), f)
        XCTAssertFalse(f.broker.archived)
    }

    func test_previewListsEveryPastCycleItMoves() throws {
        let f = try BridgeFixture()
        let old = Transaction(account: f.checking, externalId: "old-credit", bookedAt: BridgeFixture.day(-45),
                              amount: 15, currency: "EUR", amountEur: 15, direction: .credit, description: "OLD REFUND")
        f.ctx.insert(old)
        // Something to offset: a credit never takes a category's spending below zero.
        f.ctx.insert(Transaction(account: f.checking, externalId: "old-shop", bookedAt: BridgeFixture.day(-44),
                                 amount: -40, currency: "EUR", amountEur: -40, direction: .debit, description: "OLD SHOP",
                                 category: f.groceries, categorySource: .manual))
        try f.ctx.save()
        let replica = try BridgeReplica(BridgeExport.make(in: f.ctx, appState: BridgeFixture.appState, redact: false, now: now))
        let preview = try replica.preview(BridgeBatch(summary: "", ops: [.categorize(txIds: [old.id], category: "Groceries")]), now: now)

        let month = try XCTUnwrap(preview.months.first, "\(preview.months)")
        XCTAssertEqual(preview.months.count, 1)
        XCTAssertLessThan(month.end, BridgeFixture.day(-15), "a past cycle, not the current one")
        XCTAssertEqual(month.incomeBefore - month.incomeAfter, 15, "an uncategorized credit stops counting as income")
        XCTAssertEqual(month.expenseBefore - month.expenseAfter, 15, "and offsets that month's spending instead")
        XCTAssertEqual(preview.before.cycleNet, preview.after.cycleNet)
    }

    func test_newOpsRoundTripThroughJSON() throws {
        let ops: [BridgeOp] = [
            .importStatement(accountId: UUID(), csv: statement), .deleteTransactions(txIds: [UUID()]),
            .adoptFeed(feedAccountId: UUID(), manualAccountId: UUID()), .undoPensionSplit(debitTxId: UUID()),
            .createRoute(pattern: "x", targetAccountId: UUID(), sourceAccountId: nil, field: .counterparty, match: .equals,
                         direction: .credit, priority: 3),
            .updateRoute(routeId: UUID(), pattern: nil, targetAccountId: UUID(), sourceAccountId: nil, field: nil, match: nil,
                         direction: nil, enabled: false),
            .deleteRoute(routeId: UUID()), .requestBankSync(connectionIds: nil), .requestReconnect(connectionId: UUID()),
            .createTransaction(accountId: UUID(), amount: Decimal(string: "-12.34")!, bookedAt: now, description: "x",
                               counterparty: "y", category: "Groceries"),
            .mirrorTransfer(sourceTxId: UUID(), targetAccountId: UUID()),
            .createSharedGroupFromCredit(label: "z", creditTxId: UUID(), expenseTxIds: [UUID()]),
            .archiveAccount(accountId: UUID(), archived: false),
        ]
        let batch = BridgeBatch(summary: "all", ops: ops)
        XCTAssertEqual(try BridgeCoding.decoder().decode(BridgeBatch.self, from: BridgeCoding.encoder().encode(batch)), batch)
    }
}

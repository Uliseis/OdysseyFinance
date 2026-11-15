import XCTest
import SwiftData
@testable import CoreBridge
@testable import CoreLogic
@testable import CoreModel

@MainActor
final class BridgeExecutorTests: XCTestCase {
    private let now = BridgeFixture.now

    private func row(_ text: String, in ctx: ModelContext) throws -> Transaction {
        try XCTUnwrap(ctx.fetch(FetchDescriptor<Transaction>()).first { $0.transactionDescription == text })
    }

    private func replica(_ f: BridgeFixture) throws -> BridgeReplica {
        try BridgeReplica(BridgeExport.make(in: f.ctx, appState: BridgeFixture.appState, redact: false, now: now))
    }

    private func categories(_ ctx: ModelContext) throws -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<Transaction>()).map { ($0.id, "\($0.category?.name ?? "-")/\($0.categorySource.rawValue)") })
    }

    // The batch Claude would send for one unknown credit: a new category, the row, a rule.
    private func safeBatch(_ f: BridgeFixture) throws -> BridgeBatch {
        BridgeBatch(summary: "Refunds", ops: [
            .createCategory(name: "Refunds", kind: .expense, parent: nil),
            .categorize(txIds: [try row("UNKNOWN CREDIT", in: f.ctx).id], category: "refunds"),
            .createRule(pattern: "UNKNOWN", category: "Refunds", field: .description, match: .contains, priority: -1000),
        ])
    }

    func test_opsDecodeFromTheJSONClaudeWrites_withDefaults() throws {
        let json = #"""
        [{"op":"createCategory","name":"Gifts"},
         {"op":"createRule","pattern":"BIZUM","category":"Shared costs"},
         {"op":"categorize","txIds":["6F9619FF-8B86-D011-B42D-00CF4FC964FF"],"category":"Gifts"},
         {"op":"recordValuation","accountId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","asOf":"2026-03-10T00:00:00Z","marketValueEur":1234.5}]
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ops = try decoder.decode([BridgeOp].self, from: Data(json.utf8))
        XCTAssertEqual(ops[0], .createCategory(name: "Gifts", kind: .expense, parent: nil))
        XCTAssertEqual(ops[1], .createRule(pattern: "BIZUM", category: "Shared costs", field: .description, match: .contains, priority: -1000))
        XCTAssertEqual(ops[3].autoApplyKind, .recordValuation)
        XCTAssertThrowsError(try decoder.decode([BridgeOp].self, from: Data(#"[{"op":"dropTable"}]"#.utf8)))

        let all: [BridgeOp] = ops + [
            .updateRule(ruleId: UUID(), pattern: "X", category: nil, field: .counterparty, match: .equals),
            .deleteRule(ruleId: UUID()), .applyRules(txIds: nil), .pairTransfer(txIds: [UUID(), UUID()]),
            .unpairTransfer(txId: UUID()), .createSharedGroup(label: "Trip", primaryTxId: UUID(), reimbursementTxIds: [UUID()]),
            .deleteSharedGroup(groupId: UUID()), .restoreCategories([.init(txId: UUID(), categoryId: nil, source: .bank)]),
            .deleteCategory(id: UUID()), .deleteValuation(id: UUID()),
        ]
        let batch = BridgeBatch(summary: "all", ops: all)
        XCTAssertEqual(try BridgeCoding.decoder().decode(BridgeBatch.self, from: BridgeCoding.encoder().encode(batch)), batch)
    }

    func test_previewRunsOnTheReplicaOnly_andApplyingDoesWhatThePreviewShowed() throws {
        let f = try BridgeFixture()
        let batch = try safeBatch(f)
        let before = try categories(f.ctx)

        let preview = try replica(f).preview(batch, now: now.addingTimeInterval(3_600))
        XCTAssertEqual(preview.outcome.ops.map(\.status), [.applied, .applied, .applied])
        XCTAssertEqual(try categories(f.ctx), before, "a preview must not touch the real store")
        XCTAssertTrue(try BridgeExecutor.findCategories(named: "Refunds", in: f.ctx).isEmpty)
        XCTAssertEqual(preview.after.uncategorized, preview.before.uncategorized - 1)
        // Recategorizing never changes income minus spending.
        XCTAssertEqual(preview.after.cycleNet, preview.before.cycleNet)
        XCTAssertEqual(preview.outcome.autoApplyKinds, [.categorizeUncategorized, .createCategory, .createRule])

        let applied = BridgeExecutor.run(batch, in: f.ctx, now: now)
        XCTAssertEqual(applied.ops.map(\.status), preview.outcome.ops.map(\.status))
        XCTAssertEqual(try row("UNKNOWN CREDIT", in: f.ctx).category?.name, "Refunds")
        XCTAssertEqual(try row("UNKNOWN CREDIT", in: f.ctx).categorySource, .manual)
    }

    func test_replayingABatchChangesNothing() throws {
        let f = try BridgeFixture()
        let batch = try safeBatch(f)
        _ = BridgeExecutor.run(batch, in: f.ctx, now: now)
        let snapshot = try categories(f.ctx)
        let again = BridgeExecutor.run(batch, in: f.ctx, now: now)
        XCTAssertEqual(again.ops.map(\.status), [.skipped, .skipped, .skipped])
        XCTAssertEqual(try categories(f.ctx), snapshot)
        XCTAssertEqual(try f.ctx.fetch(FetchDescriptor<CategoryRule>()).filter { $0.pattern == "UNKNOWN" }.count, 1)
    }

    func test_undoRestoresEverythingTheSafeSetChanged() throws {
        let f = try BridgeFixture()
        let original = try categories(f.ctx)
        let rulesBefore = try f.ctx.fetchCount(FetchDescriptor<CategoryRule>())
        let valuationsBefore = try f.ctx.fetchCount(FetchDescriptor<PortfolioValuation>())

        var batch = try safeBatch(f)
        batch.ops += [
            .applyRules(txIds: nil),
            .recordValuation(accountId: f.broker.id, asOf: BridgeFixture.day(0), marketValueEur: 1200, cashValueEur: nil, notes: nil),
            .recordValuation(accountId: f.broker.id, asOf: BridgeFixture.day(-1), marketValueEur: 1150, cashValueEur: 50, notes: nil),
        ]
        let outcome = BridgeExecutor.run(batch, in: f.ctx, now: now)
        XCTAssertEqual(outcome.failedCount, 0, "\(outcome.ops)")
        let undo = try XCTUnwrap(outcome.undo)
        XCTAssertTrue(undo.allSatisfy(\.isUndoOnly) || undo.contains { if case .recordValuation = $0 { true } else { false } })

        let reverted = BridgeExecutor.run(BridgeBatch(summary: "undo", ops: undo), in: f.ctx, now: now)
        XCTAssertEqual(reverted.failedCount, 0, "\(reverted.ops)")
        XCTAssertEqual(try categories(f.ctx), original)
        XCTAssertEqual(try f.ctx.fetchCount(FetchDescriptor<CategoryRule>()), rulesBefore)
        XCTAssertTrue(try BridgeExecutor.findCategories(named: "Refunds", in: f.ctx).isEmpty)
        let valuations = try f.ctx.fetch(FetchDescriptor<PortfolioValuation>())
        XCTAssertEqual(valuations.count, valuationsBefore)
        XCTAssertEqual(valuations.first?.marketValueEur, 1100)
    }

    func test_reviewIsRequiredOutsideTheSafeSet_andAFailureDoesntStopTheBatch() throws {
        let f = try BridgeFixture()
        let recategorize = BridgeExecutor.run(
            BridgeBatch(summary: "", ops: [.categorize(txIds: [f.bankRow.id], category: "Restaurants")]), in: f.ctx, now: now)
        XCTAssertNil(recategorize.autoApplyKinds, "moving a categorized row needs review")

        let mixed = BridgeExecutor.run(BridgeBatch(summary: "", ops: [
            .categorize(txIds: [UUID()], category: "Groceries"),
            .createCategory(name: "Gifts", kind: .expense, parent: nil),
        ]), in: f.ctx, now: now)
        XCTAssertEqual(mixed.ops.map(\.status), [.failed, .applied])
        XCTAssertNil(mixed.autoApplyKinds)
        XCTAssertNotNil(mixed.ops[0].message.range(of: "Not found"))

        let ambiguous = BridgeExecutor.run(BridgeBatch(summary: "", ops: [
            .createCategory(name: "Gifts", kind: .expense, parent: nil),
            .categorize(txIds: [f.bankRow.id], category: "Nope"),
        ]), in: f.ctx, now: now)
        XCTAssertEqual(ambiguous.ops.map(\.status), [.skipped, .failed])
    }

    func test_transfersSharedGroupsAndRules_needReviewAndWork() throws {
        let f = try BridgeFixture()
        let out = try row("To Savings", in: f.ctx), into = try row("From Checking", in: f.ctx)

        let unpaired = BridgeExecutor.run(BridgeBatch(summary: "", ops: [.unpairTransfer(txId: out.id)]), in: f.ctx, now: now)
        XCTAssertEqual(unpaired.ops.map(\.status), [.applied])
        XCTAssertNil(unpaired.autoApplyKinds)
        XCTAssertNil(unpaired.undo)
        XCTAssertFalse(out.isTransfer)

        let paired = BridgeExecutor.run(BridgeBatch(summary: "", ops: [
            .pairTransfer(txIds: [out.id, into.id]), .pairTransfer(txIds: [out.id, into.id]),
        ]), in: f.ctx, now: now)
        XCTAssertEqual(paired.ops.map(\.status), [.applied, .skipped])
        XCTAssertTrue(out.isTransfer && into.isTransfer)

        let rule = try XCTUnwrap(f.ctx.fetch(FetchDescriptor<CategoryRule>()).first)
        let edited = BridgeExecutor.run(BridgeBatch(summary: "", ops: [
            .updateRule(ruleId: rule.id, pattern: nil, category: "Restaurants", field: nil, match: nil),
            .deleteRule(ruleId: rule.id),
        ]), in: f.ctx, now: now)
        XCTAssertEqual(edited.ops.map(\.status), [.applied, .applied])
        XCTAssertEqual(try f.ctx.fetchCount(FetchDescriptor<CategoryRule>()), 0)

        let expense = try row("EXAMPLE BISTRO", in: f.ctx), refund = try row("SAMPLE MARKET REFUND", in: f.ctx)
        let grouped = BridgeExecutor.run(BridgeBatch(summary: "", ops: [
            .createSharedGroup(label: "Bistro", primaryTxId: expense.id, reimbursementTxIds: [refund.id]),
        ]), in: f.ctx, now: now)
        XCTAssertEqual(grouped.ops.map(\.status), [.applied], "\(grouped.ops)")
        let group = try XCTUnwrap(expense.sharedExpenseGroup)
        let dissolved = BridgeExecutor.run(BridgeBatch(summary: "", ops: [.deleteSharedGroup(groupId: group.id)]), in: f.ctx, now: now)
        XCTAssertEqual(dissolved.ops.map(\.status), [.applied])
        XCTAssertNil(expense.sharedExpenseGroup)
    }

    func test_undoNeverDeletesACategoryThatIsInUse() throws {
        let f = try BridgeFixture()
        let outcome = BridgeExecutor.run(try safeBatch(f), in: f.ctx, now: now)
        // The user files another row under the new category by hand before undoing.
        try CoreLogic.Categories.recategorize(f.bankRow, to: BridgeExecutor.category(named: "Refunds", in: f.ctx), in: f.ctx)
        let reverted = BridgeExecutor.run(BridgeBatch(summary: "undo", ops: try XCTUnwrap(outcome.undo)), in: f.ctx, now: now)
        XCTAssertEqual(reverted.ops.last?.status, .failed)
        XCTAssertEqual(f.bankRow.category?.name, "Refunds")
    }
}

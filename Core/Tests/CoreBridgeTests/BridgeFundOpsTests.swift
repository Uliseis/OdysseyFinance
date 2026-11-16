import XCTest
import SwiftData
@testable import CoreBridge
@testable import CoreLogic
@testable import CoreModel

// Fund-order imports and the investment settings Claude can correct. Synthetic ISINs, dates in
// 2030 and invented amounts only: the repository is public.
@MainActor
final class BridgeFundOpsTests: XCTestCase {
    private let a = BridgeFixture.fundA
    private let b = BridgeFixture.fundB
    private let c = "ZZ0000000C08"
    private let now = BridgeFixture.utcDay(2030, 4, 1)

    private let ordersHeader = "Fecha de la orden;ISIN;Importe estimado;Nº de participaciones;Estado"
    private let cashHeader = "Fecha de operación;Fecha de valor;Concepto;Importe;Divisa"

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private func orders(_ lines: String...) -> String { ([ordersHeader] + lines).joined(separator: "\n") }

    private func cash(_ lines: [(day: String, amount: String)]) -> String {
        ([cashHeader] + lines.map { "\($0.day);\($0.day);EXAMPLE FUND;\($0.amount);EUR" }).joined(separator: "\n")
    }

    // Three buys and a sale, each settled the next day for exactly its estimate.
    private var firstOrders: String {
        orders("20/03/2030;\(a);125.00 EUR;12,000;Finalizada",
               "20/02/2030;\(a);205.00 EUR;20,000;Finalizada",
               "15/02/2030;\(b);50.00 EUR;5,000;Finalizada",
               "20/01/2030;\(a);100.00 EUR;10,000;Finalizada")
    }
    private var firstCash: String {
        cash([("21/03/2030", "125"), ("21/02/2030", "-205"), ("16/02/2030", "-50"), ("21/01/2030", "-100")])
    }
    private var firstImport: BridgeOp { importOp(firstOrders, firstCash, [a: 18, b: 5]) }

    private struct Store {
        let ctx: ModelContext
        let funds: Account
        let cashAccount: Account
    }

    private func store() throws -> Store {
        let ctx = try BridgeFixture.makeContext()
        let invest = AccountGroup(name: "Investments", kind: .investment)
        let cashGroup = AccountGroup(name: "Cash", kind: .cash)
        let space = AccountSpace(name: "Personal", isDefault: true)
        [invest, cashGroup].forEach(ctx.insert)
        ctx.insert(space)
        let funds = Account(group: invest, space: space, externalId: "funds", type: .broker, institution: "Example",
                            name: "Funds", currency: "EUR", costBasisOpeningEur: 1000,
                            costBasisOpeningAt: BridgeFixture.utcDay(2030, 1, 1))
        let cashAccount = Account(group: cashGroup, space: space, externalId: "cash", type: .bank, institution: "Example",
                                  name: "Checking", currency: "EUR", manualOpeningBalance: 0)
        ctx.insert(funds)
        ctx.insert(cashAccount)
        try ctx.save()
        return Store(ctx: ctx, funds: funds, cashAccount: cashAccount)
    }

    private func importOp(_ orders: String, _ movements: String, _ held: [String: Decimal], into account: UUID? = nil) -> BridgeOp {
        .importFundOrders(accountId: account ?? UUID(), ordersCsv: orders, movementsCsv: movements, heldUnits: held)
    }

    private func importing(_ op: BridgeOp, into account: Account) -> BridgeOp {
        guard case .importFundOrders(_, let o, let m, let h) = op else { return op }
        return .importFundOrders(accountId: account.id, ordersCsv: o, movementsCsv: m, heldUnits: h)
    }

    private func run(_ ops: [BridgeOp], _ s: Store) -> BatchOutcome {
        BridgeExecutor.run(BridgeBatch(summary: "test", ops: ops), in: s.ctx, now: now)
    }

    private func replica(_ s: Store) throws -> BridgeReplica {
        try BridgeReplica(BridgeExport.make(in: s.ctx, appState: .init(), redact: true, now: now))
    }

    private func trades(_ s: Store) throws -> [FundTrade] {
        try s.ctx.fetch(FetchDescriptor<FundTrade>()).sorted { ($0.importKey ?? "") < ($1.importKey ?? "") }
    }

    // MARK: - Decoding

    func test_fundOpsDecodeFromTheJSONClaudeWrites_andRoundTrip() throws {
        let id = "6F9619FF-8B86-D011-B42D-00CF4FC964FF"
        let json = #"""
        [{"op":"importFundOrders","accountId":"\#(id)","ordersCsv":"o","movementsCsv":"m","heldUnits":{"\#(a)":12.345,"\#(b)":5}},
         {"op":"setBrokerCashAnchor","accountId":"\#(id)","amountEur":250.5,"at":"2030-01-01T00:00:00Z"},
         {"op":"setBrokerCashAnchor","accountId":"\#(id)","amountEur":null},
         {"op":"setCostBasisOpening","accountId":"\#(id)","amountEur":1500,"at":"2030-02-01T00:00:00Z"},
         {"op":"setLiveSource","accountId":"\#(id)","source":"funds"},
         {"op":"setLiveSource","accountId":"\#(id)","source":null}]
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ops = try decoder.decode([BridgeOp].self, from: Data(json.utf8))
        let account = try XCTUnwrap(UUID(uuidString: id))
        XCTAssertEqual(ops, [
            .importFundOrders(accountId: account, ordersCsv: "o", movementsCsv: "m", heldUnits: [a: d("12.345"), b: 5]),
            .setBrokerCashAnchor(accountId: account, amountEur: d("250.5"), at: BridgeFixture.utcDay(2030, 1, 1)),
            .setBrokerCashAnchor(accountId: account, amountEur: nil, at: nil),
            .setCostBasisOpening(accountId: account, amountEur: 1500, at: BridgeFixture.utcDay(2030, 2, 1)),
            .setLiveSource(accountId: account, source: "funds"),
            .setLiveSource(accountId: account, source: nil),
        ])
        XCTAssertThrowsError(try decoder.decode([BridgeOp].self, from: Data(
            #"[{"op":"importFundOrders","accountId":"\#(id)","ordersCsvPath":"/tmp/o.csv","movementsCsv":"m","heldUnits":{}}]"#.utf8)),
            "paths are the server's to read; the phone only takes the text")

        XCTAssertTrue(ops.allSatisfy { $0.isUndoable && !$0.isUndoOnly && $0.autoApplyKind == nil })
        let restore = BridgeOp.restoreFundTrades(deleteIds: [UUID()], restores: [.init(id: UUID(), amountEur: 10, switchGroupId: nil)])
        XCTAssertTrue(restore.isUndoOnly)
        let batch = BridgeBatch(summary: "all", ops: ops + [restore])
        XCTAssertEqual(try BridgeCoding.decoder().decode(BridgeBatch.self, from: BridgeCoding.encoder().encode(batch)), batch)
    }

    // MARK: - importFundOrders

    func test_importFundOrders_previewsOnTheReplica_applies_replaysAsNoChange_andUndoes() throws {
        let s = try store()
        let op = importing(firstImport, into: s.funds)

        let preview = try replica(s).preview(BridgeBatch(summary: "", ops: [op]), now: now)
        let shown = try XCTUnwrap(preview.outcome.ops.first)
        XCTAssertEqual(shown.status, .applied, shown.message)
        XCTAssertTrue(shown.message.contains("4 new, 0 already saved"), shown.message)
        XCTAssertTrue(shown.message.contains("4 matched to cash movements"), shown.message)
        XCTAssertEqual(shown.changes.filter { $0.after?.hasPrefix("new trade") ?? false }.count, 4)
        XCTAssertEqual(shown.changes.first { $0.label.contains("2030-03-20 · sell \(a)") }?.after, "new trade, 125 EUR")
        XCTAssertEqual(shown.changes.first { $0.label == "\(a) position" }?.after, "18 units · cost 184.5 EUR · realised 4.5 EUR")
        XCTAssertEqual(shown.changes.first { $0.label == "\(b) position" }?.after, "5 units · cost 50 EUR · realised 0 EUR")
        XCTAssertNotNil(preview.outcome.undo)
        XCTAssertNil(preview.outcome.autoApplyKinds)
        XCTAssertTrue(try trades(s).isEmpty, "a preview must not touch the real store")

        // Trade ids differ between the replica and the store; everything shown must not.
        func shownText(_ changes: [BridgeChange]?) -> [String] {
            (changes ?? []).map { "\($0.label) | \($0.before ?? "-") | \($0.after ?? "-")" }
        }
        let applied = run([op], s)
        XCTAssertEqual(applied.ops.map(\.status), [.applied])
        XCTAssertEqual(shownText(applied.ops.first?.changes), shownText(shown.changes))
        XCTAssertEqual(try trades(s).count, 4)
        XCTAssertEqual(run([op], s).ops.first?.status, .skipped)

        let reverted = run(try XCTUnwrap(applied.undo), s)
        XCTAssertEqual(reverted.failedCount, 0, "\(reverted.ops)")
        XCTAssertTrue(try trades(s).isEmpty)
    }

    func test_importFundOrders_listsCorrectedAmounts_andUndoPutsThemBack() throws {
        let s = try store()
        let earlier = BridgeFixture.utcDay(2030, 3, 20)
        // Saved from the estimate by an import without the cash export.
        s.ctx.insert(FundTrade(account: s.funds, isin: a, tradeDate: BridgeFixture.utcDay(2030, 1, 20), side: .buy,
                               units: 100, amountEur: 1000, importKey: "myinvestor:v1:2030-01-20:\(a):100:1000#1",
                               createdAt: earlier, updatedAt: earlier))
        try s.ctx.save()
        let op = BridgeOp.importFundOrders(
            accountId: s.funds.id,
            ordersCsv: orders("15/03/2030;\(c);300.00 EUR;30,000;Finalizada",
                              "20/01/2030;\(a);1000.00 EUR;100,000;Finalizada"),
            movementsCsv: cash([("17/03/2030", "-299,90"), ("21/01/2030", "-1.000,25")]),
            heldUnits: [a: 100, c: 30])

        let outcome = run([op], s)
        let shown = try XCTUnwrap(outcome.ops.first)
        XCTAssertEqual(shown.status, .applied, shown.message)
        XCTAssertTrue(shown.message.contains("1 new, 1 already saved"), shown.message)
        XCTAssertTrue(shown.message.contains("1 amounts corrected by 0.25 EUR"), shown.message)
        let corrected = try XCTUnwrap(shown.changes.first { $0.label.contains("buy \(a)") })
        XCTAssertEqual(corrected.before, "1000 EUR")
        XCTAssertEqual(corrected.after, "1000.25 EUR")
        XCTAssertEqual(shown.changes.first { $0.label == "\(a) position" }?.before, "100 units · cost 1000 EUR · realised 0 EUR")
        XCTAssertEqual(try trades(s).map(\.amountEur), [d("1000.25"), d("299.9")])

        let reverted = run(try XCTUnwrap(outcome.undo), s)
        XCTAssertEqual(reverted.ops.map(\.status), [.applied], "\(reverted.ops)")
        XCTAssertEqual(try trades(s).map(\.amountEur), [1000])
    }

    func test_importFundOrders_refusalsSayWhy_andWriteNothing() throws {
        let s = try store()
        func refusal(_ op: BridgeOp) throws -> String {
            let outcome = run([op], s)
            XCTAssertEqual(outcome.ops.first?.status, .failed)
            XCTAssertTrue(try trades(s).isEmpty)
            return try XCTUnwrap(outcome.ops.first?.message)
        }

        let incomplete = try refusal(importing(importOp(firstOrders, firstCash, [a: 18, b: 5, c: 7]), into: s.funds))
        XCTAssertTrue(incomplete.hasPrefix("Import refused: the orders export is incomplete"), incomplete)
        XCTAssertTrue(incomplete.contains(c), incomplete)

        let mismatch = try refusal(importing(importOp(firstOrders, firstCash, [a: 18, b: 4]), into: s.funds))
        XCTAssertTrue(mismatch.contains(b) && mismatch.contains("heldUnits"), mismatch)

        let unmatched = try refusal(importing(importOp(firstOrders, cashHeader, [a: 18, b: 5]), into: s.funds))
        XCTAssertTrue(unmatched.contains("no cash movement or switch partner"), unmatched)

        let swapped = try refusal(importing(importOp(firstCash, firstOrders, [a: 18, b: 5]), into: s.funds))
        XCTAssertTrue(swapped.contains("orders export") && swapped.contains("Fecha de la orden;ISIN"), swapped)

        let notInvestment = try refusal(importing(firstImport, into: s.cashAccount))
        XCTAssertTrue(notInvestment.contains("Checking isn't an investment account"), notInvestment)
    }

    func test_restoreFundTrades_putsBackAmountsAndSwitchGroups() throws {
        let s = try store()
        let group = UUID()
        let trade = FundTrade(account: s.funds, isin: a, tradeDate: BridgeFixture.utcDay(2030, 1, 20), side: .sell,
                              units: 10, amountEur: 120, switchGroupId: UUID())
        let extra = FundTrade(account: s.funds, isin: b, tradeDate: BridgeFixture.utcDay(2030, 1, 22), side: .buy,
                              units: 6, amountEur: 118)
        s.ctx.insert(trade)
        s.ctx.insert(extra)
        try s.ctx.save()

        let outcome = run([.restoreFundTrades(deleteIds: [extra.id],
                                              restores: [.init(id: trade.id, amountEur: 115, switchGroupId: group)])], s)
        XCTAssertEqual(outcome.ops.first?.status, .applied, "\(outcome.ops)")
        XCTAssertEqual(try trades(s).map(\.id), [trade.id])
        XCTAssertEqual(trade.amountEur, 115)
        XCTAssertEqual(trade.switchGroupId, group)
    }

    // MARK: - Investment settings

    func test_setBrokerCashAnchor_pinsTheDay_reportsTheLedger_replaysAsNoChange_andUndoes() throws {
        let s = try store()
        _ = run([importing(firstImport, into: s.funds)], s)
        let op = BridgeOp.setBrokerCashAnchor(accountId: s.funds.id, amountEur: 300,
                                              at: BridgeFixture.utcDay(2030, 1, 1).addingTimeInterval(15 * 3_600))

        let outcome = run([op], s)
        let shown = try XCTUnwrap(outcome.ops.first)
        XCTAssertEqual(shown.status, .applied, shown.message)
        XCTAssertEqual(shown.changes.first?.before, nil)
        XCTAssertEqual(shown.changes.first?.after, "300 EUR at the end of 2030-01-01")
        // 300 − 100 − 50 − 205 + 125: the second buy takes it to −55.
        XCTAssertTrue(shown.message.contains("now 70 EUR"), shown.message)
        XCTAssertTrue(shown.message.contains("lowest -55 EUR on 2030-02-20"), shown.message)
        XCTAssertEqual(s.funds.brokerCashAnchorAt, BridgeFixture.utcDay(2030, 1, 1))
        XCTAssertEqual(run([op], s).ops.first?.status, .skipped)
        XCTAssertNil(outcome.autoApplyKinds)

        let reverted = run(try XCTUnwrap(outcome.undo), s)
        XCTAssertEqual(reverted.ops.map(\.status), [.applied], "\(reverted.ops)")
        XCTAssertNil(s.funds.brokerCashAnchorEur)
        XCTAssertNil(s.funds.brokerCashAnchorAt)
        XCTAssertEqual(run([.setBrokerCashAnchor(accountId: s.cashAccount.id, amountEur: 1, at: now)], s).ops.first?.status, .failed)
    }

    func test_setCostBasisOpening_changesCostBasis_andUndoRestoresThePreviousOpening() throws {
        let s = try store()
        let op = BridgeOp.setCostBasisOpening(accountId: s.funds.id, amountEur: 1500, at: BridgeFixture.utcDay(2030, 2, 1))

        let outcome = run([op], s)
        let shown = try XCTUnwrap(outcome.ops.first)
        XCTAssertEqual(shown.status, .applied, shown.message)
        XCTAssertEqual(shown.changes.first?.before, "1000 EUR before 2030-01-01")
        XCTAssertEqual(shown.changes.first?.after, "1500 EUR before 2030-02-01")
        XCTAssertTrue(shown.message.contains("1000 → 1500"), shown.message)
        XCTAssertEqual(run([op], s).ops.first?.status, .skipped)

        _ = run(try XCTUnwrap(outcome.undo), s)
        XCTAssertEqual(s.funds.costBasisOpeningEur, 1000)
        XCTAssertEqual(s.funds.costBasisOpeningAt, BridgeFixture.utcDay(2030, 1, 1))
    }

    func test_setLiveSource_switchesTheSource_andRefusesWhatItCantUndo() throws {
        let s = try store()
        let outcome = run([.setLiveSource(accountId: s.funds.id, source: " funds ")], s)
        let shown = try XCTUnwrap(outcome.ops.first)
        XCTAssertEqual(shown.status, .applied, shown.message)
        XCTAssertEqual(shown.message, "The phone values it from fund prices (EODHD)")
        XCTAssertEqual(shown.changes.first?.before, "typed valuations")
        XCTAssertEqual(shown.changes.first?.after, "fund prices (EODHD)")
        XCTAssertEqual(s.funds.liveValueSource, "funds")
        XCTAssertNil(s.funds.assetQuantity)
        XCTAssertEqual(run([.setLiveSource(accountId: s.funds.id, source: "funds")], s).ops.first?.status, .skipped)

        _ = run(try XCTUnwrap(outcome.undo), s)
        XCTAssertNil(s.funds.liveValueSource)

        // Without a quantity a crypto source values nothing, and dropping one couldn't be undone.
        let crypto = run([.setLiveSource(accountId: s.funds.id, source: "crypto:example")], s)
        XCTAssertEqual(crypto.ops.first?.status, .failed)
        XCTAssertTrue(crypto.ops.first?.message.contains("needs a quantity") ?? false, "\(crypto.ops)")
        try CoreLogic.Investments.setLiveSource(s.funds, source: "crypto:example", quantity: d("0.5"), in: s.ctx)
        let away = run([.setLiveSource(accountId: s.funds.id, source: "funds")], s)
        XCTAssertEqual(away.ops.first?.status, .failed)
        XCTAssertTrue(away.ops.first?.message.contains("quantity") ?? false, "\(away.ops)")
        XCTAssertEqual(s.funds.assetQuantity, d("0.5"))
    }

    func test_setLiveSource_takesOnlyTrading212FundPricesOrNone() throws {
        let s = try store()
        let t212 = run([.setLiveSource(accountId: s.funds.id, source: "t212")], s)
        let shown = try XCTUnwrap(t212.ops.first)
        XCTAssertEqual(shown.status, .applied, shown.message)
        XCTAssertEqual(shown.message, "The phone values it from Trading 212")
        XCTAssertEqual(shown.changes.first?.after, "Trading 212")
        XCTAssertEqual(s.funds.liveValueSource, "t212")

        for source in ["coingecko", "Funds", "eodhd"] {
            let refused = run([.setLiveSource(accountId: s.funds.id, source: source)], s)
            XCTAssertEqual(refused.ops.first?.status, .failed, source)
            XCTAssertEqual(refused.ops.first?.message,
                           #"Unknown source "\#(source)": use "funds" (fund prices), "t212" (Trading 212) or null (typed valuations only)"#)
        }
        XCTAssertEqual(s.funds.liveValueSource, "t212")

        let manual = run([.setLiveSource(accountId: s.funds.id, source: nil)], s)
        XCTAssertEqual(manual.ops.first?.status, .applied, "\(manual.ops)")
        XCTAssertEqual(manual.ops.first?.changes.first?.before, "Trading 212")
        XCTAssertNil(s.funds.liveValueSource)
    }
}

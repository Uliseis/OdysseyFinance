import XCTest
import SwiftData
@testable import CoreBridge
@testable import CoreLogic
@testable import CoreModel

@MainActor
final class BridgeQueriesTests: XCTestCase {
    private let now = BridgeFixture.now

    private func replica(_ f: BridgeFixture) throws -> BridgeReplica {
        try BridgeReplica(try BridgeExport.make(in: f.ctx, appState: BridgeFixture.appState, redact: true, now: now))
    }

    func test_overview_matchesTheDashboardAndExplainsEachBalance() throws {
        let f = try BridgeFixture()
        let o = try replica(f).overview(now: now.addingTimeInterval(3_600))

        let personal = try XCTUnwrap(f.ctx.fetch(FetchDescriptor<AccountSpace>()).first(where: \.isDefault))
        let dashboard = try XCTUnwrap(CoreLogic.Dashboard.summary(
            spaceId: personal.id, defaultSpaceId: personal.id, months: 1, now: now.addingTimeInterval(3_600),
            cycle: BridgeFixture.appState.cycle, in: f.ctx))
        XCTAssertEqual(o.netWorth, dashboard.totalNetWorth)
        XCTAssertEqual(o.space, "Personal")
        XCTAssertEqual(o.snapshotAgeMinutes, 60)

        let source = Dictionary(uniqueKeysWithValues: o.accounts.map { ($0.name, $0.balanceSource) })
        XCTAssertEqual(source["Main"], "bank")
        XCTAssertEqual(source["Savings"], "anchor")
        XCTAssertEqual(source["Card"], "opening")
        XCTAssertEqual(source["Broker"], "valuation")
        XCTAssertNotNil(o.accounts.first { $0.name == "Card" }?.feedSince)

        let connection = try XCTUnwrap(o.connections.first)
        XCTAssertEqual(connection.daysUntilExpiry, 79)
        XCTAssertEqual(connection.accounts, 1)
        // UNKNOWN CREDIT, the split leg and the USD diner; the shared-group payback doesn't count.
        XCTAssertEqual(o.uncategorizedCount, 3)
    }

    // A live price times a quantity has more than two decimals; Claude should see cents. The
    // ledger sum of a valued account isn't its balance, so it's replaced by cost basis and P&L.
    func test_overview_roundsEurosToCents_andValuedAccountsShowCostBasisNotLedger() throws {
        let f = try BridgeFixture()
        f.ctx.insert(PortfolioValuation(account: f.broker, asOf: BridgeFixture.day(0),
                                        marketValueEur: Decimal(string: "1234.56789")!, cashValueEur: 0, notes: nil))
        try f.ctx.save()
        let o = try replica(f).overview(now: now.addingTimeInterval(3_600))

        func isCents(_ d: Decimal?) -> Bool {
            guard var d else { return true }
            var rounded = Decimal()
            NSDecimalRound(&rounded, &d, 2, .plain)
            return rounded == d
        }
        XCTAssertTrue(o.accounts.allSatisfy { isCents($0.balanceEur) && isCents($0.costBasisEur) && isCents($0.pnlEur) })
        XCTAssertTrue([o.netWorth, o.cash, o.liabilities, o.investments].allSatisfy(isCents))
        XCTAssertTrue(o.groups.allSatisfy { isCents($0.eur) })

        let broker = try XCTUnwrap(o.accounts.first { $0.name == "Broker" })
        XCTAssertNil(broker.balanceNative)
        XCTAssertNotNil(broker.costBasisEur)
        XCTAssertNotNil(broker.pnlEur)
        XCTAssertNotNil(o.accounts.first { $0.name == "Main" }?.balanceNative)
    }

    func test_transactions_filterByTextCategoryAmountAndCarryBankDetails() throws {
        let f = try BridgeFixture()
        let r = try replica(f)

        let market = try r.transactions(.init(text: "sample market"))
        XCTAssertEqual(market.total, 2)
        XCTAssertEqual(market.rows.first { $0.id == f.bankRow.id }?.bankCode, "CARD_PAYMENT")
        XCTAssertEqual(market.rows.first { $0.id == f.bankRow.id }?.creditor, "SAMPLE MARKET")

        XCTAssertEqual(try r.transactions(.init(category: "groceries")).total, 2)
        XCTAssertEqual(try r.transactions(.init(uncategorized: true)).total, 3)
        let big = try r.transactions(.init(minAmount: 150, transfers: false))
        XCTAssertEqual(big.rows.map(\.description), ["PAYROLL EXAMPLE LTD"])

        let paged = try r.transactions(.init(limit: 2, offset: 1))
        XCTAssertEqual(paged.rows.count, 2)
        XCTAssertGreaterThan(paged.total, 2)

        let mirrorSource = try XCTUnwrap(r.transactions(.init(text: "To Card", direction: .debit)).rows.first)
        XCTAssertEqual(mirrorSource.mirrorTxIds?.count, 1)
    }

    func test_flowAndBreakdown_usePayCycleAndDashboardRules() throws {
        let f = try BridgeFixture()
        let r = try replica(f)

        let flow = try r.monthlyFlow(months: 2, now: now)
        XCTAssertEqual(flow.count, 2)
        let cycleStart = CoreLogic.Dashboard.cycleStart(now, cycle: BridgeFixture.appState.cycle)
        XCTAssertEqual(flow.last?.start, cycleStart, "buckets follow the phone's day-20 cycle")
        XCTAssertEqual(flow.last.map { $0.income - $0.expense }, flow.last?.net)

        let breakdown = Dictionary(uniqueKeysWithValues: try r.categoryBreakdown(containing: now).map { ($0.category, $0.total) })
        XCTAssertEqual(breakdown["Restaurants"], 85, "bistro 40 + the dinner group's net 45 under its primary's category")
        XCTAssertEqual(breakdown["Groceries"], 40, "a refund in a spending category offsets it")
        XCTAssertEqual(breakdown["Uncategorized"], 25)
    }

    func test_rulesRoutesCategoriesAndSyncStatus() throws {
        let f = try BridgeFixture()
        let r = try replica(f)
        XCTAssertEqual(try r.rules().map(\.pattern), ["SAMPLE MARKET"])
        let route = try XCTUnwrap(r.routes().first)
        XCTAssertEqual(route.mirrorCount, 1)
        XCTAssertEqual(route.target, "Card")
        XCTAssertEqual(try r.categories().first { $0.name == "Restaurants" }?.parent, "Food")
        let status = try r.syncStatus(now: now)
        XCTAssertEqual(status.runs.first?.inserted, 3)
        XCTAssertEqual(status.connections.count, 1)
    }

    func test_transferCandidates_findUnpairedSameAmountLegs() throws {
        let f = try BridgeFixture()
        let out = Transaction(account: f.checking, externalId: "x-out", bookedAt: BridgeFixture.day(-2), amount: -75,
                              currency: "EUR", amountEur: -75, direction: .debit, description: "Exchange")
        let into = Transaction(account: f.savings, externalId: "x-in", bookedAt: BridgeFixture.day(-1), amount: 75,
                               currency: "EUR", amountEur: 75, direction: .credit, description: "Top-up")
        f.ctx.insert(out); f.ctx.insert(into)
        try f.ctx.save()
        let r = try replica(f)

        let window = try r.transferCandidates(txId: nil, from: BridgeFixture.day(-10), to: now)
        let pair = try XCTUnwrap(window.first { $0.debit.id == out.id })
        XCTAssertEqual(pair.credit.id, into.id)
        XCTAssertTrue(pair.withinDetectWindow)
        XCTAssertFalse(window.contains { $0.debit.isTransfer || $0.credit.isTransfer })

        XCTAssertEqual(try r.transferCandidates(txId: out.id, from: nil, to: nil).map(\.credit.id), [into.id])
        XCTAssertThrowsError(try r.transferCandidates(txId: UUID(), from: nil, to: nil))
    }

    func test_paybackCandidates_listCreditsNearAnExpense() throws {
        let f = try BridgeFixture()
        let r = try replica(f)
        let bistro = try XCTUnwrap(r.transactions(.init(text: "EXAMPLE BISTRO")).rows.first)
        let candidates = try r.paybackCandidates(txId: bistro.id)
        XCTAssertTrue(candidates.contains { $0.description == "UNKNOWN CREDIT" })
        XCTAssertFalse(candidates.contains { $0.description == "PAYBACK FROM FRIEND" }, "already in a shared group")
    }

    func test_fundPositions_perFundFiguresSwitchesAndTheCashLedger() throws {
        let f = try BridgeFixture()
        let p = try replica(f).fundPositions(accountId: f.broker.id)
        XCTAssertEqual(p.account, "Broker")
        XCTAssertEqual(p.trades, 3)

        let sold = try XCTUnwrap(p.funds.first { $0.isin == BridgeFixture.fundA })
        XCTAssertFalse(sold.held)
        XCTAssertEqual(sold.units, 0)
        XCTAssertNil(sold.averagePriceEur)
        XCTAssertEqual(sold.realisedGainEur, 20)
        let held = try XCTUnwrap(p.funds.first { $0.isin == BridgeFixture.fundB })
        XCTAssertTrue(held.held)
        XCTAssertEqual(held.units, Decimal(string: "6.125"))
        XCTAssertEqual(held.costEur, 120)
        XCTAssertEqual(held.averagePriceEur, Decimal(string: "19.5918"), "120 / 6.125, to four decimals")

        let pair = try XCTUnwrap(p.switches.first)
        XCTAssertEqual(p.switches.count, 1)
        XCTAssertEqual(pair.sell?.isin, BridgeFixture.fundA)
        XCTAssertEqual(pair.buy?.isin, BridgeFixture.fundB)
        XCTAssertEqual(pair.buy?.date, BridgeFixture.utcDay(2030, 3, 12))

        // 250 at the anchor, −100 for the buy, +120 −120 for the switch.
        let cash = try XCTUnwrap(p.cash)
        XCTAssertEqual(cash.anchorEur, 250)
        XCTAssertEqual(cash.currentEur, 150)
        XCTAssertEqual(cash.lowestEur, 150)
        XCTAssertEqual(cash.lowestOn, BridgeFixture.utcDay(2030, 1, 20))

        XCTAssertNil(try replica(f).fundPositions(accountId: f.checking.id).cash)
        XCTAssertThrowsError(try replica(f).fundPositions(accountId: UUID()))
    }
}

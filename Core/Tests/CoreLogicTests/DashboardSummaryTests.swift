import XCTest
import SwiftData
@testable import CoreLogic
@testable import CoreModel

@MainActor
final class DashboardSummaryTests: XCTestCase {
    typealias S = TransferTestSupport
    private let now = Date(timeIntervalSince1970: 1_781_524_800) // 2026-06-15 12:00 UTC

    func testSummaryScopesToSpace_andSplitsCashLiabilitiesInvestments() throws {
        let ctx = try S.makeContext()
        let home = S.makeSpace(ctx)
        let other = AccountSpace(name: "Other", isDefault: false)
        ctx.insert(other)
        let cash = AccountGroup(name: "Cash", kind: .cash, sortOrder: 1)
        let cards = AccountGroup(name: "Cards", kind: .credit, sortOrder: 2)
        let invest = AccountGroup(name: "Invest", kind: .investment, sortOrder: 3)
        [cash, cards, invest].forEach(ctx.insert)

        let checking = S.makeAccount(ctx, name: "Checking", space: home)
        checking.group = cash; checking.manualOpeningBalance = 1000
        let spaceless = S.makeAccount(ctx, name: "Spaceless")
        spaceless.group = cash; spaceless.manualOpeningBalance = 50
        let card = S.makeAccount(ctx, name: "Card", space: home)
        card.group = cards; card.manualOpeningBalance = -200
        let broker = S.makeAccount(ctx, name: "Broker", space: home, excluded: true)
        broker.group = invest
        ctx.insert(PortfolioValuation(account: broker, asOf: now, marketValueEur: 700))
        let elsewhere = S.makeAccount(ctx, name: "Elsewhere", space: other)
        elsewhere.manualOpeningBalance = 9999
        let roommate = S.makeAccount(ctx, name: "Roommate", space: home, excluded: true)
        roommate.manualOpeningBalance = 300
        _ = S.makeTx(ctx, account: checking, amount: -40, direction: .debit, bookedAt: now)
        try ctx.save()

        let s = try XCTUnwrap(CoreLogic.Dashboard.summary(
            spaceId: home.id, defaultSpaceId: home.id, months: 2, now: now, cycle: .init(), in: ctx))
        XCTAssertEqual(s.cashTotal, 1010, "checking 1000 − 40 plus the space-less account; excluded and other-space accounts left out")
        XCTAssertEqual(s.liabilities, -200)
        XCTAssertEqual(s.investmentValue, 700, "investment value ignores `excluded`")
        XCTAssertEqual(s.totalNetWorth, 1510)
        XCTAssertEqual(s.groups.map(\.name), ["Cash", "Cards"])
        XCTAssertEqual(s.flow.last?.expense, 40)

        XCTAssertNil(try CoreLogic.Dashboard.summary(
            spaceId: other.id, defaultSpaceId: home.id, months: 1, now: now, cycle: .init(),
            in: try S.makeContext()), "no accounts ⇒ nil")
    }

    func testSpacesContains_defaultSpaceTakesSpacelessAccounts() throws {
        let ctx = try S.makeContext()
        let home = S.makeSpace(ctx)
        let other = AccountSpace(name: "Other", isDefault: false)
        ctx.insert(other)
        let spaceless = S.makeAccount(ctx, name: "Spaceless")
        XCTAssertTrue(CoreLogic.Spaces.contains(spaceless, spaceId: home.id, defaultSpaceId: home.id))
        XCTAssertFalse(CoreLogic.Spaces.contains(spaceless, spaceId: other.id, defaultSpaceId: home.id))
        XCTAssertTrue(CoreLogic.Spaces.contains(S.makeAccount(ctx, name: "O", space: other), spaceId: other.id, defaultSpaceId: home.id))
    }
}

import XCTest
import SwiftData
@testable import CoreLogic
@testable import CoreModel

@MainActor
final class FeedAdoptionTests: XCTestCase {
    typealias S = TransferTestSupport
    typealias A = CoreLogic.FeedAdoption

    private let day: TimeInterval = 86_400
    // Midnight, like an Enable Banking booking date.
    private let feedStart = Date(timeIntervalSince1970: 1_789_948_800)

    private struct Fixture {
        let ctx: ModelContext
        let manual: Account
        let feed: Account
        let main: Account
        let connection: Connection
    }

    private func fixture() throws -> Fixture {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let connection = Connection(connector: .enablebanking, institutionName: "Bank",
                                    sessionId: "sess", status: .active)
        ctx.insert(connection)
        let manual = S.makeAccount(ctx, name: "Card", space: space)
        manual.balanceAnchor = -100
        manual.balanceAnchorAt = feedStart.addingTimeInterval(-30 * day)
        let feed = S.makeAccount(ctx, name: "HOLDER", space: space, connection: connection)
        feed.externalId = "feed-uid"
        feed.iban = "ES00CARD"
        feed.balance = -42
        feed.metadataJSON = try JSONSerialization.data(withJSONObject: ["pendingApproval": true])
        let main = S.makeAccount(ctx, name: "Main", space: space, connection: connection)
        try ctx.save()
        return Fixture(ctx: ctx, manual: manual, feed: feed, main: main, connection: connection)
    }

    private func rows(_ account: Account, in ctx: ModelContext) throws -> [Transaction] {
        let id = account.id
        return try ctx.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.account?.id == id }))
    }

    func testMatchedChargeKeepsTheManualRowUnderTheFeedId() throws {
        let f = try fixture()
        let category = CoreModel.Category(name: "Restaurants")
        f.ctx.insert(category)
        let mine = S.makeTx(f.ctx, account: f.manual, amount: -12.50, direction: .debit,
                            bookedAt: feedStart.addingTimeInterval(10 * 3600),
                            description: "Statement text", categorySource: .manual,
                            category: category, externalId: "manual-tx:1")
        S.makeTx(f.ctx, account: f.feed, amount: -12.50, direction: .debit,
                 bookedAt: feedStart, description: "FEED TEXT", externalId: "feed-1")
        try f.ctx.save()

        let summary = try A.adopt(feed: f.feed, into: f.manual, in: f.ctx)

        XCTAssertEqual(summary.rekeyed, 1)
        XCTAssertEqual(mine.externalId, "feed-1")
        XCTAssertEqual(mine.transactionDescription, "Statement text")
        XCTAssertEqual(mine.category?.name, "Restaurants")
        XCTAssertEqual(try rows(f.manual, in: f.ctx).count, 1)
        XCTAssertEqual(try f.ctx.fetchCount(FetchDescriptor<Transaction>()), 1)
    }

    func testMatchedTopUpReplacesTheRouteMirrorWithThePairedFeedLeg() throws {
        let f = try fixture()
        let source = S.makeTx(f.ctx, account: f.main, amount: -40, direction: .debit,
                              bookedAt: feedStart, description: "To EUR")
        try CoreLogic.TransferRoutes.createRoute(pattern: "To EUR", target: f.manual, in: f.ctx)
        _ = try CoreLogic.TransferRoutes.apply(in: f.ctx)
        XCTAssertEqual(source.mirrors.count, 1)
        let leg = S.makeTx(f.ctx, account: f.feed, amount: 40, direction: .credit,
                           bookedAt: feedStart, description: "To EUR", externalId: "feed-topup")
        try f.ctx.save()

        let summary = try A.adopt(feed: f.feed, into: f.manual, in: f.ctx)

        XCTAssertEqual(summary.mirrorsReplaced, 1)
        XCTAssertTrue(source.mirrors.isEmpty)
        XCTAssertEqual(leg.account?.id, f.manual.id)
        XCTAssertTrue(leg.isTransfer)
        XCTAssertTrue(source.isTransfer)
        XCTAssertNotNil(leg.transferGroup)
        XCTAssertEqual(leg.transferGroup?.id, source.transferGroup?.id)
        XCTAssertEqual(try rows(f.manual, in: f.ctx).map(\.externalId), ["feed-topup"])
    }

    func testUnmatchedFeedRowsMoveAndManualOnlyRowsStay() throws {
        let f = try fixture()
        S.makeTx(f.ctx, account: f.manual, amount: -2, direction: .debit,
                 bookedAt: feedStart.addingTimeInterval(3600), externalId: "revolutcsv:edge")
        let missing = S.makeTx(f.ctx, account: f.feed, amount: -9.96, direction: .debit,
                               bookedAt: feedStart, externalId: "feed-missing")
        try f.ctx.save()

        let summary = try A.adopt(feed: f.feed, into: f.manual, in: f.ctx)

        XCTAssertEqual(summary.moved, 1)
        XCTAssertEqual(summary.keptManualOnly, 1)
        XCTAssertEqual(missing.account?.id, f.manual.id)
        XCTAssertEqual(Set(try rows(f.manual, in: f.ctx).map(\.externalId)),
                       ["revolutcsv:edge", "feed-missing"])
    }

    func testManualAccountBecomesTheFeedAccount() throws {
        let f = try fixture()
        S.makeTx(f.ctx, account: f.feed, amount: -1, direction: .debit,
                 bookedAt: feedStart.addingTimeInterval(2 * day), externalId: "later")
        S.makeTx(f.ctx, account: f.feed, amount: -3, direction: .debit,
                 bookedAt: feedStart, externalId: "first")
        try f.ctx.save()
        let feedId = f.feed.id

        try A.adopt(feed: f.feed, into: f.manual, in: f.ctx)

        XCTAssertEqual(f.manual.connection?.id, f.connection.id)
        XCTAssertEqual(f.manual.externalId, "feed-uid")
        XCTAssertEqual(f.manual.iban, "ES00CARD")
        XCTAssertEqual(f.manual.balance, -42)
        XCTAssertNil(f.manual.balanceAnchor)
        XCTAssertEqual(f.manual.displayName, "Card")
        XCTAssertEqual(A.feedSince(of: f.manual), feedStart)
        let meta = try JSONSerialization.jsonObject(
            with: XCTUnwrap(f.manual.metadataJSON)) as? [String: Any]
        XCTAssertNil(meta?["pendingApproval"])
        XCTAssertEqual(try CoreLogic.Accounts.computeEurBalances([f.manual], in: f.ctx)[f.manual.id], -42)
        XCTAssertEqual(try f.ctx.fetchCount(FetchDescriptor<Account>(
            predicate: #Predicate { $0.id == feedId })), 0)
    }

    func testRoutesStopMirroringIntoTheAccountOnceItsFeedStarts() throws {
        let f = try fixture()
        S.makeTx(f.ctx, account: f.feed, amount: -3, direction: .debit,
                 bookedAt: feedStart, externalId: "first")
        try f.ctx.save()
        try A.adopt(feed: f.feed, into: f.manual, in: f.ctx)

        let before = S.makeTx(f.ctx, account: f.main, amount: -10, direction: .debit,
                              bookedAt: feedStart.addingTimeInterval(-3 * day), description: "To EUR")
        let after = S.makeTx(f.ctx, account: f.main, amount: -25, direction: .debit,
                             bookedAt: feedStart.addingTimeInterval(5 * day), description: "To EUR")
        try CoreLogic.TransferRoutes.createRoute(pattern: "To EUR", target: f.manual, in: f.ctx)
        _ = try CoreLogic.TransferRoutes.apply(in: f.ctx)

        XCTAssertEqual(before.mirrors.count, 1)
        XCTAssertTrue(after.mirrors.isEmpty)
        XCTAssertFalse(after.isTransfer)
    }

    func testRefusesAConnectedTargetOrACurrencyMismatch() throws {
        let f = try fixture()
        XCTAssertThrowsError(try A.adopt(feed: f.feed, into: f.main, in: f.ctx)) {
            XCTAssertEqual($0 as? A.AdoptError, .targetNotManual)
        }
        f.manual.currency = "USD"
        XCTAssertThrowsError(try A.adopt(feed: f.feed, into: f.manual, in: f.ctx)) {
            XCTAssertEqual($0 as? A.AdoptError, .currencyMismatch)
        }
    }
}

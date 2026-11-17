import XCTest
import SwiftData
import CoreModel
@testable import CoreIntegrations
@testable import CoreLogic

final class InvestmentRefreshTests: XCTestCase {
    private typealias R = CoreLogic.InvestmentRefresh
    private typealias S = TransferTestSupport

    // Regression: parseAmount reads "0,04512345" as 4512345 — its 1-2-digits rule treats that
    // comma as grouping, which is right for money and catastrophic for a BTC holding.
    func testParseQuantityKeepsEightDecimals() {
        let q = CoreLogic.Transactions.parseQuantity("0,04512345")
        XCTAssertEqual(q, Decimal(string: "0.04512345"))
        XCTAssertEqual(CoreLogic.Transactions.parseQuantity("0.04512345"), q)
        XCTAssertNotEqual(CoreLogic.Transactions.parseAmount("0,04512345"), q, "the money parser is the bug")
    }

    func testParseQuantityTreatsTheLastSeparatorAsDecimal() {
        XCTAssertEqual(CoreLogic.Transactions.parseQuantity("1.234,5"), Decimal(string: "1234.5"))
        XCTAssertEqual(CoreLogic.Transactions.parseQuantity("1,234.5"), Decimal(string: "1234.5"))
        XCTAssertEqual(CoreLogic.Transactions.parseQuantity("12"), 12)
        XCTAssertNil(CoreLogic.Transactions.parseQuantity(""))
        XCTAssertNil(CoreLogic.Transactions.parseQuantity("0"))
        XCTAssertNil(CoreLogic.Transactions.parseQuantity("abc"))
    }

    func testImplausibleGuardCatchesOrdersOfMagnitude() {
        XCTAssertTrue(R.isImplausible(257_203_665_000, previous: 4100), "the 4512345-BTC case")
        XCTAssertTrue(R.isImplausible(40, previous: 4100), "a 100x drop is equally suspect")
        XCTAssertFalse(R.isImplausible(4500, previous: 4100), "a real market move")
        XCTAssertFalse(R.isImplausible(4100, previous: nil), "nothing to compare against")
        XCTAssertFalse(R.isImplausible(4100, previous: 0))
    }

    @MainActor
    func testRefreshRefusesToWriteAnImplausibleValue() async throws {
        let ctx = try S.makeContext()
        let acc = Account(
            externalId: "x", type: .broker, institution: "R", name: "Crypto", currency: "EUR",
            liveValueSource: "crypto:bitcoin", assetQuantity: 4_512_345)
        ctx.insert(acc)
        ctx.insert(PortfolioValuation(
            account: acc, asOf: Date.now.addingTimeInterval(-86_400 * 3), marketValueEur: 4100))
        try ctx.save()

        let outcome = await R.run(in: ctx, crypto: StubPrices(["bitcoin": 57_000]))
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("far from the last"))
        let all = try CoreLogic.Investments.listValuations(for: [acc.id], in: ctx)
        XCTAssertEqual(all.count, 1, "the bad reading must not be stored")
    }

    @MainActor
    func testGuardComparesAgainstYesterdaySoTodayCanBeCorrected() async throws {
        let ctx = try S.makeContext()
        let acc = Account(
            externalId: "x", type: .broker, institution: "R", name: "Crypto", currency: "EUR",
            liveValueSource: "crypto:bitcoin", assetQuantity: Decimal(string: "0.07"))
        ctx.insert(acc)
        ctx.insert(PortfolioValuation(
            account: acc, asOf: Date.now.addingTimeInterval(-86_400), marketValueEur: 4000))
        // A bad value already written today, as happened on the device.
        ctx.insert(PortfolioValuation(account: acc, asOf: .now, marketValueEur: 257_203_665_000))
        try ctx.save()

        let outcome = await R.run(in: ctx, crypto: StubPrices(["bitcoin": 57_000]))
        XCTAssertEqual(outcome.updated, [acc.id])
        let all = try CoreLogic.Investments.listValuations(for: [acc.id], in: ctx)
        XCTAssertEqual(all.last?.marketValueEur, 3990, "today's bad row is overwritten")
    }

    func testCoinIdParsing() {
        XCTAssertEqual(R.coinId(from: "crypto:bitcoin"), "bitcoin")
        XCTAssertNil(R.coinId(from: "crypto:"), "empty id is not a source")
        XCTAssertNil(R.coinId(from: "t212"))
        XCTAssertNil(R.coinId(from: nil))
    }

    @MainActor
    func testLiveValuedAccountsSkipsArchivedAndUnsourced() throws {
        let ctx = try S.makeContext()
        let live = Account(
            externalId: "a", type: .broker, institution: "T", name: "Live", currency: "EUR",
            liveValueSource: "t212")
        let manual = Account(
            externalId: "b", type: .broker, institution: "M", name: "Manual", currency: "EUR")
        let archived = Account(
            externalId: "c", type: .broker, institution: "X", name: "Old", currency: "EUR",
            archived: true, liveValueSource: "crypto:bitcoin")
        ctx.insert(live); ctx.insert(manual); ctx.insert(archived)
        try ctx.save()

        let found = try R.liveValuedAccounts(in: ctx)
        XCTAssertEqual(found.map(\.name), ["Live"])
    }

    @MainActor
    func testRefreshRecordsCryptoValueFromQuantityTimesPrice() async throws {
        let ctx = try S.makeContext()
        let acc = Account(
            externalId: "x", type: .broker, institution: "R", name: "Crypto", currency: "EUR",
            liveValueSource: "crypto:bitcoin", assetQuantity: Decimal(string: "0.05"))
        ctx.insert(acc)
        try ctx.save()

        let outcome = await R.run(in: ctx, crypto: StubPrices(["bitcoin": 60_000]))
        XCTAssertEqual(outcome.updated, [acc.id])
        let v = try XCTUnwrap(CoreLogic.Investments.listValuations(for: [acc.id], in: ctx).last)
        XCTAssertEqual(v.marketValueEur, 3000)
    }

    @MainActor
    func testRefreshReportsAccountsMissingAQuantity() async throws {
        let ctx = try S.makeContext()
        let acc = Account(
            externalId: "x", type: .broker, institution: "R", name: "Crypto", currency: "EUR",
            liveValueSource: "crypto:bitcoin")
        ctx.insert(acc)
        try ctx.save()

        let outcome = await R.run(in: ctx, crypto: StubPrices(["bitcoin": 60_000]))
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("no quantity"))
    }

    @MainActor
    func testRefreshTwiceInADayOverwritesRatherThanStacking() async throws {
        let ctx = try S.makeContext()
        let acc = Account(
            externalId: "x", type: .broker, institution: "R", name: "Crypto", currency: "EUR",
            liveValueSource: "crypto:bitcoin", assetQuantity: 1)
        ctx.insert(acc)
        try ctx.save()

        _ = await R.run(in: ctx, crypto: StubPrices(["bitcoin": 50_000]))
        _ = await R.run(in: ctx, crypto: StubPrices(["bitcoin": 51_000]))
        let all = try CoreLogic.Investments.listValuations(for: [acc.id], in: ctx)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].marketValueEur, 51_000)
    }

    @MainActor
    func testOutcomeCountsTheLiveAccountsItLookedAt() async throws {
        let ctx = try S.makeContext()
        let none = await R.run(in: ctx, crypto: StubPrices([:]))
        XCTAssertEqual(none.liveAccounts, 0, "nothing to refresh")

        ctx.insert(Account(
            externalId: "x", type: .broker, institution: "R", name: "Crypto", currency: "EUR",
            liveValueSource: "crypto:bitcoin", assetQuantity: 1))
        try ctx.save()
        let one = await R.run(in: ctx, crypto: StubPrices(["bitcoin": 50_000]))
        XCTAssertEqual(one.liveAccounts, 1)
    }

    @MainActor
    func testAMissingTrading212KeyIsSaidInPlainWords() async throws {
        let ctx = try S.makeContext()
        try insertTrading212Account(ctx)

        let outcome = await R.run(in: ctx, keychain: StubKeys(t212: .notFound))
        XCTAssertEqual(outcome.failures, ["Trading 212: add the API key in Settings"])
    }

    // The keys can be read only while the phone is unlocked, which in the background it often isn't.
    @MainActor
    func testALockedKeychainIsSaidInPlainWords() async throws {
        let ctx = try S.makeContext()
        try insertTrading212Account(ctx)

        let outcome = await R.run(in: ctx, keychain: StubKeys(t212: .keychain(errSecInteractionNotAllowed)))
        XCTAssertEqual(outcome.failures, ["Trading 212: the API key can't be read until the iPhone is unlocked after a restart"])
    }

    @MainActor
    func testACryptoRateLimitIsSaidInPlainWords() async throws {
        let ctx = try S.makeContext()
        ctx.insert(Account(
            externalId: "x", type: .broker, institution: "R", name: "Crypto", currency: "EUR",
            liveValueSource: "crypto:bitcoin", assetQuantity: 1))
        try ctx.save()

        let outcome = await R.run(in: ctx, crypto: FailingPrices(error: CryptoPriceError(status: 429, body: "{}")))
        XCTAssertEqual(outcome.failures, ["Crypto prices: rate limited, try again later"])
    }

    @MainActor
    private func insertTrading212Account(_ ctx: ModelContext) throws {
        ctx.insert(Account(
            externalId: "t", type: .broker, institution: "T", name: "Broker", currency: "EUR",
            liveValueSource: R.trading212Source))
        try ctx.save()
    }

    // MARK: - Background schedule

    private let madrid = TimeZone(identifier: "Europe/Madrid")!

    private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = madrid
        return cal.date(from: DateComponents(year: 2030, month: month, day: day, hour: hour, minute: minute))!
    }

    func testTheNextBackgroundRunIsTheFirstSixInTheMorningAtLeastSixHoursAway() {
        XCTAssertEqual(R.nextBackgroundRun(after: local(3, 12, 22), timeZone: madrid), local(3, 13, 6),
                       "an evening run books the next morning")
        XCTAssertEqual(R.nextBackgroundRun(after: local(3, 12, 0), timeZone: madrid), local(3, 12, 6),
                       "exactly six hours away still counts")
        XCTAssertEqual(R.nextBackgroundRun(after: local(3, 12, 7, 30), timeZone: madrid), local(3, 13, 6),
                       "a morning run books tomorrow's")
        XCTAssertEqual(R.nextBackgroundRun(after: local(3, 12, 3), timeZone: madrid), local(3, 13, 6),
                       "not straight after a run in the small hours")
    }

    func testALaunchAfterMidnightKeepsTheMorningRunAlreadyBooked() {
        // Booked the evening before for 6:00; booking again at 1:00 would skip to the day after.
        XCTAssertNil(R.backgroundRunToBook(after: local(3, 13, 1), alreadyBooked: true, timeZone: madrid))
        XCTAssertEqual(R.backgroundRunToBook(after: local(3, 13, 1), alreadyBooked: false, timeZone: madrid),
                       local(3, 14, 6), "with nothing booked, the next run follows the usual rule")
    }

    func testTheNextBackgroundRunStaysAtSixAcrossAClockChange() {
        // Summer time starts on the night of 30 to 31 March 2030, and ends on that of 26 to 27 October.
        XCTAssertEqual(R.nextBackgroundRun(after: local(3, 30, 20), timeZone: madrid), local(3, 31, 6))
        XCTAssertEqual(R.nextBackgroundRun(after: local(10, 26, 22), timeZone: madrid), local(10, 27, 6))
    }
}

private struct FailingPrices: CryptoPriceSource {
    let error: any Error
    func prices(for coinIds: [String]) async throws -> [String: Decimal] { throw error }
}

private struct StubKeys: MarketKeys {
    let t212: MarketKeyError
    func loadTrading212() throws -> Trading212Credentials { throw t212 }
    func loadEODHD() throws -> String { throw MarketKeyError.notFound }
}

// Serves canned prices instead of hitting CoinGecko.
private struct StubPrices: CryptoPriceSource {
    let stub: [String: Decimal]
    init(_ stub: [String: Decimal]) { self.stub = stub }
    func prices(for coinIds: [String]) async throws -> [String: Decimal] {
        stub.filter { coinIds.contains($0.key) }
    }
}

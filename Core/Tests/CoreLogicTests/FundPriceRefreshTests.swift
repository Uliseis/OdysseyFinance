import XCTest
import SwiftData
import CoreModel
import CoreIntegrations
@testable import CoreLogic

@MainActor
final class FundPriceRefreshTests: XCTestCase {
    private typealias R = CoreLogic.InvestmentRefresh
    private typealias S = TransferTestSupport
    private typealias Entry = CoreLogic.FundPriceCache.Entry

    private let a = "ZZ0000000A00"
    private let b = "ZZ0000000B09"
    private let c = "ZZ0000000C08"
    private let key = "test-eodhd-key"

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    // March 2030: Friday the 1st, Monday the 11th, Wednesday the 13th.
    private func day(_ dd: Int, month: Int = 3) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2030, month: month, day: dd))!
    }

    private var now: Date { day(13).addingTimeInterval(9 * 3600) }

    private var source: FakeFundSource!
    private var cache: MemoryFundPriceCache!
    private var keys: FakeKeys!

    override func setUp() async throws {
        source = FakeFundSource()
        source.infos = [
            a: FundInfo(isin: a, name: "Example Fund A", currency: "EUR"),
            b: FundInfo(isin: b, name: "Example Fund B", currency: "EUR"),
        ]
        source.quotes = [
            a: FundQuote(isin: a, day: day(12), price: d("7.4321"), currency: "EUR"),
            b: FundQuote(isin: b, day: day(12), price: d("2.0468"), currency: "EUR"),
        ]
        cache = MemoryFundPriceCache()
        keys = FakeKeys(eodhd: key)
    }

    // 10 units of A, 4 of B, and C bought and sold out; 25.50 cash at the broker.
    private func makeAccount(_ ctx: ModelContext, cashAnchor: Decimal? = Decimal(string: "25.5")) throws -> Account {
        let acc = Account(
            externalId: "funds", type: .broker, institution: "Broker", name: "Funds", currency: "EUR",
            liveValueSource: R.fundsSource)
        ctx.insert(acc)
        for (isin, side, units, amount, dd) in [
            (a, FundTradeSide.buy, "10", "70", 4), (b, .buy, "4", "8", 5),
            (c, .buy, "3", "30", 6), (c, .sell, "3", "33", 20),
        ] {
            ctx.insert(FundTrade(account: acc, isin: isin, tradeDate: day(dd, month: 2), side: side,
                                 units: d(units), amountEur: d(amount)))
        }
        try ctx.save()
        try CoreLogic.FundTrades.setBrokerCashAnchor(acc, amountEur: cashAnchor, at: day(1), in: ctx)
        return acc
    }

    private func run(_ ctx: ModelContext, at time: Date? = nil) async -> R.Outcome {
        let source = self.source!
        return await R.run(in: ctx, keychain: keys!, fundPrices: { [key] apiKey in
            XCTAssertEqual(apiKey, key)
            return source
        }, fundPriceCache: cache, now: time ?? now)
    }

    private func valuations(_ acc: Account, _ ctx: ModelContext) throws -> [PortfolioValuation] {
        try CoreLogic.Investments.listValuations(for: [acc.id], in: ctx)
    }

    func testValueIsUnitsTimesPricePlusCash() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.updated, [acc.id])
        XCTAssertEqual(outcome.failures, [])
        let v = try XCTUnwrap(valuations(acc, ctx).last)
        XCTAssertEqual(v.marketValueEur, d("108.0082"), "10 × 7.4321 + 4 × 2.0468 + 25.50")
        XCTAssertEqual(v.cashValueEur, d("25.5"))
        XCTAssertEqual(v.notes, "auto: funds")
        XCTAssertEqual(source.latests, [a, b], "nothing fetched for the sold-out fund")
        XCTAssertEqual(cache.cache.funds[a], Entry(
            name: "Example Fund A", currency: "EUR", price: d("7.4321"), priceDay: day(12), fetchedDay: day(13)))
        XCTAssertEqual(cache.cache.requestDay, day(13))
        XCTAssertEqual(cache.cache.requestCount, 4, "two lookups and two prices")
    }

    func testASecondRunTheSameUTCDayMakesNoRequests() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        _ = await run(ctx)
        let lookups = source.lookups, latests = source.latests

        let outcome = await run(ctx, at: now.addingTimeInterval(10 * 3600))

        XCTAssertEqual(source.lookups, lookups)
        XCTAssertEqual(source.latests, latests)
        XCTAssertEqual(outcome.updated, [acc.id])
        XCTAssertEqual(try valuations(acc, ctx).count, 1)
        XCTAssertEqual(cache.cache.requestCount, 4)
    }

    func testNameAndCurrencyAreLookedUpOnce() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        _ = await run(ctx)
        source.quotes[a] = FundQuote(isin: a, day: day(13), price: d("7.5"), currency: "EUR")

        _ = await run(ctx, at: day(14).addingTimeInterval(9 * 3600))

        XCTAssertEqual(source.lookups, [a, b])
        XCTAssertEqual(source.latests, [a, b, a, b])
        XCTAssertEqual(cache.cache.requestCount, 2, "the count starts again each UTC day")
        XCTAssertEqual(cache.cache.funds[a]?.price, d("7.5"))
        XCTAssertEqual(cache.cache.funds[a]?.previousPrice, d("7.4321"))
    }

    func testTheDailyCapStopsRequestsAndNamesTheFundsLeftOut() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cache.cache.funds = [
            a: Entry(name: "Example Fund A", currency: "EUR", price: d("7.4"), priceDay: day(11), fetchedDay: day(12)),
            b: Entry(name: "Example Fund B", currency: "EUR", price: d("2.05"), priceDay: day(11), fetchedDay: day(12)),
        ]
        cache.cache.requestDay = day(13)
        cache.cache.requestCount = R.fundRequestsPerDay - 1

        let outcome = await run(ctx)

        XCTAssertEqual(source.latests, [a])
        XCTAssertEqual(cache.cache.requestCount, R.fundRequestsPerDay)
        XCTAssertEqual(cache.cache.funds[b]?.price, d("2.05"), "B keeps its cached price")
        XCTAssertEqual(outcome.updated, [acc.id], "a cached price a day old still values the account")
        XCTAssertEqual(try valuations(acc, ctx).last?.marketValueEur, d("108.021"), "10 × 7.4321 + 4 × 2.05 + 25.50")
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("Example Fund B"), outcome.failures[0])
        XCTAssertFalse(outcome.failures[0].contains("Example Fund A"), outcome.failures[0])

        _ = await run(ctx, at: day(14).addingTimeInterval(3600))
        XCTAssertEqual(source.latests, [a, a, b], "the next UTC day fetches both again")
    }

    func testTheDailyLimitAnswerStopsRequestsForTheDay() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        source.latestErrors[a] = .rateLimited

        let outcome = await run(ctx)

        XCTAssertEqual(source.lookups, [a], "no request for B after EODHD says the limit is reached")
        XCTAssertEqual(source.latests, [a])
        XCTAssertEqual(cache.cache.requestCount, R.fundRequestsPerDay)
        XCTAssertTrue(outcome.updated.isEmpty, "neither fund has a price yet")
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("Example Fund A"), outcome.failures[0])
        XCTAssertTrue(outcome.failures[0].contains(b), "B was never looked up, so its ISIN names it")
    }

    func testAStalePriceIsRefused() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        source.quotes[a] = FundQuote(isin: a, day: day(6), price: d("7.4321"), currency: "EUR")

        let outcome = await run(ctx)

        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("Example Fund A"), outcome.failures[0])
        XCTAssertTrue(outcome.failures[0].contains("from 2030-03-06, more than 4 business days"), outcome.failures[0])
        XCTAssertFalse(outcome.failures[0].contains("Example Fund B"), outcome.failures[0])
        XCTAssertEqual(try valuations(acc, ctx).count, 0)
    }

    func testBusinessDaysCountWeekdaysOnly() {
        XCTAssertEqual(R.businessDays(after: day(7), through: now), 4, "Thursday to Wednesday")
        XCTAssertEqual(R.businessDays(after: day(6), through: now), 5)
        XCTAssertEqual(R.businessDays(after: day(8), through: day(11)), 1, "Friday to Monday")
        XCTAssertEqual(R.businessDays(after: day(13), through: now), 0)
    }

    func testAJumpOverFifteenPercentIsRefusedAndTheCacheKeepsItsPrice() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        let oldA = Entry(name: "Example Fund A", currency: "EUR", price: d("7.4321"), priceDay: day(11),
                         fetchedDay: day(11), previousPrice: d("7.4"))
        cache.cache.funds = [
            a: oldA,
            b: Entry(name: "Example Fund B", currency: "EUR", price: d("2.0468"), priceDay: day(11), fetchedDay: day(11)),
        ]
        source.quotes[a] = FundQuote(isin: a, day: day(12), price: d("8.6"), currency: "EUR")
        source.quotes[b] = FundQuote(isin: b, day: day(12), price: d("2.3"), currency: "EUR")

        let outcome = await run(ctx)

        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("Example Fund A"), outcome.failures[0])
        XCTAssertTrue(outcome.failures[0].contains("15%"), outcome.failures[0])
        XCTAssertEqual(try valuations(acc, ctx).count, 0)
        let a2 = try XCTUnwrap(cache.cache.funds[a])
        XCTAssertEqual([a2.price, a2.previousPrice], [oldA.price, oldA.previousPrice])
        XCTAssertEqual(a2.priceDay, oldA.priceDay)
        XCTAssertEqual(cache.cache.funds[b]?.price, d("2.3"), "a 12% move is a market move")
        XCTAssertEqual(cache.cache.funds[b]?.previousPrice, d("2.0468"))
    }

    func testANavRepublishedForTheSameDayIsCheckedAgainstTheDayBefore() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cache.cache.funds = [
            a: Entry(name: "Example Fund A", currency: "EUR", price: d("9.9"), priceDay: day(12),
                     fetchedDay: day(12), previousPrice: d("7.4")),
            b: Entry(name: "Example Fund B", currency: "EUR", price: d("2.0468"), priceDay: day(12), fetchedDay: day(13)),
        ]
        source.quotes[a] = FundQuote(isin: a, day: day(12), price: d("7.4321"), currency: "EUR")

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.updated, [acc.id], "\(outcome.failures)")
        XCTAssertEqual(cache.cache.funds[a]?.price, d("7.4321"), "the corrected NAV replaces the wrong one")
        XCTAssertEqual(cache.cache.funds[a]?.previousPrice, d("7.4"))
    }

    func testAFundNotQuotedInEuroIsRefused() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        source.infos[b] = FundInfo(isin: b, name: "Example Fund B", currency: "USD")

        let outcome = await run(ctx)

        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("Example Fund B"), outcome.failures[0])
        XCTAssertTrue(outcome.failures[0].contains("USD"), outcome.failures[0])
        XCTAssertEqual(source.latests, [a], "no request for a price that can't be used")
        XCTAssertEqual(try valuations(acc, ctx).count, 0)
    }

    func testAFundWithoutAPriceIsRefused() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        source.infos[b] = nil

        let outcome = await run(ctx)

        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains(b), outcome.failures[0])
        XCTAssertEqual(try valuations(acc, ctx).count, 0)
    }

    func testWithoutTheEODHDKeyNothingIsFetchedOrSaved() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        keys = FakeKeys(eodhd: nil)

        let outcome = await run(ctx)

        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("add the EODHD key in Settings"), outcome.failures[0])
        XCTAssertEqual(source.lookups + source.latests, [])
        XCTAssertEqual(try valuations(acc, ctx).count, 0)
    }

    func testAKeychainThatCantBeReadDoesntAskForTheKeyAgain() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        keys = FakeKeys(eodhd: nil, error: .keychain(errSecInteractionNotAllowed))

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("couldn't be read"), outcome.failures[0])
        XCTAssertFalse(outcome.failures[0].contains("Settings"), outcome.failures[0])
        XCTAssertEqual(source.lookups + source.latests, [])
        XCTAssertEqual(try valuations(acc, ctx).count, 0)
    }

    func testWithoutABrokerCashAnchorNothingIsFetchedOrSaved() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx, cashAnchor: nil)

        let outcome = await run(ctx)

        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("set the cash at the broker first"), outcome.failures[0])
        XCTAssertEqual(source.lookups + source.latests, [])
        XCTAssertEqual(try valuations(acc, ctx).count, 0)
    }

    func testTheImplausibleValueGuardStillApplies() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        ctx.insert(PortfolioValuation(account: acc, asOf: day(12), marketValueEur: 1))
        try ctx.save()

        let outcome = await run(ctx)

        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertTrue(outcome.failures.contains { $0.contains("far from the last") }, "\(outcome.failures)")
        XCTAssertEqual(try valuations(acc, ctx).count, 1)
    }
}

@MainActor
private final class FakeFundSource: FundPriceSource {
    var infos: [String: FundInfo] = [:]
    var quotes: [String: FundQuote] = [:]
    var latestErrors: [String: FundPriceError] = [:]
    private(set) var lookups: [String] = []
    private(set) var latests: [String] = []

    func lookup(isin: String) async throws -> FundInfo {
        lookups.append(isin)
        guard let info = infos[isin] else { throw FundPriceError.notFound }
        return info
    }

    func latest(isin: String, currency: String) async throws -> FundQuote {
        latests.append(isin)
        if let error = latestErrors[isin] { throw error }
        guard let quote = quotes[isin] else { throw FundPriceError.notFound }
        return quote
    }
}

private final class MemoryFundPriceCache: FundPriceCacheStore {
    var cache = CoreLogic.FundPriceCache()
    func load() -> CoreLogic.FundPriceCache { cache }
    func save(_ cache: CoreLogic.FundPriceCache) throws { self.cache = cache }
}

private struct FakeKeys: MarketKeys {
    let eodhd: String?
    var error = MarketKeyError.notFound
    func loadTrading212() throws -> Trading212Credentials { throw MarketKeyError.notFound }
    func loadEODHD() throws -> String {
        guard let eodhd else { throw error }
        return eodhd
    }
}

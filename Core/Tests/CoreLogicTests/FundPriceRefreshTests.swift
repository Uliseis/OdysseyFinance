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

    private func run(
        _ ctx: ModelContext, at time: Date? = nil, store: (any FundPriceCacheStore)? = nil
    ) async -> R.Outcome {
        let source = self.source!
        return await R.run(in: ctx, keychain: keys!, fundPrices: { [key] apiKey in
            XCTAssertEqual(apiKey, key)
            return source
        }, fundPriceCache: store ?? cache, now: time ?? now)
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
        XCTAssertEqual(outcome.notices, ["Funds: values recorded for 1 day (12 Mar)."])
        let v = try XCTUnwrap(valuations(acc, ctx).last)
        XCTAssertEqual(v.marketValueEur, d("108.01"), "10 × 7.4321 + 4 × 2.0468 + 25.50, in cents")
        XCTAssertEqual(v.cashValueEur, d("25.5"))
        XCTAssertEqual(v.notes, "auto: funds")
        XCTAssertEqual(v.asOf, day(12), "dated by the prices, not the refresh")
        XCTAssertEqual(source.latests, [a, b], "nothing fetched for the sold-out fund")
        XCTAssertEqual(cache.cache.funds[a], Entry(
            name: "Example Fund A", currency: "EUR", price: d("7.4321"), priceDay: day(12), fetchedDay: day(13),
            history: [.init(date: day(12), priceEur: d("7.4321"))]))
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
        XCTAssertEqual(outcome.updated, [])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, ["Funds: no new prices since 12 Mar."])
        XCTAssertEqual(try valuations(acc, ctx).count, 1)
        XCTAssertEqual(cache.cache.requestCount, 4)
    }

    func testTheCacheIsSavedBeforeAndAfterEveryRequest() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)

        _ = await run(ctx)

        XCTAssertEqual(cache.saves.map(\.requestCount), [1, 1, 2, 2, 3, 3, 4, 4])
        XCTAssertEqual(cache.saves[1].funds[a]?.name, "Example Fund A")
        XCTAssertNil(cache.saves[2].funds[a]?.price)
        XCTAssertEqual(cache.saves[3].funds[a]?.price, d("7.4321"))
    }

    func testARequestIsCountedInTheSavedCacheWhileItIsOut() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        let store = cache!
        var savedCounts: [Int] = []
        source.onRequest = { savedCounts.append(store.cache.requestCount) }

        _ = await run(ctx)

        XCTAssertEqual(savedCounts, [1, 2, 3, 4], "a process killed mid-request still counts it")
    }

    func testACacheThatCantBeSavedIsANoticeOnce() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cache.saveError = CocoaError(.fileWriteNoPermission)

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.updated, [acc.id])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices.filter { $0.contains("weren't cached") }.count, 1, "\(outcome.notices)")
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
        XCTAssertEqual(try valuations(acc, ctx).last?.marketValueEur, d("108.02"), "10 × 7.4321 + 4 × 2.05 + 25.50")
        XCTAssertEqual(outcome.failures, [], "a value saved from a cached price is no failure")
        XCTAssertEqual(outcome.notices.count, 2, "\(outcome.notices)")
        XCTAssertEqual(outcome.notices[1], "Funds: values recorded for 1 day (12 Mar).")
        XCTAssertTrue(outcome.notices[0].contains("Example Fund B"), outcome.notices[0])
        XCTAssertTrue(outcome.notices[0].contains("no EODHD requests left today"), outcome.notices[0])
        XCTAssertFalse(outcome.notices[0].contains("Example Fund A"), outcome.notices[0])

        _ = await run(ctx, at: day(14).addingTimeInterval(3600))
        XCTAssertEqual(source.latests, [a, a, b], "the next UTC day fetches both again")
    }

    // Without its request count the cache can't be read.
    private let unreadable = Data(#"{"funds": {"ZZ0000000A00": {"name": "Example Fund A", "currency": "EUR"}}}"#.utf8)

    private func unreadableCacheFile(modified: Date) throws -> FundPriceCacheFile {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fund-price-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "fund-prices.json")
        try unreadable.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        return FundPriceCacheFile(url: url)
    }

    func testAnUnreadableCacheWrittenTodayMakesNoRequestsAndIsLeftAsItIs() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        let file = try unreadableCacheFile(modified: day(13).addingTimeInterval(3600))

        let outcome = await run(ctx, store: file)

        XCTAssertEqual(source.lookups + source.latests, [], "it can't say how many requests today made")
        XCTAssertEqual(try Data(contentsOf: file.url), unreadable, "an empty cache would drop its prices and held jumps")
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(try valuations(acc, ctx).count, 0)
        XCTAssertEqual(outcome.notices, ["The fund price cache couldn't be read; no fund prices are fetched today."])
    }

    func testAnUnreadableCacheWrittenBeforeTodayIsReplacedByTheRequestsMadeNow() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        let file = try unreadableCacheFile(modified: day(12).addingTimeInterval(20 * 3600))

        let outcome = await run(ctx, store: file)

        XCTAssertEqual(source.lookups, [a, b], "counts are saved before each request, so it counted none today")
        XCTAssertEqual(source.latests, [a, b])
        let replaced = try XCTUnwrap(file.load(), "replaced by a cache that can be read")
        XCTAssertEqual(replaced.requestDay, day(13))
        XCTAssertEqual(replaced.requestCount, 4)
        XCTAssertEqual(replaced.funds[a]?.price, d("7.4321"))
        XCTAssertEqual(outcome.updated, [acc.id], "\(outcome.failures)")
        XCTAssertEqual(try valuations(acc, ctx).last?.marketValueEur, d("108.01"))
        XCTAssertEqual(outcome.notices,
                       ["The fund price cache couldn't be read; it starts again from the prices fetched now.",
                        "Funds: values recorded for 1 day (12 Mar)."])
    }

    func testAnUnreadableCacheOfUnknownAgeMakesNoRequests() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        cache.unreadable = true

        let outcome = await run(ctx)

        XCTAssertEqual(source.lookups + source.latests, [])
        XCTAssertEqual(cache.saves.count, 0)
        XCTAssertEqual(outcome.notices, ["The fund price cache couldn't be read; no fund prices are fetched today."])
    }

    func testTheDailyLimitAnswerStopsRequestsForTheDay() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        source.latestErrors[a] = FundPriceError.rateLimited

        let outcome = await run(ctx)

        XCTAssertEqual(source.lookups, [a], "no request for B after EODHD says the limit is reached")
        XCTAssertEqual(source.latests, [a])
        XCTAssertEqual(cache.cache.requestCount, R.fundRequestsPerDay)
        XCTAssertTrue(outcome.updated.isEmpty, "neither fund has a price yet")
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("Example Fund A"), outcome.failures[0])
        XCTAssertTrue(outcome.failures[0].contains(b), "B was never looked up, so its ISIN names it")
    }

    func testOverlappingRunsShareOneSetOfRequests() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        source.delay = .milliseconds(20)

        let first = Task { await run(ctx) }
        let second = Task { await run(ctx) }
        let outcomes = [await first.value, await second.value]

        XCTAssertEqual(source.lookups, [a, b])
        XCTAssertEqual(source.latests, [a, b])
        XCTAssertEqual(cache.cache.requestCount, 4)
        XCTAssertEqual(outcomes[0], outcomes[1], "the second call gets the first one's outcome")
        XCTAssertEqual(outcomes[1].updated, [acc.id])
        XCTAssertEqual(try valuations(acc, ctx).count, 1)
    }

    func testACallerCancelledMidRunDoesntCutItShortForTheOthers() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        source.delay = .milliseconds(20)
        var first: Task<R.Outcome, Never>?
        source.onRequest = { first?.cancel() }

        first = Task { await run(ctx) }
        let second = Task { await run(ctx) }
        let outcome = await second.value
        _ = await first?.value

        XCTAssertEqual(source.lookups, [a, b])
        XCTAssertEqual(source.latests, [a, b])
        XCTAssertEqual(cache.cache.requestCount, 4)
        XCTAssertEqual(outcome.updated, [acc.id], "\(outcome.failures)")
        XCTAssertEqual(try valuations(acc, ctx).count, 1)
    }

    // What an expiring background task calls: iOS suspends the app right after.
    func testCancelStopsTheRunningRefresh() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        source.delay = .seconds(30)
        source.onRequest = { R.cancel() }

        let outcome = await run(ctx)

        XCTAssertEqual(source.lookups, [a], "no request after the cancel")
        XCTAssertEqual(source.latests, [])
        XCTAssertEqual(cache.cache.requestCount, 0, "the request it cut short isn't counted")
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(try valuations(acc, ctx).count, 0)

        source.delay = .zero
        source.onRequest = nil
        let next = await run(ctx)
        XCTAssertEqual(next.updated, [acc.id], "the next run isn't affected: \(next.failures)")
    }

    func testARequestEndingInCancellationIsNotCountedAndEndsTheRequests() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        source.latestErrors[a] = URLError(.cancelled)

        _ = await run(ctx)

        XCTAssertEqual(source.lookups, [a])
        XCTAssertEqual(source.latests, [a])
        XCTAssertEqual(cache.cache.requestCount, 1, "the lookup counts, the cancelled request doesn't")

        let ctx2 = try S.makeContext()
        _ = try makeAccount(ctx2)
        source = FakeFundSource()
        source.lookupErrors[a] = CancellationError()
        cache = MemoryFundPriceCache()

        _ = await run(ctx2)

        XCTAssertEqual(source.lookups, [a])
        XCTAssertEqual(cache.cache.requestCount, 0)
    }

    func testARejectedKeyStopsTheRunsRequestsAndIsReportedOnce() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        source.lookupErrors[a] = FundPriceError.unauthorized

        let outcome = await run(ctx)

        XCTAssertEqual(source.lookups, [a], "no request for B after EODHD rejects the key")
        XCTAssertEqual(source.latests, [])
        XCTAssertEqual(cache.cache.requestCount, 1)
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(outcome.failures.first, "EODHD rejected the key; check it in Settings.")
        XCTAssertEqual(outcome.failures.filter { $0.contains("key") }.count, 1, "\(outcome.failures)")
        XCTAssertEqual(outcome.notices.filter { $0.contains("key") }, [])
    }

    func testARejectedKeyStillValuesFromFreshCachedPrices() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cache.cache.funds = [
            a: Entry(name: "Example Fund A", currency: "EUR", price: d("7.4"), priceDay: day(12), fetchedDay: day(12)),
            b: Entry(name: "Example Fund B", currency: "EUR", price: d("2.05"), priceDay: day(12), fetchedDay: day(12)),
        ]
        source.latestErrors[a] = FundPriceError.unauthorized

        let outcome = await run(ctx)

        XCTAssertEqual(source.latests, [a])
        XCTAssertEqual(outcome.updated, [acc.id])
        XCTAssertEqual(outcome.failures, ["EODHD rejected the key; check it in Settings."])
    }

    func testAPriceEODHDDoesntHaveIsAskedForOnceADay() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        source.quotes[b] = nil

        let first = await run(ctx)
        _ = await run(ctx, at: now.addingTimeInterval(8 * 3600))

        XCTAssertTrue(first.failures.first?.contains("EODHD has no recent price for it") == true, "\(first.failures)")
        XCTAssertEqual(source.latests, [a, b], "the second run asks again for neither")
        XCTAssertEqual(cache.cache.requestCount, 4)

        _ = await run(ctx, at: day(14).addingTimeInterval(3600))
        XCTAssertEqual(source.latests, [a, b, a, b])
    }

    func testAFundEODHDDoesntListIsLookedUpOnceADay() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        source.infos[b] = nil

        _ = await run(ctx)
        let second = await run(ctx, at: now.addingTimeInterval(8 * 3600))

        XCTAssertEqual(source.lookups, [a, b])
        XCTAssertEqual(cache.cache.requestCount, 3)
        XCTAssertTrue(second.failures.first?.contains("\(b): no price yet (EODHD doesn't list this ISIN as a fund)") == true,
                      "\(second.failures)")

        _ = await run(ctx, at: day(14).addingTimeInterval(3600))
        XCTAssertEqual(source.lookups, [a, b, b])
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

    private let oldA = Entry(name: "Example Fund A", currency: "EUR", price: Decimal(string: "7.4321"),
                             priceDay: nil, fetchedDay: nil, previousPrice: Decimal(string: "7.4"))

    // A priced on Monday the 11th; Tuesday's NAV is 8.6, a 16% jump. B moves 12%.
    private func cacheBeforeAJump() {
        var a0 = oldA
        a0.priceDay = day(11)
        a0.fetchedDay = day(11)
        cache.cache.funds = [
            a: a0,
            b: Entry(name: "Example Fund B", currency: "EUR", price: d("2.0468"), priceDay: day(11), fetchedDay: day(11)),
        ]
        source.quotes[a] = FundQuote(isin: a, day: day(12), price: d("8.6"), currency: "EUR")
        source.quotes[b] = FundQuote(isin: b, day: day(12), price: d("2.3"), currency: "EUR")
    }

    // Values stop at the day before the refused price: B's newer price waits for A's.
    func testAJumpOverFifteenPercentIsRefusedAndHeldUntilConfirmed() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cacheBeforeAJump()

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.updated, [acc.id])
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("Example Fund A: new price awaiting confirmation"), outcome.failures[0])
        XCTAssertTrue(outcome.failures[0].contains("15%"), outcome.failures[0])
        XCTAssertTrue(outcome.failures[0].contains("no value after 11 Mar"), outcome.failures[0])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.map(\.asOf), [day(11)])
        XCTAssertEqual(values.map(\.marketValueEur), [d("108.01")], "10 × 7.4321 + 4 × 2.0468 + 25.50: both of the 11th")
        let a2 = try XCTUnwrap(cache.cache.funds[a])
        XCTAssertEqual([a2.price, a2.previousPrice], [oldA.price, oldA.previousPrice])
        XCTAssertEqual(a2.priceDay, day(11))
        XCTAssertEqual(a2.pendingPrice, d("8.6"))
        XCTAssertEqual(a2.pendingDay, day(12))
        XCTAssertEqual(cache.cache.funds[b]?.price, d("2.3"), "a 12% move is a market move")
        XCTAssertEqual(cache.cache.funds[b]?.previousPrice, d("2.0468"))
        XCTAssertNil(cache.cache.funds[b]?.pendingPrice)
    }

    func testARefusedJumpRefusesEveryRunThatDay() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cacheBeforeAJump()

        let first = await run(ctx)
        let second = await run(ctx, at: now.addingTimeInterval(8 * 3600))

        for outcome in [first, second] {
            XCTAssertEqual(outcome.failures.count, 1)
            XCTAssertTrue(outcome.failures.first?.contains("Example Fund A: new price awaiting confirmation") == true,
                          "\(outcome.failures)")
        }
        XCTAssertEqual(second.updated, [])
        XCTAssertEqual(second.notices, ["Funds: no new prices since 11 Mar."])
        XCTAssertEqual(source.latests, [a, b], "the second run fetches nothing")
        XCTAssertEqual(try valuations(acc, ctx).map(\.asOf), [day(11)])
    }

    func testTheSameRefusedNavFetchedAgainIsNoConfirmation() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cacheBeforeAJump()
        _ = await run(ctx)

        let outcome = await run(ctx, at: day(14).addingTimeInterval(9 * 3600))

        XCTAssertEqual(source.latests, [a, b, a, b])
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertTrue(outcome.failures.first?.contains("awaiting confirmation") == true, "\(outcome.failures)")
        XCTAssertEqual(cache.cache.funds[a]?.pendingDay, day(12))
        XCTAssertEqual(try valuations(acc, ctx).map(\.asOf), [day(11)])
    }

    func testALaterDayAgreeingWithARefusedJumpConfirmsIt() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cacheBeforeAJump()
        _ = await run(ctx)
        source.quotes[a] = FundQuote(isin: a, day: day(13), price: d("8.7"), currency: "EUR")

        let outcome = await run(ctx, at: day(14).addingTimeInterval(9 * 3600))

        XCTAssertEqual(outcome.updated, [acc.id], "\(outcome.failures)")
        XCTAssertEqual(outcome.failures, [])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.map(\.asOf), [day(11), day(12), day(13)])
        XCTAssertEqual(values.map(\.marketValueEur).suffix(2), [d("120.7"), d("121.7")],
                       "10 × 8.6 + 4 × 2.3 + 25.50 on the 12th: the confirmed price values its own day")
        let a2 = try XCTUnwrap(cache.cache.funds[a])
        XCTAssertEqual(a2.price, d("8.7"))
        XCTAssertEqual(a2.priceDay, day(13))
        XCTAssertEqual(a2.previousPrice, d("8.6"), "the confirmed price is the day before")
        XCTAssertEqual(a2.history.map(\.priceEur), [d("7.4321"), d("8.6"), d("8.7")])
        XCTAssertNil(a2.pendingPrice)
        XCTAssertNil(a2.pendingDay)
    }

    func testALaterDayBackNearTheOldPriceClearsARefusedJump() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cacheBeforeAJump()
        _ = await run(ctx)
        source.quotes[a] = FundQuote(isin: a, day: day(13), price: d("7.45"), currency: "EUR")

        let outcome = await run(ctx, at: day(14).addingTimeInterval(9 * 3600))

        XCTAssertEqual(outcome.updated, [acc.id], "\(outcome.failures)")
        XCTAssertEqual(try valuations(acc, ctx).map(\.marketValueEur), [d("108.01"), d("109.02"), d("109.2")],
                       "the dropped price never values a day: the 12th takes A's price of the 11th")
        let a2 = try XCTUnwrap(cache.cache.funds[a])
        XCTAssertEqual(a2.price, d("7.45"))
        XCTAssertEqual(a2.previousPrice, d("7.4321"))
        XCTAssertEqual(a2.history.map(\.date), [day(11), day(13)])
        XCTAssertNil(a2.pendingPrice)
        XCTAssertNil(a2.pendingDay)
    }

    // A price older than a usable one says nothing about how far the market has moved since.
    func testAJumpFromAStaleCachedPriceIsAccepted() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        cache.cache.funds = [
            a: Entry(name: "Example Fund A", currency: "EUR", price: d("6"), priceDay: day(1),
                     fetchedDay: day(1), previousPrice: d("5.9")),
            b: Entry(name: "Example Fund B", currency: "EUR", price: d("2.0468"), priceDay: day(11), fetchedDay: day(11)),
        ]

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.updated, [acc.id], "\(outcome.failures)")
        let a2 = try XCTUnwrap(cache.cache.funds[a])
        XCTAssertEqual(a2.price, d("7.4321"), "a 24% move over seven business days")
        XCTAssertNil(a2.previousPrice, "the stale price isn't kept as a reference")
        XCTAssertNil(a2.pendingPrice)
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
        keys = FakeKeys(eodhd: nil, error: .keychain(errSecDecode))

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("couldn't be read"), outcome.failures[0])
        XCTAssertFalse(outcome.failures[0].contains("Settings"), outcome.failures[0])
        XCTAssertEqual(source.lookups + source.latests, [])
        XCTAssertEqual(try valuations(acc, ctx).count, 0)
    }

    func testALockedKeychainSaysThePhoneIsLocked() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        keys = FakeKeys(eodhd: nil, error: .keychain(errSecInteractionNotAllowed))

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.failures, ["Funds: the EODHD key can't be read until the iPhone is unlocked after a restart; not saved."])
        XCTAssertEqual(source.lookups + source.latests, [])
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

    // MARK: - Dated values and gaps

    private func prices(_ isin: String, _ rows: [(Int, String)], month: Int = 3) -> [FundQuote] {
        rows.map { FundQuote(isin: isin, day: day($0.0, month: month), price: d($0.1), currency: "EUR") }
    }

    private func value(_ acc: Account, _ ctx: ModelContext, on dd: Int, _ eur: String) throws {
        ctx.insert(PortfolioValuation(account: acc, asOf: day(dd).addingTimeInterval(22 * 3600), marketValueEur: d(eur)))
        try ctx.save()
    }

    // Last valued on Monday the 4th, run on Tuesday the 12th with prices up to Monday the 11th.
    // 100 paid in on Wednesday the 6th, 2 more units of A bought for 15 on Thursday the 7th.
    func testAGapIsFilledWithOneValuePerWeekdayFromTheUnitsAndCashOfEachDay() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try value(acc, ctx, on: 4, "100")
        _ = S.makeTx(ctx, account: acc, amount: 100, direction: .credit, bookedAt: day(6), isTransfer: true)
        ctx.insert(FundTrade(account: acc, isin: a, tradeDate: day(7), side: .buy, units: 2, amountEur: 15))
        try ctx.save()
        source.series[a] = prices(a, [(4, "7"), (5, "7.1"), (6, "7.2"), (7, "7.3"), (8, "7.4"), (11, "7.5")])
        source.series[b] = prices(b, [(4, "2"), (5, "2.01"), (6, "2.02"), (7, "2.03"), (8, "2.04"), (11, "2.05")])

        let outcome = await run(ctx, at: day(12).addingTimeInterval(9 * 3600))

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.updated, [acc.id])
        XCTAssertEqual(outcome.notices, ["Funds: values recorded for 5 days (5–11 Mar)."])
        let auto = try valuations(acc, ctx).dropFirst()
        XCTAssertEqual(auto.map(\.asOf), [day(5), day(6), day(7), day(8), day(11)], "no weekend")
        XCTAssertEqual(auto.map(\.marketValueEur), [d("104.54"), d("205.58"), d("206.22"), d("207.46"), d("208.7")],
                       "10 × A + 4 × B + cash; 12 units of A from the 7th")
        XCTAssertEqual(auto.map(\.cashValueEur), [d("25.5"), d("125.5"), d("110.5"), d("110.5"), d("110.5")])
        XCTAssertEqual(Set(auto.map(\.notes)), ["auto: funds"])
        XCTAssertEqual(source.sinces, [a: day(15, month: 2), b: day(15, month: 2)],
                       "from a week before the first day a refresh may correct, earlier than the last value")
        XCTAssertEqual(cache.cache.funds[a]?.history.count, 6)
    }

    func testFundsWithDifferentNewestDaysValueTheNewestDayWithEachOnesLatestPrice() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try value(acc, ctx, on: 11, "100")
        source.series[a] = prices(a, [(11, "7.3"), (12, "7.4"), (13, "7.5")])
        source.series[b] = prices(b, [(11, "2"), (12, "2.05")])

        let outcome = await run(ctx, at: day(14).addingTimeInterval(9 * 3600))

        XCTAssertEqual(outcome.notices, ["Funds: values recorded for 2 days (12–13 Mar)."])
        let auto = try valuations(acc, ctx).dropFirst()
        XCTAssertEqual(auto.map(\.asOf), [day(12), day(13)])
        XCTAssertEqual(auto.map(\.marketValueEur), [d("107.7"), d("108.7")], "the 13th takes B's price of the 12th")
    }

    func testADayWithAFundPricedNoLaterThanAWeekBeforeIsLeftOutAndNamed() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try value(acc, ctx, on: 1, "100")
        source.series[a] = prices(a, [(1, "7"), (4, "7"), (5, "7"), (6, "7"), (7, "7"), (8, "7"), (11, "7"), (12, "7"), (13, "7")])
        source.series[b] = prices(b, [(1, "2"), (4, "2"), (13, "2")])

        let outcome = await run(ctx, at: day(14).addingTimeInterval(9 * 3600))

        XCTAssertEqual(try valuations(acc, ctx).dropFirst().map(\.asOf),
                       [day(4), day(5), day(6), day(7), day(8), day(11), day(13)])
        XCTAssertEqual(outcome.failures,
                       ["Funds: 1 day not valued (12 Mar): no price in the week before for Example Fund B."])
        XCTAssertEqual(outcome.notices, ["Funds: values recorded for 7 days (4–13 Mar)."])
    }

    // A is priced from Monday the 11th at a level 20% up; the series stops at Friday the 8th
    // and the newest price waits for a later day's.
    func testAMoveOverFifteenPercentInsideTheSeriesStopsTheValuesBeforeIt() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try value(acc, ctx, on: 7, "100")
        let moved: [(Int, String)] = [(7, "7"), (8, "7.1"), (11, "8.5"), (12, "8.6")]
        source.series[a] = prices(a, moved)
        source.series[b] = prices(b, [(7, "2"), (8, "2"), (11, "2"), (12, "2")])

        let first = await run(ctx)

        XCTAssertEqual(try valuations(acc, ctx).dropFirst().map(\.asOf), [day(8)])
        XCTAssertEqual(first.failures.count, 1)
        XCTAssertTrue(first.failures[0].contains("Example Fund A: new price awaiting confirmation"), first.failures[0])
        XCTAssertEqual(cache.cache.funds[a]?.priceDay, day(8))
        XCTAssertEqual(cache.cache.funds[a]?.pendingDay, day(12))

        // A later day at the new level confirms the move and the days leading up to it.
        source.series[a] = prices(a, moved + [(13, "8.7")])
        source.series[b] = prices(b, [(7, "2"), (8, "2"), (11, "2"), (12, "2"), (13, "2")])
        let second = await run(ctx, at: day(14).addingTimeInterval(9 * 3600))

        XCTAssertEqual(second.failures, [])
        let auto = try valuations(acc, ctx).dropFirst()
        XCTAssertEqual(auto.map(\.asOf), [day(8), day(11), day(12), day(13)])
        XCTAssertEqual(auto.map(\.marketValueEur), [d("104.5"), d("118.5"), d("119.5"), d("120.5")])
    }

    // Written by a refresh that dated values by the time it ran, with older prices.
    func testAnAutomaticValueAlreadyOnTheNewestPriceDayIsReplaced() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        ctx.insert(PortfolioValuation(account: acc, asOf: day(12).addingTimeInterval(9 * 3600), marketValueEur: 99,
                                      notes: "auto: funds"))
        try ctx.save()

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.notices, ["Funds: values recorded for 1 day (12 Mar)."])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].marketValueEur, d("108.01"))
        XCTAssertEqual(values[0].asOf, day(12))
        XCTAssertEqual(values[0].notes, "auto: funds")
    }

    // Typed in, or sent by Claude: someone meant that figure for that day.
    func testAValueEnteredOnTheNewestPriceDayIsKept() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try value(acc, ctx, on: 12, "99")
        ctx.insert(PortfolioValuation(account: acc, asOf: day(11), marketValueEur: 98, notes: "From the broker's statement"))
        try ctx.save()

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.updated, [])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, ["Funds: kept the value entered on 12 Mar."])
        XCTAssertEqual(try valuations(acc, ctx).map(\.marketValueEur), [98, 99])
    }

    // Saving would replace whichever of the day's values came first, maybe the typed one.
    func testANewestPriceDayWithATypedAndAnAutomaticValueIsKept() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        ctx.insert(PortfolioValuation(account: acc, asOf: day(12).addingTimeInterval(8 * 3600), marketValueEur: 98,
                                      notes: "From the broker's statement", updatedAt: day(12)))
        ctx.insert(PortfolioValuation(account: acc, asOf: day(12).addingTimeInterval(9 * 3600), marketValueEur: 99,
                                      notes: "auto: funds", updatedAt: day(12)))
        try ctx.save()

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.updated, [])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, ["Funds: kept the value entered on 12 Mar."])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.map(\.marketValueEur), [98, 99])
        XCTAssertEqual(values.map(\.notes), ["From the broker's statement", "auto: funds"])
        XCTAssertEqual(values.map(\.updatedAt), [day(12), day(12)], "nothing written")
    }

    func testAValueDatedAfterTheNewestPricesIsLeftAlone() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        // Written by a refresh that dated values by the time it ran.
        ctx.insert(PortfolioValuation(account: acc, asOf: day(13).addingTimeInterval(3600), marketValueEur: 108, notes: "auto: funds"))
        try ctx.save()

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.updated, [])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, ["Funds: no new prices since 13 Mar."])
        XCTAssertEqual(try valuations(acc, ctx).map(\.marketValueEur), [108])
    }

    func testAGapLongerThanTheCapFillsOnlyTheLatestDaysAndSaysSo() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let lastValued = cal.date(from: DateComponents(year: 2029, month: 11, day: 26))!
        ctx.insert(PortfolioValuation(account: acc, asOf: lastValued.addingTimeInterval(20 * 3600), marketValueEur: 100))
        try ctx.save()
        let days = stride(from: lastValued, through: day(12), by: 86_400).filter { !cal.isDateInWeekend($0) }
        source.series[a] = days.map { FundQuote(isin: a, day: $0, price: 7, currency: "EUR") }
        source.series[b] = days.map { FundQuote(isin: b, day: $0, price: 2, currency: "EUR") }
        // Held from 6 to 20 February.
        source.infos[c] = FundInfo(isin: c, name: "Example Fund C", currency: "EUR")
        source.series[c] = days.map { FundQuote(isin: c, day: $0, price: 10, currency: "EUR") }

        let outcome = await run(ctx)

        let auto = try valuations(acc, ctx).dropFirst()
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(source.latests, [a, b, c], "a fund sold since the last value still values the days it was held")
        XCTAssertEqual(auto.count, R.fundGapDays)
        XCTAssertEqual(auto.first?.asOf, cal.date(from: DateComponents(year: 2029, month: 12, day: 19)))
        XCTAssertEqual(auto.last?.asOf, day(12))
        XCTAssertEqual(source.sinces[a], cal.date(from: DateComponents(year: 2029, month: 11, day: 19)))
        XCTAssertEqual(outcome.notices, [
            "Funds: values recorded for 60 days (19 Dec 2029 – 12 Mar 2030).",
            "Funds: the gap since 26 Nov is longer than 60 weekdays; only the latest 60 were filled.",
        ])
    }

    // The cache holds prices from the 4th, kept for an account valued daily; this one was last
    // valued on Friday 22 February, so its request reaches further back than the cache.
    func testOlderDaysARequestReachesFillTheCacheSoAnOlderGapIsValued() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        ctx.insert(PortfolioValuation(account: acc, asOf: day(22, month: 2).addingTimeInterval(22 * 3600), marketValueEur: 100))
        try ctx.save()
        let cached = [4, 5, 6, 7, 8, 11]
        for (isin, name, price) in [(a, "Example Fund A", d("7")), (b, "Example Fund B", d("2"))] {
            cache.cache.funds[isin] = Entry(name: name, currency: "EUR", price: price, priceDay: day(11), fetchedDay: day(12),
                                            history: cached.map { .init(date: day($0), priceEur: price) })
        }
        let february = [15, 18, 19, 20, 21, 22, 25, 26, 27, 28]
        // A misprinted NAV on the 27th, far from the days either side of it.
        source.series[a] = prices(a, february.map { ($0, $0 == 27 ? "9" : "7") }, month: 2)
            + prices(a, [(1, "7")] + cached.map { ($0, "7") } + [(12, "7")])
        source.series[b] = prices(b, february.map { ($0, "2") }, month: 2) + prices(b, ([1] + cached + [12]).map { ($0, "2") })

        let outcome = await run(ctx)

        XCTAssertEqual(source.sinces[a], day(15, month: 2))
        XCTAssertEqual(outcome.failures, [])
        let auto = try valuations(acc, ctx).dropFirst()
        XCTAssertEqual(auto.map(\.asOf), [25, 26, 27, 28].map { day($0, month: 2) } + ([1] + cached + [12]).map { day($0) })
        XCTAssertEqual(Set(auto.map(\.marketValueEur)), [d("103.5")], "10 × 7 + 4 × 2 + 25.50, the misprint left out")
        let history = try XCTUnwrap(cache.cache.funds[a]?.history)
        XCTAssertEqual(history.first?.date, day(15, month: 2))
        XCTAssertFalse(history.contains { $0.date == day(27, month: 2) })
        XCTAssertEqual(cache.cache.funds[a]?.priceDay, day(12))
    }

    func testDailyPricesAreKeptFromTwoWeeksBackOrTheRequestsStartButNoMoreThan400Days() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let today = day(13)
        XCTAssertEqual(R.dailyPricesKept(since: nil, today: today), day(27, month: 2))
        XCTAssertEqual(R.dailyPricesKept(since: day(4), today: today), day(27, month: 2))
        XCTAssertEqual(R.dailyPricesKept(since: day(2, month: 1), today: today), day(2, month: 1))
        XCTAssertEqual(R.dailyPricesKept(since: cal.date(byAdding: .year, value: -2, to: today), today: today),
                       cal.date(byAdding: .day, value: -400, to: today))
    }

    func testDailyPricesOlderThanNeededLeaveTheCache() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        cache.cache.funds[a] = Entry(name: "Example Fund A", currency: "EUR", price: d("7.3"), priceDay: day(11),
                                     fetchedDay: day(11), history: [.init(date: Date(timeIntervalSince1970: 0), priceEur: 1),
                                                                    .init(date: day(11), priceEur: d("7.3"))])

        _ = await run(ctx)

        XCTAssertEqual(cache.cache.funds[a]?.history.map(\.date), [day(11), day(12)])
    }

    func testValuesAreInCents() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx, cashAnchor: d("25.505"))
        source.quotes[a] = FundQuote(isin: a, day: day(12), price: d("7.43215"), currency: "EUR")

        _ = await run(ctx)

        let v = try XCTUnwrap(valuations(acc, ctx).last)
        XCTAssertEqual(v.marketValueEur, d("108.01"), "74.3215 + 8.1872 + 25.505 is 108.0137")
        XCTAssertEqual(v.cashValueEur, d("25.51"))
    }

    func testCryptoStillRecordsTheRefreshTimeWithItsUnroundedValue() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        let coin = Account(externalId: "c", type: .broker, institution: "R", name: "Crypto", currency: "EUR",
                           liveValueSource: "crypto:bitcoin", assetQuantity: d("0.0512345"))
        ctx.insert(coin)
        try ctx.save()
        let source = self.source!

        let outcome = await R.run(in: ctx, keychain: keys!, crypto: StubCoins(price: d("60000.123")),
                                  fundPrices: { _ in source }, fundPriceCache: cache, now: now)

        XCTAssertTrue(outcome.updated.contains(coin.id))
        let v = try XCTUnwrap(valuations(coin, ctx).last)
        XCTAssertEqual(v.asOf, now)
        XCTAssertEqual(v.marketValueEur, d("0.0512345") * d("60000.123"))
        XCTAssertEqual(v.notes, "auto: crypto:bitcoin")
    }

    // A value dated by its prices is no longer read today, so money paid in after it is added
    // on top, and only until a value that includes it.
    func testMoneyPaidInAfterTheValuesDayCountsOnce() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        _ = await run(ctx)
        // Booked mid-morning on the 13th, after the value of the 12th.
        _ = S.makeTx(ctx, account: acc, amount: 100, direction: .credit,
                     bookedAt: day(13).addingTimeInterval(10 * 3600), isTransfer: true)
        try ctx.save()
        func metrics(at time: Date) throws -> CoreLogic.Investments.AccountMetrics? {
            CoreLogic.Investments.computeAccountMetrics(
                bases: [CoreLogic.Investments.basis(for: acc)],
                valuations: try valuations(acc, ctx),
                legs: try CoreLogic.Investments.listContributionLegs(for: [acc.id], in: ctx),
                now: time)[acc.id]
        }

        XCTAssertEqual(try metrics(at: now.addingTimeInterval(8 * 3600))?.valueEur, d("208.01"))

        source.quotes[a] = FundQuote(isin: a, day: day(13), price: d("7.4321"), currency: "EUR")
        source.quotes[b] = FundQuote(isin: b, day: day(13), price: d("2.0468"), currency: "EUR")
        let next = day(14).addingTimeInterval(9 * 3600)
        _ = await run(ctx, at: next)

        let latest = try XCTUnwrap(valuations(acc, ctx).last)
        XCTAssertEqual(latest.marketValueEur, d("208.01"))
        XCTAssertEqual(latest.cashValueEur, d("125.5"))
        XCTAssertEqual(try metrics(at: next)?.valueEur, d("208.01"), "the value of the 13th includes the money")
        XCTAssertEqual(try metrics(at: next)?.contributionsSinceValueEur, 0)
    }

    // Against the newest reading before the day being valued.
    func testTheImplausibleValueGuardStillApplies() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        ctx.insert(PortfolioValuation(account: acc, asOf: day(11), marketValueEur: 1))
        try ctx.save()

        let outcome = await run(ctx)

        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertTrue(outcome.failures.contains { $0.contains("far from the last") }, "\(outcome.failures)")
        XCTAssertEqual(try valuations(acc, ctx).count, 1)
    }

    // MARK: - Recent values corrected

    private var thursday: Date { day(14).addingTimeInterval(9 * 3600) }

    // A value saved `hours` past the start of its day, as a refresh writes it unless notes say otherwise.
    private func addValue(
        _ acc: Account, _ ctx: ModelContext, on dd: Int, hours: Double = 0, _ eur: String,
        cash: String? = "25.5", notes: String? = "auto: funds"
    ) throws {
        ctx.insert(PortfolioValuation(
            account: acc, asOf: day(dd).addingTimeInterval(hours * 3600), marketValueEur: d(eur),
            cashValueEur: cash.map(d), notes: notes, createdAt: day(dd), updatedAt: day(dd)))
        try ctx.save()
    }

    // An older build valued Monday the 11th and Tuesday the 12th when it ran, with Friday's
    // prices; Friday the 8th is right.
    private func makeOldBuildValues(_ ctx: ModelContext) throws -> Account {
        let acc = try makeAccount(ctx)
        try addValue(acc, ctx, on: 8, "103.5")
        try addValue(acc, ctx, on: 11, hours: 9.25, "103.5")
        try addValue(acc, ctx, on: 12, hours: 7.5, "103.5")
        source.series[a] = prices(a, [(8, "7"), (11, "7.1"), (12, "7.2"), (13, "7.3")])
        source.series[b] = prices(b, [(8, "2"), (11, "2.01"), (12, "2.02"), (13, "2.03")])
        return acc
    }

    func testRecentAutomaticValuesAreRecalculatedWithTheirOwnDaysPrices() async throws {
        let ctx = try S.makeContext()
        let acc = try makeOldBuildValues(ctx)

        let outcome = await run(ctx, at: thursday)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.updated, [acc.id])
        XCTAssertEqual(outcome.notices, [
            "Funds: values recorded for 1 day (13 Mar).",
            "Funds: corrected 2 recent values (11–12 Mar) with newer prices.",
        ])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.map(\.asOf), [day(8), day(11), day(12), day(13)], "at the start of each day")
        XCTAssertEqual(values.map(\.marketValueEur), [d("103.5"), d("104.54"), d("105.58"), d("106.62")],
                       "10 × A + 4 × B of each day + 25.50")
        XCTAssertEqual(Set(values.map(\.notes)), ["auto: funds"])
        XCTAssertEqual(values[0].updatedAt, day(8), "a value that was right isn't written again")
        XCTAssertEqual(source.sinces, [a: day(19, month: 2), b: day(19, month: 2)],
                       "a week before the first day a refresh may correct")
    }

    func testASecondRunTheSameDayCorrectsNothingAgain() async throws {
        let ctx = try S.makeContext()
        let acc = try makeOldBuildValues(ctx)
        _ = await run(ctx, at: thursday)
        let written = try valuations(acc, ctx).map(\.updatedAt)
        let lookups = source.lookups, latests = source.latests

        let outcome = await run(ctx, at: thursday.addingTimeInterval(6 * 3600))

        XCTAssertEqual(source.lookups, lookups)
        XCTAssertEqual(source.latests, latests)
        XCTAssertEqual(outcome.updated, [])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, ["Funds: no new prices since 13 Mar."])
        XCTAssertEqual(try valuations(acc, ctx).map(\.updatedAt), written, "nothing written")
    }

    // B publishes a day after A, so the 12th is first valued with B's price of the 11th.
    func testADayValuedWithALateFundsPreviousPriceIsCorrectedWhenItsOwnArrives() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        source.series[a] = prices(a, [(11, "7"), (12, "7.1")])
        source.series[b] = prices(b, [(11, "2")])
        _ = await run(ctx)
        XCTAssertEqual(try valuations(acc, ctx).map(\.marketValueEur), [d("104.5")], "10 × 7.1 + 4 × 2 + 25.50")

        source.series[a] = prices(a, [(11, "7"), (12, "7.1"), (13, "7.2")])
        source.series[b] = prices(b, [(11, "2"), (12, "2.05")])
        let outcome = await run(ctx, at: thursday)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, [
            "Funds: values recorded for 1 day (13 Mar).",
            "Funds: corrected 1 recent value (12 Mar) with newer prices.",
        ])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.map(\.asOf), [day(12), day(13)])
        XCTAssertEqual(values.map(\.marketValueEur), [d("104.7"), d("105.7")], "B at 2.05 from the 12th")
    }

    // Typed in, or sent by Claude: someone meant that figure for that day.
    func testValuesTypedOrSentByClaudeInTheLastWeekAreLeftAsTheyAre() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try addValue(acc, ctx, on: 11, hours: 22, "99", cash: nil, notes: nil)
        try addValue(acc, ctx, on: 12, "98", notes: "history (EODHD)")
        source.series[a] = prices(a, [(8, "7"), (11, "7.1"), (12, "7.2"), (13, "7.3")])
        source.series[b] = prices(b, [(8, "2"), (11, "2.01"), (12, "2.02"), (13, "2.03")])

        let outcome = await run(ctx, at: thursday)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, ["Funds: values recorded for 1 day (13 Mar)."])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.map(\.marketValueEur), [99, 98, d("106.62")])
        XCTAssertEqual(values.map(\.asOf), [day(11).addingTimeInterval(22 * 3600), day(12), day(13)])
        XCTAssertEqual(values.map(\.notes), [nil, "history (EODHD)", "auto: funds"])
    }

    // The newest price day is Wednesday the 13th, so the last seven weekdays start on Monday the 4th.
    func testOnlyTheLastSevenWeekdaysUpToTheNewestPriceDayAreCorrected() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try addValue(acc, ctx, on: 1, "90")
        try addValue(acc, ctx, on: 4, hours: 9, "90")
        let open = [1, 4, 5, 6, 7, 8, 11, 12, 13]
        source.series[a] = prices(a, open.map { ($0, "7.1") })
        source.series[b] = prices(b, open.map { ($0, "2") })

        let outcome = await run(ctx, at: thursday)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, [
            "Funds: values recorded for 7 days (5–13 Mar).",
            "Funds: corrected 1 recent value (4 Mar) with newer prices.",
        ])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.first?.marketValueEur, 90, "older than the last seven weekdays")
        XCTAssertEqual(values.first?.updatedAt, day(1))
        XCTAssertEqual(values.dropFirst().map(\.asOf), [4, 5, 6, 7, 8, 11, 12, 13].map { day($0) })
        XCTAssertEqual(Set(values.dropFirst().map(\.marketValueEur)), [d("104.5")])
    }

    // Written by a refresh that dated values by the time it ran: Wednesday's is after the newest
    // prices, of Tuesday the 12th.
    func testAValueAfterTheNewestPricesIsLeftAloneWhileTheOnesBeforeAreCorrected() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try addValue(acc, ctx, on: 12, hours: 8, "103.5")
        try addValue(acc, ctx, on: 13, hours: 8, "103.5")
        source.series[a] = prices(a, [(11, "7.1"), (12, "7.2")])
        source.series[b] = prices(b, [(11, "2"), (12, "2")])

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.updated, [acc.id])
        XCTAssertEqual(outcome.notices, ["Funds: corrected 1 recent value (12 Mar) with newer prices."])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.map(\.asOf), [day(12), day(13).addingTimeInterval(8 * 3600)])
        XCTAssertEqual(values.map(\.marketValueEur), [d("105.5"), d("103.5")])
    }

    func testARecentDayThatCantBeValuedNowIsLeftAsItIs() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try addValue(acc, ctx, on: 12, "90")
        source.series[a] = prices(a, [1, 4, 5, 6, 7, 8, 11, 12, 13].map { ($0, "7") })
        source.series[b] = prices(b, [(1, "2"), (4, "2"), (13, "2")])

        let outcome = await run(ctx, at: thursday)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, ["Funds: values recorded for 1 day (13 Mar)."])
        XCTAssertEqual(try valuations(acc, ctx).map(\.marketValueEur), [90, d("103.5")],
                       "B has no price in the week before the 12th, and a total without it isn't written")
    }

    // 100 paid in at 10:00 on Tuesday the 12th, which the older build missed; Monday's amount was
    // right but its time wasn't.
    func testACorrectedValueIsInCentsAndDatedLikeANewOne() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try addValue(acc, ctx, on: 11, hours: 9, "104.73")
        try addValue(acc, ctx, on: 12, hours: 9, "104.73")
        _ = S.makeTx(ctx, account: acc, amount: 100, direction: .credit,
                     bookedAt: day(12).addingTimeInterval(10 * 3600), isTransfer: true)
        try ctx.save()
        source.series[a] = prices(a, [(8, "7"), (11, "7.12345"), (12, "7.12345"), (13, "7.12345")])
        source.series[b] = prices(b, [(8, "2"), (11, "2"), (12, "2"), (13, "2")])

        let outcome = await run(ctx, at: thursday)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, [
            "Funds: values recorded for 1 day (13 Mar).",
            "Funds: corrected 2 recent values (11–12 Mar) with newer prices.",
        ])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.map(\.asOf), [day(11), day(12).addingTimeInterval(10 * 3600), day(13)],
                       "the start of the day, or the transfer booked that day")
        XCTAssertEqual(values.map(\.marketValueEur), [d("104.73"), d("204.73"), d("204.73")],
                       "71.2345 + 8 + cash, in cents")
        XCTAssertEqual(values.map(\.cashValueEur), [d("25.5"), d("125.5"), d("125.5")])
    }

    // C bought on Monday the 4th for 30 and sold on Monday the 11th for 31, before the last value
    // of Tuesday the 12th: its prices are still fetched for the days it was held.
    func testAFundSoldBeforeTheLastValueIsPricedForTheDaysItCanCorrect() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx, cashAnchor: d("125.5"))
        ctx.insert(FundTrade(account: acc, isin: c, tradeDate: day(4), side: .buy, units: 3, amountEur: 30))
        ctx.insert(FundTrade(account: acc, isin: c, tradeDate: day(11), side: .sell, units: 3, amountEur: 31))
        try ctx.save()
        try addValue(acc, ctx, on: 8, "200", cash: "95.5")
        try addValue(acc, ctx, on: 12, "204.5", cash: "126.5")
        let open = [4, 5, 6, 7, 8, 11, 12, 13]
        source.infos[c] = FundInfo(isin: c, name: "Example Fund C", currency: "EUR")
        source.series[a] = prices(a, open.map { ($0, "7") })
        source.series[b] = prices(b, open.map { ($0, "2") })
        source.series[c] = prices(c, open.map { ($0, "10") })

        let outcome = await run(ctx, at: thursday)

        XCTAssertEqual(source.latests, [a, b, c])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, [
            "Funds: values recorded for 1 day (13 Mar).",
            "Funds: corrected 1 recent value (8 Mar) with newer prices.",
        ])
        XCTAssertEqual(try valuations(acc, ctx).map(\.marketValueEur), [d("203.5"), d("204.5"), d("204.5")],
                       "70 + 8 + 3 × 10 + 95.50 on the 8th")
    }

    // Saturday the 9th, valued by an older build when it ran: the rule values any day, here with
    // Friday's prices.
    func testARecentAutomaticValueOnAWeekendIsCorrectedToo() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try addValue(acc, ctx, on: 9, hours: 10, "90")
        source.series[a] = prices(a, [(8, "7"), (11, "7.1"), (12, "7.2")])
        source.series[b] = prices(b, [(8, "2"), (11, "2"), (12, "2")])

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, [
            "Funds: values recorded for 2 days (11–12 Mar).",
            "Funds: corrected 1 recent value (9 Mar) with newer prices.",
        ])
        let values = try valuations(acc, ctx)
        XCTAssertEqual(values.map(\.asOf), [day(9), day(11), day(12)])
        XCTAssertEqual(values.map(\.marketValueEur), [d("103.5"), d("104.5"), d("105.5")])
    }

    // Saving would replace whichever of the day's values came first, maybe the typed one.
    func testADayWithMoreThanOneValueIsLeftAsItIs() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try addValue(acc, ctx, on: 11, hours: 9, "90")
        try addValue(acc, ctx, on: 11, hours: 20, "91", notes: "From the broker's statement")
        source.series[a] = prices(a, [(8, "7"), (11, "7.1"), (12, "7.2")])
        source.series[b] = prices(b, [(8, "2"), (11, "2"), (12, "2")])

        let outcome = await run(ctx)

        XCTAssertEqual(outcome.notices, ["Funds: values recorded for 1 day (12 Mar)."])
        XCTAssertEqual(try valuations(acc, ctx).map(\.marketValueEur), [90, 91, d("105.5")])
    }

    // Against the newest reading before the day being corrected, each day on its own: a refused
    // correction leaves the value it would replace, which is no problem to report as a failure.
    func testTheImplausibleValueGuardAppliesToEachCorrectionOnItsOwn() async throws {
        let ctx = try S.makeContext()
        let acc = try makeAccount(ctx)
        try addValue(acc, ctx, on: 8, "1", notes: nil)
        try addValue(acc, ctx, on: 11, "104")
        try addValue(acc, ctx, on: 12, "105")
        source.series[a] = prices(a, [(8, "7"), (11, "7.1"), (12, "7.2"), (13, "7.3")])
        source.series[b] = prices(b, [(8, "2"), (11, "2"), (12, "2"), (13, "2")])

        let outcome = await run(ctx, at: thursday)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.notices, [
            "Funds: values recorded for 1 day (13 Mar).",
            "Funds: corrected 1 recent value (12 Mar) with newer prices.",
            "Funds: left the 11 Mar value as it was; the new one looks implausible next to the 8 Mar reading.",
        ])
        XCTAssertEqual(try valuations(acc, ctx).map(\.marketValueEur), [1, 104, d("105.5"), d("106.5")])
    }

    func testAutomaticValuesFromOtherSourcesAreNotCorrected() async throws {
        let ctx = try S.makeContext()
        _ = try makeAccount(ctx)
        let coin = Account(externalId: "c", type: .broker, institution: "R", name: "Crypto", currency: "EUR",
                           liveValueSource: "crypto:bitcoin", assetQuantity: d("0.5"))
        let stocks = Account(externalId: "t", type: .broker, institution: "T", name: "Stocks", currency: "EUR",
                             liveValueSource: R.trading212Source)
        ctx.insert(coin)
        ctx.insert(stocks)
        try ctx.save()
        try addValue(coin, ctx, on: 11, hours: 9, "90", cash: nil, notes: "auto: crypto:bitcoin")
        try addValue(coin, ctx, on: 12, hours: 9, "91", cash: nil, notes: "auto: crypto:bitcoin")
        try addValue(stocks, ctx, on: 12, hours: 9, "92", notes: "auto: t212")
        let source = self.source!

        let outcome = await R.run(in: ctx, keychain: keys!, crypto: StubCoins(price: 200),
                                  fundPrices: { _ in source }, fundPriceCache: cache, now: now)

        XCTAssertEqual(outcome.failures, ["Trading 212: add the API key in Settings"])
        XCTAssertEqual(try valuations(coin, ctx).map(\.marketValueEur), [90, 91, 100])
        XCTAssertEqual(try valuations(coin, ctx).map(\.asOf),
                       [day(11).addingTimeInterval(9 * 3600), day(12).addingTimeInterval(9 * 3600), now])
        XCTAssertEqual(try valuations(stocks, ctx).map(\.marketValueEur), [92])
    }
}

@MainActor
private final class FakeFundSource: FundPriceSource {
    var infos: [String: FundInfo] = [:]
    // A fund's window of prices, or just the newest when it has no series.
    var quotes: [String: FundQuote] = [:]
    var series: [String: [FundQuote]] = [:]
    var lookupErrors: [String: any Error] = [:]
    var latestErrors: [String: any Error] = [:]
    // Long enough for a second run to start while a request is out.
    var delay: Duration = .zero
    // Called as each request goes out.
    var onRequest: (() -> Void)?
    private(set) var lookups: [String] = []
    private(set) var latests: [String] = []
    private(set) var sinces: [String: Date] = [:]

    func lookup(isin: String) async throws -> FundInfo {
        lookups.append(isin)
        onRequest?()
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error = lookupErrors[isin] { throw error }
        guard let info = infos[isin] else { throw FundPriceError.notFound }
        return info
    }

    func recent(isin: String, currency: String, since: Date?) async throws -> [FundQuote] {
        latests.append(isin)
        sinces[isin] = since
        onRequest?()
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error = latestErrors[isin] { throw error }
        guard let quotes = series[isin] ?? quotes[isin].map({ [$0] }) else { throw FundPriceError.notFound }
        return quotes
    }
}

private final class MemoryFundPriceCache: FundPriceCacheStore {
    var cache = CoreLogic.FundPriceCache()
    var unreadable = false
    var modified: Date?
    var saveError: (any Error)?
    private(set) var saves: [CoreLogic.FundPriceCache] = []
    func load() -> CoreLogic.FundPriceCache? { unreadable ? nil : cache }
    func modificationDate() -> Date? { modified }
    func save(_ cache: CoreLogic.FundPriceCache) throws {
        if let saveError { throw saveError }
        self.cache = cache
        unreadable = false
        saves.append(cache)
    }
}

private struct StubCoins: CryptoPriceSource {
    let price: Decimal
    func prices(for coinIds: [String]) async throws -> [String: Decimal] {
        Dictionary(uniqueKeysWithValues: coinIds.map { ($0, price) })
    }
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

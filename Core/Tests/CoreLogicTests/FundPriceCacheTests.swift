import XCTest
@testable import CoreLogic

final class FundPriceCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "fund-price-cache-\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAMissingFileIsAnEmptyCache() {
        let file = FundPriceCacheFile(url: dir.appending(path: "none.json"))
        XCTAssertEqual(file.load(), CoreLogic.FundPriceCache())
    }

    // Not an empty cache: that would reset today's request count.
    func testAnUnreadableFileLoadsAsNothing() throws {
        let url = dir.appending(path: "broken.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(FundPriceCacheFile(url: url).load())
    }

    func testAFundThatCantBeReadOrAnUnknownFieldDoesntWipeTheCache() throws {
        let url = dir.appending(path: "fund-prices.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"requestDay": 0, "requestCount": 3, "futureField": true,
         "funds": {
           "ZZ0000000A00": {"name": "Example Fund", "currency": "EUR", "price": 5.1234, "priceDay": 0, "futureField": 1},
           "ZZ0000000B09": {"name": "Example Fund Without Currency"}
         }}
        """.utf8).write(to: url)
        var expected = CoreLogic.FundPriceCache()
        expected.funds["ZZ0000000A00"] = .init(
            name: "Example Fund", currency: "EUR", price: Decimal(string: "5.1234"),
            priceDay: Date(timeIntervalSinceReferenceDate: 0))
        expected.requestDay = Date(timeIntervalSinceReferenceDate: 0)
        expected.requestCount = 3
        XCTAssertEqual(FundPriceCacheFile(url: url).load(), expected)
    }

    func testTheModificationDateIsTheFilesAndNilWithoutOne() throws {
        let url = dir.appending(path: "fund-prices.json")
        XCTAssertNil(FundPriceCacheFile(url: url).modificationDate())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let written = Date(timeIntervalSince1970: 21_990 * 86_400 + 3_600)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path(percentEncoded: false))
        XCTAssertEqual(FundPriceCacheFile(url: url).modificationDate(), written)
    }

    func testAFileWithoutARequestCountIsUnreadable() throws {
        let url = dir.appending(path: "fund-prices.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"requestDay": 0, "funds": {}}"#.utf8).write(to: url)
        XCTAssertNil(FundPriceCacheFile(url: url).load())
    }

    func testRoundTripKeepsPricesExact() throws {
        // A folder that doesn't exist yet, like Application Support on a fresh install.
        let file = FundPriceCacheFile(url: dir.appending(path: "nested/fund-prices.json"))
        var cache = CoreLogic.FundPriceCache()
        let day = Date(timeIntervalSince1970: 21_990 * 86_400)
        cache.funds["ZZ0000000A00"] = .init(
            name: "Example Fund", currency: "EUR", price: Decimal(string: "5.1234"), priceDay: day,
            fetchedDay: day, previousPrice: Decimal(string: "2.0468"),
            pendingPrice: Decimal(string: "7.4321"), pendingDay: day,
            history: [.init(date: day.addingTimeInterval(-86_400), priceEur: Decimal(string: "5.0987")!),
                      .init(date: day, priceEur: Decimal(string: "5.1234")!)])
        cache.requestDay = day
        cache.requestCount = 3
        cache.failedLookups["ZZ0000000B09"] = day
        try file.save(cache)
        let loaded = try XCTUnwrap(file.load())
        XCTAssertEqual(loaded, cache)
        XCTAssertEqual(loaded.funds["ZZ0000000A00"]?.price?.description, "5.1234")
        XCTAssertEqual(loaded.funds["ZZ0000000A00"]?.history.first?.priceEur.description, "5.0987")
    }

    // Written before daily prices were kept: every fund stays, so none is looked up again.
    func testACacheWrittenBeforeDailyPricesDecodesWithEveryFund() throws {
        let url = dir.appending(path: "fund-prices.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"requestDay": 0, "requestCount": 2, "failedLookups": {},
         "funds": {"ZZ0000000A00": {"name": "Example Fund", "currency": "EUR", "price": 5.1234, "priceDay": 0,
                                    "fetchedDay": 0, "previousPrice": 5.1, "pendingPrice": 6.5, "pendingDay": 86400}}}
        """.utf8).write(to: url)
        let entry = try XCTUnwrap(FundPriceCacheFile(url: url).load()?.funds["ZZ0000000A00"])
        let day0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(entry, .init(
            name: "Example Fund", currency: "EUR", price: Decimal(string: "5.1234"), priceDay: day0,
            fetchedDay: day0, previousPrice: Decimal(string: "5.1"), pendingPrice: Decimal(string: "6.5"),
            pendingDay: day0.addingTimeInterval(86_400)))
        XCTAssertEqual(entry.history, [])
        XCTAssertEqual(entry.dailyPrices, [.init(date: day0, priceEur: Decimal(string: "5.1234")!)],
                       "the newest price values its day even without daily prices")
    }

    func testDailyPricesEndWithTheNewestAcceptedPrice() {
        let d1 = Date(timeIntervalSince1970: 21_990 * 86_400), d2 = d1.addingTimeInterval(86_400)
        var entry = CoreLogic.FundPriceCache.Entry(name: "Example Fund", currency: "EUR")
        XCTAssertEqual(entry.dailyPrices, [])
        entry.history = [.init(date: d1, priceEur: 5)]
        entry.price = 6
        entry.priceDay = d2
        XCTAssertEqual(entry.dailyPrices, [.init(date: d1, priceEur: 5), .init(date: d2, priceEur: 6)])
        entry.history.append(.init(date: d2, priceEur: 6))
        XCTAssertEqual(entry.dailyPrices, entry.history)
    }

    func testPriceDaysSpanTheNewestPriceOfEachFundAsked() {
        let d1 = Date(timeIntervalSince1970: 21_990 * 86_400), d2 = d1.addingTimeInterval(86_400)
        var cache = CoreLogic.FundPriceCache()
        cache.funds["ZZ0000000A00"] = .init(name: "Fund A", currency: "EUR", price: 5, priceDay: d2)
        cache.funds["ZZ0000000B09"] = .init(name: "Fund B", currency: "EUR", price: 7, priceDay: d1)
        cache.funds["ZZ0000000C08"] = .init(name: "Fund Not Priced Yet", currency: "EUR")
        XCTAssertEqual(cache.priceDays(for: ["ZZ0000000A00", "ZZ0000000B09", "ZZ0000000C08"]), d1...d2)
        XCTAssertEqual(cache.priceDays(for: ["ZZ0000000A00"]), d2...d2)
        XCTAssertNil(cache.priceDays(for: ["ZZ0000000C08", "ZZ0000000D07"]))
    }

    func testPriceDaysOfTradesSpanOnlyTheFundsTheyStillHold() {
        let d1 = Date(timeIntervalSince1970: 21_990 * 86_400), d2 = d1.addingTimeInterval(86_400)
        var cache = CoreLogic.FundPriceCache()
        cache.funds["ZZ0000000A00"] = .init(name: "Fund A", currency: "EUR", price: 5, priceDay: d2)
        cache.funds["ZZ0000000B09"] = .init(name: "Fund B", currency: "EUR", price: 7, priceDay: d1)
        let trades = [
            CoreLogic.Funds.Trade(isin: "ZZ0000000A00", date: d1, side: .buy, units: 3, amountEur: 15),
            CoreLogic.Funds.Trade(isin: "ZZ0000000B09", date: d1, side: .buy, units: 2, amountEur: 14),
            CoreLogic.Funds.Trade(isin: "ZZ0000000B09", date: d2, side: .sell, units: 2, amountEur: 14),
        ]
        XCTAssertEqual(cache.priceDays(heldBy: trades), d2...d2, "B is sold out")
        XCTAssertNil(cache.priceDays(heldBy: []))
    }

    func testEuroPricesLeaveOutOtherCurrenciesAndFundsWithoutAPrice() {
        var cache = CoreLogic.FundPriceCache()
        cache.funds["ZZ0000000A00"] = .init(name: "Euro Fund", currency: "EUR", price: 5, pendingPrice: 9)
        cache.funds["ZZ0000000B09"] = .init(name: "Dollar Fund", currency: "USD", price: 7)
        cache.funds["ZZ0000000C08"] = .init(name: "Fund Not Priced Yet", currency: "EUR")
        XCTAssertEqual(cache.eurPrices, ["ZZ0000000A00": 5])
    }
}

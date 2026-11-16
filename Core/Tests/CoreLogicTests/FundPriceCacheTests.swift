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
            fetchedDay: day, previousPrice: Decimal(string: "2.0468"))
        cache.requestDay = day
        cache.requestCount = 3
        try file.save(cache)
        let loaded = try XCTUnwrap(file.load())
        XCTAssertEqual(loaded, cache)
        XCTAssertEqual(loaded.funds["ZZ0000000A00"]?.price?.description, "5.1234")
    }
}

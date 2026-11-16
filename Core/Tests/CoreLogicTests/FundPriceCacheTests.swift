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

    func testAnUnreadableFileIsAnEmptyCache() throws {
        let url = dir.appending(path: "broken.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(FundPriceCacheFile(url: url).load(), CoreLogic.FundPriceCache())
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
        let loaded = file.load()
        XCTAssertEqual(loaded, cache)
        XCTAssertEqual(loaded.funds["ZZ0000000A00"]?.price?.description, "5.1234")
    }
}

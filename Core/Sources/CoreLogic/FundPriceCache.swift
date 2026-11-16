import Foundation

extension CoreLogic {
    // Fund prices kept on this device only: they can always be fetched again, so they are
    // never synced (D17). Days are UTC starts of day.
    public struct FundPriceCache: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable {
            public var name: String
            public var currency: String
            public var price: Decimal?
            public var priceDay: Date?
            // When the source last answered, even with a price the jump guard refused.
            public var fetchedDay: Date?
            // The price before `price`, from an earlier day: what a NAV re-published for
            // priceDay is checked against.
            public var previousPrice: Decimal?

            public init(
                name: String, currency: String, price: Decimal? = nil, priceDay: Date? = nil,
                fetchedDay: Date? = nil, previousPrice: Decimal? = nil
            ) {
                self.name = name
                self.currency = currency
                self.price = price
                self.priceDay = priceDay
                self.fetchedDay = fetchedDay
                self.previousPrice = previousPrice
            }
        }

        // By ISIN.
        public var funds: [String: Entry] = [:]
        public var requestDay: Date?
        public var requestCount = 0

        public init() {}
    }
}

public protocol FundPriceCacheStore {
    func load() -> CoreLogic.FundPriceCache
    func save(_ cache: CoreLogic.FundPriceCache) throws
}

public struct FundPriceCacheFile: FundPriceCacheStore {
    public let url: URL

    public init(url: URL = .applicationSupportDirectory.appending(path: "fund-prices.json")) {
        self.url = url
    }

    // A missing or unreadable file is an empty cache: everything in it can be fetched again.
    public func load() -> CoreLogic.FundPriceCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CoreLogic.FundPriceCache.self, from: data)
        else { return CoreLogic.FundPriceCache() }
        return cache
    }

    public func save(_ cache: CoreLogic.FundPriceCache) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
}

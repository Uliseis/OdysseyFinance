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
            // A new price the jump guard refused, held until a later day's price confirms or
            // replaces it. While it's held, accounts with the fund aren't valued.
            public var pendingPrice: Decimal?
            public var pendingDay: Date?
            // Accepted daily prices, oldest first: what values the days since an account's last
            // valuation. A cache written before they were kept has none.
            public var history: [Funds.PricePoint]

            public init(
                name: String, currency: String, price: Decimal? = nil, priceDay: Date? = nil,
                fetchedDay: Date? = nil, previousPrice: Decimal? = nil,
                pendingPrice: Decimal? = nil, pendingDay: Date? = nil, history: [Funds.PricePoint] = []
            ) {
                self.name = name
                self.currency = currency
                self.price = price
                self.priceDay = priceDay
                self.fetchedDay = fetchedDay
                self.previousPrice = previousPrice
                self.pendingPrice = pendingPrice
                self.pendingDay = pendingDay
                self.history = history
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                currency = try c.decode(String.self, forKey: .currency)
                price = try c.decodeIfPresent(Decimal.self, forKey: .price)
                priceDay = try c.decodeIfPresent(Date.self, forKey: .priceDay)
                fetchedDay = try c.decodeIfPresent(Date.self, forKey: .fetchedDay)
                previousPrice = try c.decodeIfPresent(Decimal.self, forKey: .previousPrice)
                pendingPrice = try c.decodeIfPresent(Decimal.self, forKey: .pendingPrice)
                pendingDay = try c.decodeIfPresent(Date.self, forKey: .pendingDay)
                history = try c.decodeIfPresent([Funds.PricePoint].self, forKey: .history) ?? []
            }

            // The daily prices up to the newest accepted one, which ends them even in a cache
            // written before they were kept.
            public var dailyPrices: [Funds.PricePoint] {
                guard let price, let priceDay else { return history }
                return history.filter { $0.date < priceDay } + [Funds.PricePoint(date: priceDay, priceEur: price)]
            }
        }

        // By ISIN.
        public var funds: [String: Entry] = [:]
        public var requestDay: Date?
        public var requestCount = 0
        // By ISIN: the day EODHD last said it doesn't list the fund, so it's asked at most once a day.
        public var failedLookups: [String: Date] = [:]

        public init() {}

        // By ISIN: the prices that can value a position, which needs euros. A held pending
        // price isn't one.
        public var eurPrices: [String: Decimal] {
            funds.compactMapValues { $0.currency == "EUR" ? $0.price : nil }
        }

        // The earliest and latest of these funds' newest price days; nil when none has a price.
        public func priceDays(for isins: some Sequence<String>) -> ClosedRange<Date>? {
            let days = isins.compactMap { funds[$0]?.priceDay }
            guard let first = days.min(), let last = days.max() else { return nil }
            return first...last
        }

        // A fund that can't be read is dropped and looked up again; the rest stay. The request
        // count has no fallback: without it the file is unreadable as a whole.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            funds = try c.decodeIfPresent([String: LossyEntry].self, forKey: .funds)?
                .compactMapValues(\.entry) ?? [:]
            requestDay = try c.decodeIfPresent(Date.self, forKey: .requestDay)
            requestCount = try c.decode(Int.self, forKey: .requestCount)
            failedLookups = try c.decodeIfPresent([String: Date].self, forKey: .failedLookups) ?? [:]
        }

        private struct LossyEntry: Decodable {
            let entry: Entry?
            init(from decoder: any Decoder) throws { entry = try? Entry(from: decoder) }
        }
    }
}

public protocol FundPriceCacheStore {
    // nil when there is a cache that can't be read, as opposed to none at all.
    func load() -> CoreLogic.FundPriceCache?
    // When the cache was last written; nil when that's unknown.
    func modificationDate() -> Date?
    func save(_ cache: CoreLogic.FundPriceCache) throws
}

public struct FundPriceCacheFile: FundPriceCacheStore {
    public let url: URL

    public init(url: URL = .applicationSupportDirectory.appending(path: "fund-prices.json")) {
        self.url = url
    }

    public func load() -> CoreLogic.FundPriceCache? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return CoreLogic.FundPriceCache()
        } catch {
            return nil
        }
        return try? JSONDecoder().decode(CoreLogic.FundPriceCache.self, from: data)
    }

    // From the file system, not URL resource values: a URL caches those.
    public func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
    }

    public func save(_ cache: CoreLogic.FundPriceCache) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
}

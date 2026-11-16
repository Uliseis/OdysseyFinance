import Foundation

// One NAV for a fund identified by ISIN. `day` is the UTC start of the day the NAV is for.
public struct FundQuote: Equatable, Sendable {
    public let isin: String
    public let day: Date
    public let price: Decimal
    public let currency: String

    public init(isin: String, day: Date, price: Decimal, currency: String) {
        self.isin = isin
        self.day = day
        self.price = price
        self.currency = currency
    }
}

// What the price source calls the fund, and the currency its NAV is quoted in.
public struct FundInfo: Equatable, Sendable {
    public let isin: String
    public let name: String
    public let currency: String

    public init(isin: String, name: String, currency: String) {
        self.isin = isin
        self.name = name
        self.currency = currency
    }
}

public enum FundPriceError: Error, Equatable {
    case notFound
    case unauthorized
    case rateLimited
    case badResponse(status: Int, body: String)
    case parse(String)

    static let snippetLength = 200
}

// Callers inject fakes through this.
public protocol FundPriceSource: Sendable {
    func latest(isin: String, currency: String) async throws -> FundQuote
    func lookup(isin: String) async throws -> FundInfo
}

enum FundDates {
    static let posix = Locale(identifier: "en_US_POSIX")

    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = posix
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

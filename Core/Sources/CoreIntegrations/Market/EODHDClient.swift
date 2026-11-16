import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// EODHD end-of-day prices; European funds sit on its virtual EUFUND exchange as <ISIN>.EUFUND.
// The key travels only as the api_token query item, so nothing that can reach a log or the
// UI (error bodies, URLError) is allowed to carry the request URL.
public struct EODHDClient: FundPriceSource, Sendable {
    public let baseURL: URL
    let apiKey: String
    let session: URLSession

    // Wide enough to span Easter's four-day close plus a NAV published a day or two late.
    static let latestWindowDays = 14

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://eodhd.com/api")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    func makeRequest(isin: String, from: Date, to: Date) -> URLRequest {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("eod/\(isin).EUFUND"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "api_token", value: apiKey),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "from", value: FundDates.isoDay.string(from: from)),
            URLQueryItem(name: "to", value: FundDates.isoDay.string(from: to)),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    func makeSearchRequest(isin: String) -> URLRequest {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("search/\(isin)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "api_token", value: apiKey),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public func lookup(isin: String) async throws -> FundInfo {
        try Self.decodeSearch(try await fetch(makeSearchRequest(isin: isin)), isin: isin)
    }

    public func latest(isin: String, currency: String) async throws -> FundQuote {
        try await latest(isin: isin, currency: currency, asOf: .now)
    }

    // /eod reports no currency, so the quote carries the share class's currency as the caller knows it.
    func latest(isin: String, currency: String, asOf: Date) async throws -> FundQuote {
        let from = FundDates.utc.date(byAdding: .day, value: -Self.latestWindowDays, to: asOf)!
        let data = try await fetch(makeRequest(isin: isin, from: from, to: asOf))
        guard let newest = try Self.decodeHistory(data, isin: isin, currency: currency).last else {
            throw FundPriceError.notFound
        }
        return newest
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // Its userInfo holds the failing URL, api_token included.
            throw URLError(error.code)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = String(decoding: data, as: UTF8.self)
            if !apiKey.isEmpty { body = body.replacingOccurrences(of: apiKey, with: "<key>") }
            throw Self.error(status: status, body: body)
        }
        return data
    }

    static func error(status: Int, body: String) -> FundPriceError {
        if status == 402 || status == 429 || mentionsLimit(body) { return .rateLimited }
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .notFound
        default: return .badResponse(status: status, body: String(body.prefix(FundPriceError.snippetLength)))
        }
    }

    static func mentionsLimit(_ body: String) -> Bool {
        body.lowercased().contains("limit")
    }

    // Oldest first. Rows without a positive close (no NAV that day) are dropped.
    public static func decodeHistory(_ data: Data, isin: String, currency: String) throws -> [FundQuote] {
        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: quotingClose(data))
        } catch {
            let body = String(decoding: data, as: UTF8.self)
            if mentionsLimit(body) { throw FundPriceError.rateLimited }
            throw FundPriceError.parse("EODHD body is not a price list: \(body.prefix(80))")
        }
        var quotes: [FundQuote] = []
        for row in rows {
            guard let close = row.close else { continue }
            guard let day = FundDates.isoDay.date(from: row.date),
                  let price = Decimal(string: close, locale: FundDates.posix)
            else { throw FundPriceError.parse("EODHD row \(row.date): \(close)") }
            if price > 0 {
                quotes.append(FundQuote(isin: isin, day: day, price: price, currency: currency))
            }
        }
        return quotes.sorted { $0.day < $1.day }
    }

    // Search also matches the same ISIN listed on stock exchanges; only the EUFUND row is the
    // fund's NAV, the one /eod serves.
    public static func decodeSearch(_ data: Data, isin: String) throws -> FundInfo {
        let rows: [SearchRow]
        do {
            rows = try JSONDecoder().decode([SearchRow].self, from: data)
        } catch {
            let body = String(decoding: data, as: UTF8.self)
            if mentionsLimit(body) { throw FundPriceError.rateLimited }
            throw FundPriceError.parse("EODHD body is not a search result: \(body.prefix(80))")
        }
        guard let row = rows.first(where: { $0.Exchange == "EUFUND" && $0.ISIN == isin }),
              let name = row.Name, let currency = row.Currency
        else { throw FundPriceError.notFound }
        return FundInfo(isin: isin, name: name, currency: currency)
    }

    // JSONDecoder has decoded Decimal through Double on some Foundation versions
    // (5.1234 -> 5.123400000000001024); reading the close token as text keeps the NAV's digits.
    static func quotingClose(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let quoted = text.replacing(#/"close"\s*:\s*(-?[0-9][0-9.eE+\-]*)/#) { match in
            "\"close\":\"\(match.1)\""
        }
        return Data(quoted.utf8)
    }

    struct Row: Decodable {
        let date: String
        let close: String?
    }

    // Optional throughout: a null in an unrelated listing mustn't fail the whole search.
    struct SearchRow: Decodable {
        let Exchange: String?
        let Name: String?
        let Currency: String?
        let ISIN: String?
    }
}

import XCTest
@testable import CoreIntegrations

// Serves canned responses to a URLSession so the fetch paths run without the network.
// XCTest runs these serially, so one shared handler is enough.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

final class FundPriceClientsTests: XCTestCase {
    private let isin = "ZZ0000000A00"
    private let key = "test-eodhd-key"

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func day(_ s: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let p = s.split(separator: "-").map { Int($0)! }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    private func query(_ req: URLRequest) -> [String: String] {
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    // MARK: EODHD

    func testEODHDRequestAddressesTheFundOnEUFUNDWithTheKeyOnlyInApiToken() {
        let req = EODHDClient(apiKey: key).makeRequest(
            isin: isin, from: day("2026-01-02"), to: day("2026-03-31"))
        XCTAssertEqual(req.url?.host, "eodhd.com")
        XCTAssertEqual(req.url?.path, "/api/eod/ZZ0000000A00.EUFUND")
        XCTAssertEqual(query(req), [
            "api_token": key, "fmt": "json", "from": "2026-01-02", "to": "2026-03-31",
        ])
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(req.url!.absoluteString.components(separatedBy: key).count, 2,
                       "the key appears once, in api_token")
        XCTAssertFalse((req.allHTTPHeaderFields ?? [:]).values.contains { $0.contains(key) })
    }

    func testEODHDDecodeKeepsTheFundsDigitsExact() throws {
        let json = Data("""
        [
          {"date":"2026-03-02","open":7.4321,"high":7.4321,"low":7.4321,"close":7.4321,"adjusted_close":7.4321,"volume":0},
          {"date":"2026-03-03","open":12.0305,"high":12.0305,"low":12.0305,"close":12.0305,"adjusted_close":12.0305,"volume":0},
          {"date":"2026-03-04","open":2.0468,"high":2.0468,"low":2.0468,"close": 2.0468,"adjusted_close":2.0468,"volume":0},
          {"date":"2026-03-05","open":7.4,"high":7.4,"low":7.4,"close":7.4,"adjusted_close":7.4,"volume":0},
          {"date":"2026-03-06","open":3456.7,"high":3456.7,"low":3456.7,"close":3456.7,"adjusted_close":3456.7,"volume":0},
          {"date":"2026-03-09","open":0.30000000000000004,"high":0,"low":0,"close":0.30000000000000004,"adjusted_close":0,"volume":0}
        ]
        """.utf8)
        let quotes = try EODHDClient.decodeHistory(json, isin: isin, currency: "EUR")
        XCTAssertEqual(quotes.map(\.price.description),
                       ["7.4321", "12.0305", "2.0468", "7.4", "3456.7", "0.30000000000000004"])
        XCTAssertEqual(quotes[1].price, Decimal(string: "12.0305"))
        let quoted = String(decoding: EODHDClient.quotingClose(json), as: UTF8.self)
        XCTAssertTrue(quoted.contains(#""close":"7.4321""#))
        XCTAssertTrue(quoted.contains(#""adjusted_close":7.4321"#))
        XCTAssertEqual(quotes[1], FundQuote(
            isin: isin, day: day("2026-03-03"), price: Decimal(string: "12.0305")!, currency: "EUR"))
    }

    func testEODHDDecodeSortsByDayAndSkipsRowsWithoutANav() throws {
        let json = Data("""
        [
          {"date":"2026-03-04","close":6.5},
          {"date":"2026-03-02","close":6.25},
          {"date":"2026-03-03","close":null},
          {"date":"2026-03-05","close":0}
        ]
        """.utf8)
        let quotes = try EODHDClient.decodeHistory(json, isin: isin, currency: "EUR")
        XCTAssertEqual(quotes.map(\.day), [day("2026-03-02"), day("2026-03-04")])
    }

    func testEODHDDecodeOfAnUnreadableBodyIsAParseErrorOrTheDailyLimit() {
        XCTAssertThrowsError(try EODHDClient.decodeHistory(
            Data("You exceeded your daily API requests limit.".utf8), isin: isin, currency: "EUR")
        ) { XCTAssertEqual($0 as? FundPriceError, .rateLimited) }
        XCTAssertThrowsError(try EODHDClient.decodeHistory(
            Data(#"{"unexpected":true}"#.utf8), isin: isin, currency: "EUR")
        ) {
            guard case .parse = $0 as? FundPriceError else { return XCTFail("\($0)") }
        }
    }

    func testEODHDErrorMapping() {
        XCTAssertEqual(EODHDClient.error(status: 401, body: "Unauthenticated"), .unauthorized)
        XCTAssertEqual(EODHDClient.error(status: 403, body: "Forbidden"), .unauthorized)
        XCTAssertEqual(EODHDClient.error(status: 402, body: ""), .rateLimited)
        XCTAssertEqual(EODHDClient.error(status: 429, body: ""), .rateLimited)
        XCTAssertEqual(
            EODHDClient.error(status: 403, body: "You exceeded your daily API requests limit."),
            .rateLimited)
        XCTAssertEqual(EODHDClient.error(status: 404, body: "Ticker Not Found."), .notFound)
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(EODHDClient.error(status: 500, body: long),
                       .badResponse(status: 500, body: String(repeating: "x", count: 200)))
    }

    func testEODHDLatestTakesTheNewestRowOfATwoWeekWindow() async throws {
        var seen: URLRequest?
        StubURLProtocol.handler = { req in
            seen = req
            return (200, Data(#"[{"date":"2026-03-12","close":4.0721},{"date":"2026-03-13","close":4.1093}]"#.utf8))
        }
        let client = EODHDClient(apiKey: key, session: StubURLProtocol.session())
        let quote = try await client.latest(isin: isin, currency: "EUR", asOf: day("2026-03-16"))
        XCTAssertEqual(quote.day, day("2026-03-13"))
        XCTAssertEqual(quote.price, Decimal(string: "4.1093"))
        XCTAssertEqual(query(try XCTUnwrap(seen))["from"], "2026-03-02")
        XCTAssertEqual(query(try XCTUnwrap(seen))["to"], "2026-03-16")
    }

    func testEODHDLatestOnAnEmptyWindowIsNotFound() async {
        StubURLProtocol.handler = { _ in (200, Data("[]".utf8)) }
        let client = EODHDClient(apiKey: key, session: StubURLProtocol.session())
        do {
            _ = try await client.latest(isin: isin, currency: "EUR")
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? FundPriceError, .notFound)
        }
    }

    func testEODHDErrorsNeverCarryTheKey() async {
        StubURLProtocol.handler = { req in (500, Data("bad gateway for \(req.url!.absoluteString)".utf8)) }
        let client = EODHDClient(apiKey: key, session: StubURLProtocol.session())
        do {
            _ = try await client.latest(isin: isin, currency: "EUR")
            XCTFail("expected badResponse")
        } catch {
            guard case .badResponse(500, let body) = error as? FundPriceError else {
                return XCTFail("\(error)")
            }
            XCTAssertFalse(body.contains(key))
        }

        StubURLProtocol.handler = { req in
            throw URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: req.url!])
        }
        do {
            _ = try await client.latest(isin: isin, currency: "EUR")
            XCTFail("expected a transport error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
            XCTAssertFalse(String(describing: error).contains(key))
            XCTAssertFalse((error as NSError).userInfo.description.contains(key))
        }
    }
}

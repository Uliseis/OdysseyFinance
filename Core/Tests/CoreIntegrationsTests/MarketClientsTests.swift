import XCTest
@testable import CoreIntegrations

final class MarketClientsTests: XCTestCase {
    func testBasicAuthHeaderIsBase64OfKeyColonSecret() {
        let creds = Trading212Credentials(key: "abc", secret: "def")
        XCTAssertEqual(creds.basicAuthHeader, "Basic " + Data("abc:def".utf8).base64EncodedString())
    }

    func testTrading212RequestTargetsSummaryWithAuth() {
        let client = Trading212Client(credentials: .init(key: "k", secret: "s"))
        let req = client.makeRequest(path: "equity/account/summary")
        XCTAssertEqual(
            req.url?.absoluteString,
            "https://live.trading212.com/api/v0/equity/account/summary")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertTrue(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }

    func testDecodeSummarySumsCashBuckets() throws {
        let json = Data("""
        {
          "currency": "EUR",
          "totalValue": 10500.00,
          "cash": { "availableToTrade": 450.00, "inPies": 50.00, "reservedForOrders": 0 },
          "investments": {
            "currentValue": 10000.00, "totalCost": 9000.00,
            "unrealizedProfitLoss": 1000.00, "realizedProfitLoss": 250.00
          }
        }
        """.utf8)
        let s = try Trading212Client.decodeSummary(json)
        XCTAssertEqual(s.totalValueEur, Decimal(string: "10500.00"))
        XCTAssertEqual(s.cashEur, Decimal(string: "500.00"))
        XCTAssertEqual(s.costBasisEur, Decimal(string: "9000.00"))
        XCTAssertEqual(s.realizedPnlEur, Decimal(string: "250.00"))
    }

    func testDecodeSummaryToleratesMissingSections() throws {
        let s = try Trading212Client.decodeSummary(Data(#"{"totalValue": 10}"#.utf8))
        XCTAssertEqual(s.totalValueEur, 10)
        XCTAssertNil(s.cashEur)
        XCTAssertNil(s.costBasisEur)
        XCTAssertEqual(s.currency, "EUR")
    }

    func testCryptoRequestSortsIdsAndAsksForEur() {
        let req = CryptoPriceClient().makeRequest(coinIds: ["ethereum", "bitcoin"])
        XCTAssertEqual(
            req.url?.absoluteString,
            "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=eur")
    }

    func testDecodePricesPicksTheRequestedCurrency() throws {
        let json = Data(#"{"bitcoin":{"eur":57176.0,"usd":62000.0},"ethereum":{"eur":1721.09}}"#.utf8)
        let prices = try CryptoPriceClient.decodePrices(json)
        XCTAssertEqual(prices["bitcoin"], Decimal(string: "57176.0"))
        XCTAssertEqual(prices["ethereum"], Decimal(string: "1721.09"))
        XCTAssertEqual(prices.count, 2)
    }

    func testDecodePricesSkipsCoinsMissingThatCurrency() throws {
        let prices = try CryptoPriceClient.decodePrices(Data(#"{"bitcoin":{"usd":62000.0}}"#.utf8))
        XCTAssertTrue(prices.isEmpty)
    }
}

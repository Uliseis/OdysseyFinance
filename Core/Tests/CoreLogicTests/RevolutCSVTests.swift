import XCTest
@testable import CoreLogic

final class RevolutCSVTests: XCTestCase {
    typealias R = CoreLogic.RevolutCSV

    // Ids must match the web importer's scheme byte for byte.
    func testSlugMatchesWebScheme() {
        XCTAssertEqual(R.slug("El Corte Inglés"), "el-corte-ingle-s")
        XCTAssertEqual(R.slug("Náutico del Puerto"), "na-utico-del-puerto")
        XCTAssertEqual(R.slug("  Coop.vitivinicola Ejemplo "), "coop-vitivinicola-ejemplo")
        XCTAssertEqual(R.slug("Uber   *one"), "uber-one")
        XCTAssertEqual(R.slug(String(repeating: "ab-", count: 20)).count, 40)
    }

    func testEarlyMorningMadridChargeKeysToPreviousUTCDay() throws {
        let csv = """
        Type,Started Date,Completed Date,Description,Amount,Fee,Balance
        CARD_PAYMENT,2026-07-26 00:30:00,2026-07-27 10:00:00,Shoe Shop,-19.95,0.00,-100.00
        TRANSFER,2026-08-19 18:00:00,2026-08-19 18:00:00,To EUR,500.00,0.00,85.00
        CARD_PAYMENT,2026-08-19 03:00:00,2026-08-20 10:00:00,Náutico del Puerto,-7.50,0.00,69.00
        CARD_PAYMENT,2026-08-19 03:05:00,2026-08-20 10:00:00,Náutico del Puerto,-7.50,0.00,77.00
        """
        let parsed = try R.parse(csv)
        XCTAssertEqual(parsed.skippedTransfers, 1)
        XCTAssertEqual(parsed.errors, [])
        XCTAssertEqual(parsed.rows.map(\.externalId), [
            "revolutcsv:v1:2026-07-25:-19.95:shoe-shop:0",
            "revolutcsv:v1:2026-08-19:-7.50:na-utico-del-puerto:0",
            "revolutcsv:v1:2026-08-19:-7.50:na-utico-del-puerto:1",
        ])
        XCTAssertEqual(parsed.rows[0].amount, Decimal(string: "-19.95"))
        XCTAssertEqual(parsed.rows[0].startedAt, ISO8601DateFormatter().date(from: "2026-07-25T22:30:00Z"))
        XCTAssertEqual(parsed.rows[0].completedAt, ISO8601DateFormatter().date(from: "2026-07-27T08:00:00Z"))
        XCTAssertEqual(parsed.rows[1].description, "Náutico del Puerto")
    }

    func testRejectsForeignFormatsAndBadRows() throws {
        XCTAssertThrowsError(try R.parse("Foo,Bar\n1,2"))
        XCTAssertEqual(R.normalizeAmount("1,234.56"), "1234.56")
        XCTAssertEqual(R.normalizeAmount("12,5"), "12.5")
        XCTAssertNil(R.normalizeAmount("1.234,56"))
        let parsed = try R.parse("Type,Started Date,Completed Date,Description,Amount\r\nCARD_PAYMENT,,,\"Quoted, name\",-1.00\r\nCARD_PAYMENT,2026-01-01 12:00:00,,\"Quoted, name\",-1.00\r\n")
        XCTAssertEqual(parsed.errors.count, 1)
        XCTAssertEqual(parsed.rows.first?.description, "Quoted, name")
        XCTAssertEqual(parsed.rows.first?.externalId, "revolutcsv:v1:2026-01-01:-1.00:quoted-name:0")
    }
}

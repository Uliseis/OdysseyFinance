import XCTest
@testable import CoreLogic

final class AmexCSVTests: XCTestCase {
    typealias C = CoreLogic.StatementCSV

    private let header = "Fecha,Descripción,Importe,Detalles ampliados,Aparece en su Estado de Cuenta como,"
        + "Dirección,Población/Provincia,Código postal,País,Referencia,Categoría"

    func testParsesFullDetailsExport() throws {
        let csv = header + "\n" + """
        14/03/2026,SAMPLE GROCER  MADRID,"12,50",,SAMPLE GROCER  MADRID,"CALLE EJEMPLO 1
        LOCAL 2",MADRID,28000,SPAIN,'REF0000000000000000000001',Productos-Comestibles
        15/03/2026,EXAMPLE STORE,"1.234,56",,EXAMPLE STORE,,,,,'REF0000000000000000000002',Productos-Otros Productos
        16/03/2026,,"-20,00",,EXAMPLE REFUND,,,,UNITED KINGDOM OF GB AND NI,'REF0000000000000000000003',

        """
        let parsed = try C.parse(csv)

        XCTAssertEqual(parsed.format, .amex)
        XCTAssertEqual(parsed.errors, [])
        XCTAssertEqual(parsed.rows.map(\.externalId), [
            "amex:v1:REF0000000000000000000001",
            "amex:v1:REF0000000000000000000002",
            "amex:v1:REF0000000000000000000003",
        ])
        // Charges are positive in the export and stored as debits; a negative row is a credit.
        XCTAssertEqual(parsed.rows.map(\.amount), [Decimal(string: "-12.50"), Decimal(string: "-1234.56"), 20])
        XCTAssertEqual(parsed.rows.map(\.description), ["SAMPLE GROCER  MADRID", "EXAMPLE STORE", "EXAMPLE REFUND"])
        // Noon in Madrid: CET before the March clock change.
        XCTAssertEqual(parsed.rows[0].startedAt, ISO8601DateFormatter().date(from: "2026-03-14T11:00:00Z"))
        XCTAssertNil(parsed.rows[0].completedAt)
        XCTAssertTrue(parsed.rows.allSatisfy(\.dateOnly))
    }

    func testNeedsReferenciaAndReportsUnreadableRows() throws {
        XCTAssertThrowsError(try C.parse("Fecha,Descripción,Importe\n14/03/2026,X,\"1,00\"")) {
            XCTAssertEqual($0 as? C.ParseError, .missingColumns(["Referencia"]))
        }
        let parsed = try C.parse(header + "\n14/03/2026,NO REF,\"1,00\",,,,,,,,\n,NO DATE,\"1,00\",,,,,,,'REF9',\n03/2026,BAD DATE,\"1,00\",,,,,,,'REF8',\n")
        XCTAssertEqual(parsed.rows, [])
        XCTAssertEqual(parsed.errors.count, 3)
    }

    func testDetectsFormatByHeader() throws {
        let revolut = try C.parse("Type,Started Date,Completed Date,Description,Amount\nCARD_PAYMENT,2026-03-04 12:00:00,,Shoe Shop,-19.95")
        XCTAssertEqual(revolut.format, .revolut)
        XCTAssertFalse(revolut.rows[0].dateOnly)
        XCTAssertThrowsError(try C.parse("Foo,Bar\n1,2")) {
            XCTAssertEqual($0 as? C.ParseError, .missingColumns(CoreLogic.RevolutCSV.requiredColumns))
        }
    }
}

import XCTest
@testable import CoreLogic

final class MyInvestorMovementsCSVTests: XCTestCase {
    typealias M = CoreLogic.MyInvestorMovementsCSV
    typealias F = CoreLogic.Funds

    private let header = "Fecha de operación;Fecha de valor;Concepto;Importe;Divisa"
    private let fundA = "ZZ0000000A00"
    private let fundB = "ZZ0000000B09"

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private func utcDay(_ y: Int, _ m: Int, _ dd: Int) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: dd))!
    }

    private func parseError(_ rows: String...) -> M.ParseError? {
        do {
            _ = try M.parse(([header] + rows).joined(separator: "\n"))
            return nil
        } catch {
            return error as? M.ParseError
        }
    }

    // MARK: - Parser

    func testParsesExportWithBOMAndCRLFKeepingFileOrder() throws {
        let text = "\u{FEFF}" + [
            header,
            "22/01/2030;20/01/2030;EXAMPLE BOND FUND LC EU;12.345,67;EUR",
            "17/01/2030;16/01/2030;EXAMPLE GLOBAL INDEX FUND @ 12;-250,50;EUR",
            "13/01/2030;12/01/2030;PERIODO 12/12/2029 12/01/2030;0,17;EUR",
            "10/01/2030;10/01/2030;TRANSFER MYINVESTOR;1000;EUR",
            "09/01/2030;09/01/2030;Transferencia desde MyInvestor;-50;EUR",
            "08/01/2030;08/01/2030;EXAMPLE PENSION PLAN PP;-1.250;EUR",
            "05/01/2030;05/01/2030;;12,34;EUR",
        ].joined(separator: "\r\n") + "\r\n"

        let rows = try M.parse(text)

        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows[0], M.Row(operationDate: utcDay(2030, 1, 22), valueDate: utcDay(2030, 1, 20),
                                      concept: "EXAMPLE BOND FUND LC EU", amountEur: d("12345.67")))
        XCTAssertEqual(rows.map(\.amountEur), [d("12345.67"), d("-250.5"), d("0.17"), 1000, -50, -1250, d("12.34")])
        XCTAssertEqual(rows[1].concept, "EXAMPLE GLOBAL INDEX FUND @ 12")
        XCTAssertEqual(rows[6].concept, "")
        XCTAssertEqual(rows[6].operationDate, utcDay(2030, 1, 5))
    }

    func testAmountForms() throws {
        let cases = ["1.234.567,89": "1234567.89", "-1.250": "-1250", "-1.250,5": "-1250.5", "0,5": "0.5",
                     "-0,17": "-0.17", "999": "999", "1250,00": "1250"]
        for (text, expected) in cases {
            let rows = try M.parse([header, "05/01/2030;05/01/2030;X;\(text);EUR"].joined(separator: "\n"))
            XCTAssertEqual(rows.first?.amountEur, d(expected), text)
        }
    }

    func testRefusesAmountsNotInTheSpanishFormat() {
        // A '.' before two digits or a third decimal would be the other format read the wrong way.
        for amount in ["1,234.56", "12.34", "1.25", "12,345", "1.2345", "+5", "−5", "1 250", "EUR", ""] {
            XCTAssertEqual(parseError("05/01/2030;05/01/2030;X;\(amount);EUR"), .invalidAmount(line: 2, amount), amount)
        }
    }

    func testRefusesUnknownHeaderOtherCurrenciesBadDatesAndFieldCounts() {
        XCTAssertThrowsError(try M.parse("Fecha;Concepto;Importe\n05/01/2030;X;1")) {
            XCTAssertEqual($0 as? M.ParseError, .unknownHeader(["Fecha", "Concepto", "Importe"]))
        }
        XCTAssertThrowsError(try M.parse("")) {
            XCTAssertEqual($0 as? M.ParseError, .unknownHeader([]))
        }
        XCTAssertEqual(parseError("05/01/2030;05/01/2030;X;12,34;USD"), .unsupportedCurrency(line: 2, "USD"))
        XCTAssertEqual(parseError("05/01/2030;05/01/2030;X;12,34;"), .unsupportedCurrency(line: 2, ""))
        XCTAssertEqual(parseError("2030-01-05;05/01/2030;X;1;EUR"), .invalidDate(line: 2, "2030-01-05"))
        XCTAssertEqual(parseError("05/01/2030;31/02/2030;X;1;EUR"), .invalidDate(line: 2, "31/02/2030"))
        XCTAssertEqual(parseError("05/01/2030;05/01/2030;X;1"), .wrongFieldCount(line: 2))
        XCTAssertEqual(parseError("06/01/2030;06/01/2030;X;1;EUR", "05/01/2030;05/01/2030;A;B;1;EUR"),
                       .wrongFieldCount(line: 3))
    }

    // MARK: - Matching

    private func order(_ isin: String, _ day: Int, _ side: F.Side, _ amount: String) -> F.Trade {
        F.Trade(isin: isin, date: utcDay(2030, 3, day), side: side, units: 10, amountEur: d(amount))
    }

    private func movement(_ day: Int, _ amount: String, _ concept: String = "EXAMPLE FUND") -> M.Row {
        M.Row(operationDate: utcDay(2030, 3, day), valueDate: utcDay(2030, 3, day), concept: concept, amountEur: d(amount))
    }

    func testABuyMatchesADebitAndASaleACreditWithinSixDaysAndTwoPercent() {
        let buy = order(fundA, 10, .buy, "1000")
        func matched(_ m: M.Row) -> Bool { M.match([buy], to: [m]) == [0: 0] }

        XCTAssertTrue(matched(movement(10, "-1000")))
        XCTAssertTrue(matched(movement(16, "-1000")))
        XCTAssertFalse(matched(movement(17, "-1000")))
        XCTAssertFalse(matched(movement(9, "-1000")))
        XCTAssertFalse(matched(movement(12, "1000")))
        // 2% of the estimate either way.
        XCTAssertTrue(matched(movement(12, "-980")))
        XCTAssertTrue(matched(movement(12, "-1020")))
        XCTAssertFalse(matched(movement(12, "-979.99")))
        XCTAssertFalse(matched(movement(12, "-1020.01")))

        XCTAssertEqual(M.match([order(fundA, 10, .sell, "1000")], to: [movement(12, "-1000"), movement(12, "985")]), [0: 1])
    }

    func testMatchingIsGlobalByAmountGapThenDateGap() {
        let orders = [order(fundA, 10, .buy, "1000"), order(fundB, 10, .buy, "1010")]
        // Order by order, the first would take -1006 and leave the second 20 away. -1006 is
        // closer still to the second.
        XCTAssertEqual(M.match(orders, to: [movement(11, "-1006"), movement(11, "-990")]), [0: 1, 1: 0])
        // Same amount gap: the closer date wins.
        XCTAssertEqual(M.match([orders[0]], to: [movement(14, "-1000"), movement(12, "-1000")]), [0: 1])
    }

    func testASaleCreditCanFallShortByTheTaxWithheldOnItsGain() {
        let sell = order(fundA, 10, .sell, "1000")
        func matched(_ amount: String, gain: Decimal) -> Bool {
            M.match([sell], to: [movement(12, amount)], gains: [0: gain]) == [0: 0]
        }

        // 19% of a 400 gain plus the usual 2%: down to 904. Nothing changes above the estimate.
        XCTAssertTrue(matched("930", gain: 400))
        XCTAssertTrue(matched("904", gain: 400))
        XCTAssertFalse(matched("903.99", gain: 400))
        XCTAssertTrue(matched("1020", gain: 400))
        XCTAssertFalse(matched("1020.01", gain: 400))
        // No gain, or a loss, withholds nothing.
        XCTAssertFalse(matched("930", gain: 0))
        XCTAssertFalse(matched("979.99", gain: -300))
        XCTAssertTrue(matched("980", gain: -300))
        XCTAssertEqual(M.match([sell], to: [movement(12, "930")]), [:])
        // A buy's debit keeps to 2%.
        XCTAssertEqual(M.match([order(fundA, 10, .buy, "1000")], to: [movement(12, "-930")], gains: [0: 400]), [:])
    }

    func testANonFundCreditInsideTheWidenedWindowNeverBeatsTheSaleCredit() {
        let sell = order(fundA, 10, .sell, "1000")
        for concept in ["TRANSFER MYINVESTOR", "INTERESES DEPOSITO", "Promoción bienvenida"] {
            // The estimate to the cent, on the order's own day.
            XCTAssertEqual(M.match([sell], to: [movement(10, "1000", concept), movement(13, "930")], gains: [0: 400]),
                           [0: 1], concept)
        }
    }

    func testNonFundConceptsAreNeverMatched() {
        let buy = order(fundA, 10, .buy, "50"), sell = order(fundB, 10, .sell, "50")
        for concept in ["PERIODO 01/02/2030 01/03/2030", "TRANSFER MYINVESTOR", "Transferencia a cuenta",
                        "Aportación plan", "aportacion robo", "INTERESES DEPOSITO", "APERTURA DEPOSITO",
                        "Promoción bienvenida", "Retención IRPF"] {
            XCTAssertEqual(M.match([buy, sell], to: [movement(11, "-50", concept), movement(11, "50", concept)]), [:], concept)
        }
    }
}

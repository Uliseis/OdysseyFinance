import XCTest
@testable import CoreLogic

final class MyInvestorOrdersCSVTests: XCTestCase {
    typealias M = CoreLogic.MyInvestorOrdersCSV

    private let header = "Fecha de la orden;ISIN;Importe estimado;Nº de participaciones;Estado"
    private let fundA = "ZZ0000000A00"
    private let fundB = "ZZ0000000B09"
    private let fundC = "ZZ0000000C08"
    private let fundD = "ZZ0000000D07"

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

    // Lines as the export writes them, newest first, without the status column.
    private func done(_ lines: [String]) throws -> [M.Row] {
        try M.parse(([header] + lines.map { $0 + ";Finalizada" }).joined(separator: "\n")).rows
    }

    // MARK: - Parser

    func testParsesExportWithBOMAndCRLFKeepingFileOrder() throws {
        let text = "\u{FEFF}" + [
            header,
            "13/11/2030;\(fundA);1250 EUR;;En curso",
            "12/11/2030;\(fundA);250.5 EUR;;Pendiente",
            "05/11/2030;\(fundB);12500.50 EUR;1234,567;Finalizada",
            "04/11/2030;\(fundB);300 EUR;;Cancelada",
            "03/11/2030;\(fundA);100 EUR;12,5;Rechazada",
            "21/10/2030;\(fundA);250.50 EUR;12,345;Finalizada",
        ].joined(separator: "\r\n") + "\r\n"

        let parsed = try M.parse(text)

        XCTAssertEqual(parsed.rows.map(\.status), [.inProgress, .inProgress, .done, .cancelled, .rejected, .done])
        XCTAssertEqual(parsed.skippedInProgress, 2)
        XCTAssertEqual(parsed.skippedCancelled, 1)
        XCTAssertEqual(parsed.skippedRejected, 1)
        XCTAssertEqual(parsed.rows[2], M.Row(
            date: utcDay(2030, 11, 5), isin: fundB, amountEur: d("12500.50"), units: d("1234.567"), status: .done))
        XCTAssertEqual(parsed.rows[0].amountEur, 1250)
        XCTAssertNil(parsed.rows[0].units)
        XCTAssertEqual(parsed.rows[1].amountEur, d("250.5"))
        XCTAssertEqual(parsed.rows[4].units, d("12.5"))
        XCTAssertEqual(parsed.rows[5].date, utcDay(2030, 10, 21))
        XCTAssertEqual(parsed.rows[5].units, d("12.345"))
    }

    func testRefusesUnknownHeader() {
        XCTAssertThrowsError(try M.parse("Fecha;ISIN;Importe;Estado\n21/10/2030;\(fundA);1 EUR;Finalizada")) {
            XCTAssertEqual($0 as? M.ParseError, .unknownHeader(["Fecha", "ISIN", "Importe", "Estado"]))
        }
        XCTAssertThrowsError(try M.parse("")) {
            XCTAssertEqual($0 as? M.ParseError, .unknownHeader([]))
        }
    }

    func testRefusesBadISINStatusAndMissingUnits() {
        XCTAssertEqual(parseError("21/10/2030;ZZ0000000A01;250.50 EUR;12,345;Finalizada"),
                       .invalidISIN(line: 2, "ZZ0000000A01"))
        XCTAssertEqual(parseError("21/10/2030;\(fundA);250.50 EUR;12,345;Anulada"),
                       .unknownStatus(line: 2, "Anulada"))
        XCTAssertEqual(parseError("21/10/2030;\(fundA);250.50 EUR;;Finalizada"), .missingUnits(line: 2))
        XCTAssertEqual(parseError("21/10/2030;\(fundA);250.50 EUR;12,345"), .wrongFieldCount(line: 2))
        // Line numbers count the header.
        XCTAssertEqual(parseError("22/10/2030;\(fundA);1 EUR;1,000;Finalizada", "21/10/2030;\(fundA);1 EUR;1,000;Hecha"),
                       .unknownStatus(line: 3, "Hecha"))
    }

    func testRefusesMalformedNumbersAndDates() {
        for amount in ["250,50 EUR", "1.250,00 EUR", "12,500.50 EUR", "250.50", "250.50 USD", "-250.50 EUR", "EUR"] {
            XCTAssertEqual(parseError("21/10/2030;\(fundA);\(amount);12,345;Finalizada"),
                           .invalidAmount(line: 2, amount), amount)
        }
        for units in ["12.345", "1.234,567", "1,2,3", "abc", "0", "0,000", "-1,000"] {
            XCTAssertEqual(parseError("21/10/2030;\(fundA);250.50 EUR;\(units);Finalizada"),
                           .invalidUnits(line: 2, units), units)
        }
        for date in ["2030-10-21", "31/02/2030", "1/10/2030", "21/10/30"] {
            XCTAssertEqual(parseError("\(date);\(fundA);250.50 EUR;12,345;Finalizada"),
                           .invalidDate(line: 2, date), date)
        }
    }

    // MARK: - Inference

    func testHeldFundWithOnlyBuys() throws {
        let rows = try done([
            "20/03/2030;\(fundA);330.00 EUR;30,250",
            "20/02/2030;\(fundA);205.00 EUR;20,500",
            "20/01/2030;\(fundA);100.00 EUR;10,000",
        ])

        let result = M.infer(orders: rows, heldUnits: [fundA: d("60.75")])

        XCTAssertEqual(result.funds.map(\.isin), [fundA])
        XCTAssertEqual(result.funds[0].reading, .resolved([.buy, .buy, .buy]))
        XCTAssertEqual(result.funds[0].orders.map(\.units), [10, d("20.5"), d("30.25")])
        XCTAssertEqual(result.heldWithoutOrders, [:])
    }

    func testBuyBuySellSellFullExitWithinRounding() throws {
        let rows = try done([
            "20/04/2030;\(fundA);190.00 EUR;17,999",
            "20/03/2030;\(fundA);125.00 EUR;12,000",
            "20/02/2030;\(fundA);205.00 EUR;20,000",
            "20/01/2030;\(fundA);100.00 EUR;10,000",
        ])

        let result = M.infer(orders: rows, heldUnits: [:])

        XCTAssertEqual(result.funds[0].reading, .resolved([.buy, .buy, .sell, .sell]))
        XCTAssertEqual(result.funds[0].trades, [
            CoreLogic.Funds.Trade(isin: fundA, date: utcDay(2030, 1, 20), side: .buy, units: 10, amountEur: 100),
            CoreLogic.Funds.Trade(isin: fundA, date: utcDay(2030, 2, 20), side: .buy, units: 20, amountEur: 205),
            CoreLogic.Funds.Trade(isin: fundA, date: utcDay(2030, 3, 20), side: .sell, units: 12, amountEur: 125),
            CoreLogic.Funds.Trade(isin: fundA, date: utcDay(2030, 4, 20), side: .sell, units: d("17.999"), amountEur: 190),
        ])
    }

    func testIdenticalUnitsReadAsBuyThenFullSale() throws {
        let rows = try done([
            "20/02/2030;\(fundA);110.00 EUR;25,125",
            "20/01/2030;\(fundA);100.00 EUR;25,125",
        ])
        XCTAssertEqual(M.infer(orders: rows, heldUnits: [:]).funds[0].reading, .resolved([.buy, .sell]))
    }

    func testPartialSaleIsDecidedByHeldUnits() throws {
        let rows = try done([
            "20/02/2030;\(fundA);44.00 EUR;40,000",
            "20/01/2030;\(fundA);100.00 EUR;100,000",
        ])
        XCTAssertEqual(M.infer(orders: rows, heldUnits: [fundA: 60]).funds[0].reading, .resolved([.buy, .sell]))
        XCTAssertEqual(M.infer(orders: rows, heldUnits: [fundA: 140]).funds[0].reading, .resolved([.buy, .buy]))
    }

    func testTwoFittingReadingsAreAmbiguous() throws {
        let rows = try done([
            "20/03/2030;\(fundA);5.00 EUR;5,000",
            "20/02/2030;\(fundA);5.00 EUR;5,000",
            "20/01/2030;\(fundA);10.00 EUR;10,000",
        ])
        let result = M.infer(orders: rows, heldUnits: [fundA: 10])
        XCTAssertEqual(result.funds[0].reading, .ambiguous)
        XCTAssertNil(result.funds[0].trades)
    }

    func testNoReadingWhenEarlyBuysAreMissing() throws {
        // The first row sells units bought before the export window.
        let rows = try done([
            "20/03/2030;\(fundA);10.00 EUR;10,000",
            "20/02/2030;\(fundA);10.00 EUR;10,000",
            "20/01/2030;\(fundA);30.00 EUR;30,000",
        ])
        XCTAssertEqual(M.infer(orders: rows, heldUnits: [fundA: 20]).funds[0].reading, .noReading)
    }

    func testToleranceGrowsWithTheNumberOfOrders() throws {
        let rows = try done((1...10).map { String(format: "%02d/01/2030;\(fundA);1.00 EUR;1,001", 11 - $0) })
        // tol = max(0.002, 0.0005 × 10) = 0.005
        XCTAssertEqual(M.infer(orders: rows, heldUnits: [fundA: d("10.014")]).funds[0].reading,
                       .resolved(Array(repeating: .buy, count: 10)))
        XCTAssertEqual(M.infer(orders: rows, heldUnits: [fundA: d("10.016")]).funds[0].reading, .noReading)
    }

    func testLongHistoryWithNoFitFinishes() throws {
        // Every balance is a whole number of units, so half a unit is out of reach. All on one
        // day, so nothing closes below zero early: without remembering dead ends this explores
        // about 2^60 paths.
        let rows = try done(Array(repeating: "20/01/2030;\(fundA);1.00 EUR;1,000", count: 60))
        XCTAssertEqual(M.infer(orders: rows, heldUnits: [fundA: d("0.5")]).funds[0].reading, .noReading)
    }

    func testSameDayOrdersAreListedInTheOrderPlaced() throws {
        let rows = try done([
            "20/01/2030;\(fundA);5.00 EUR;5,000",
            "20/01/2030;\(fundA);8.00 EUR;8,000",
        ])
        let fund = M.infer(orders: rows, heldUnits: [fundA: 3]).funds[0]
        XCTAssertEqual(fund.orders.map(\.units), [8, 5])
        XCTAssertEqual(fund.reading, .resolved([.buy, .sell]))
    }

    // MARK: - Same-day orders

    // Funds bought and the reading, independent of the order rows sit in within a day.
    private func outcome(_ rows: [M.Row], held: [String: Decimal]) -> [String] {
        M.infer(orders: rows, heldUnits: held).funds.map { fund in
            guard let trades = fund.trades else { return "\(fund.isin) \(fund.reading)" }
            return trades.map { "\(fund.isin) \($0.date) \($0.side) \($0.units) \($0.amountEur)" }
                .sorted().joined(separator: ", ")
        }
    }

    func testSameDayOrdersOfEqualUnitsThatFitEitherWayAreAmbiguousInEitherFileOrder() throws {
        // Either order could be the buy. On the first day, and on a later one after a full exit.
        let firstDay = try done([
            "20/01/2030;\(fundA);55.00 EUR;5,000",
            "20/01/2030;\(fundA);50.00 EUR;5,000",
        ])
        let laterDay = try done([
            "20/03/2030;\(fundA);55.00 EUR;5,000",
            "20/03/2030;\(fundA);50.00 EUR;5,000",
            "20/02/2030;\(fundA);110.00 EUR;10,000",
            "20/01/2030;\(fundA);100.00 EUR;10,000",
        ])
        for rows in [firstDay, laterDay] {
            XCTAssertEqual(M.infer(orders: rows, heldUnits: [:]).funds[0].reading, .ambiguous)
            XCTAssertEqual(M.infer(orders: rows.reversed(), heldUnits: [:]).funds[0].reading, .ambiguous)
        }
    }

    func testASameDaySaleCountsThatDaysBuyFirst() throws {
        // The 5-unit order was placed first, but it can only be the sale.
        let rows = try done([
            "20/01/2030;\(fundA);8.00 EUR;8,000",
            "20/01/2030;\(fundA);5.00 EUR;5,000",
        ])
        let fund = M.infer(orders: rows, heldUnits: [fundA: 3]).funds[0]
        XCTAssertEqual(fund.orders.map(\.units), [5, 8])
        XCTAssertEqual(fund.reading, .resolved([.sell, .buy]))
        XCTAssertEqual(outcome(rows, held: [fundA: 3]), outcome(rows.reversed(), held: [fundA: 3]))
    }

    func testReversingTheFileNeverChangesTheOutcome() throws {
        let cases: [(lines: [String], held: [String: Decimal], expected: String)] = [
            // Buy 2 and 4, sell 5, all on one day.
            (["20/01/2030;\(fundA);5.00 EUR;5,000",
              "20/01/2030;\(fundA);4.00 EUR;4,000",
              "20/01/2030;\(fundA);2.00 EUR;2,000"], [fundA: 1], "resolved"),
            // From 10 held: sell 4, buy 6, sell 3 on one day.
            (["20/02/2030;\(fundA);30.00 EUR;3,000",
              "20/02/2030;\(fundA);66.00 EUR;6,000",
              "20/02/2030;\(fundA);40.00 EUR;4,000",
              "20/01/2030;\(fundA);100.00 EUR;10,000"], [fundA: 9], "resolved"),
            (["20/01/2030;\(fundA);55.00 EUR;5,000",
              "20/01/2030;\(fundA);50.00 EUR;5,000"], [:], "ambiguous"),
            (["20/01/2030;\(fundA);5.00 EUR;5,000",
              "20/01/2030;\(fundA);4.00 EUR;4,000"], [fundA: 9], "resolved"),
            // Nothing held: selling 5 of the 4 bought that day closes it below zero.
            (["20/01/2030;\(fundA);5.00 EUR;5,000",
              "20/01/2030;\(fundA);4.00 EUR;4,000"], [:], "noReading"),
        ]
        for (i, c) in cases.enumerated() {
            let rows = try done(c.lines)
            let forward = outcome(rows, held: c.held)
            XCTAssertEqual(forward, outcome(rows.reversed(), held: c.held), "case \(i)")
            let reading = M.infer(orders: rows, heldUnits: c.held).funds[0].reading
            switch (reading, c.expected) {
            case (.resolved, "resolved"), (.ambiguous, "ambiguous"), (.noReading, "noReading"): break
            default: XCTFail("case \(i): \(reading)")
            }
        }
    }

    func testIgnoresUnfinishedOrdersAndReportsHeldFundsWithoutOrders() throws {
        let rows = try M.parse([
            header,
            "21/10/2030;\(fundA);50 EUR;;En curso",
            "20/10/2030;\(fundA);100 EUR;10,000;Finalizada",
            "19/10/2030;\(fundB);70 EUR;7,000;Cancelada",
        ].joined(separator: "\n")).rows

        let result = M.infer(orders: rows, heldUnits: [fundA: 10, fundC: d("3.5"), fundD: 0])

        XCTAssertEqual(result.funds.map(\.isin), [fundA])
        XCTAssertEqual(result.funds[0].reading, .resolved([.buy]))
        XCTAssertEqual(result.heldWithoutOrders, [fundC: d("3.5")])
    }
}

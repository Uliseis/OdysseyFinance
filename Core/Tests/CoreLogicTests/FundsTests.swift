import XCTest
@testable import CoreLogic

final class FundsTests: XCTestCase {
    typealias F = CoreLogic.Funds

    private let a = "ZZ0000000A00"
    private let b = "ZZ0000000B09"
    private let c = "ZZ0000000C08"
    private let e = "ZZ0000000E06"
    private let f = "ZZ0000000F05"

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    // UTC start of day, n days after 1 March 2030.
    private func day(_ n: Int) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2030, month: 3, day: 1))!
        return cal.date(byAdding: .day, value: n, to: base)!
    }

    private func trade(_ isin: String, _ n: Int, _ side: F.Side, _ units: String, _ amount: String) -> F.Trade {
        F.Trade(isin: isin, date: day(n), side: side, units: d(units), amountEur: d(amount))
    }

    // Booked mid-afternoon: the ledger works in UTC days, not instants.
    private func leg(_ n: Int, _ amount: String) -> CoreLogic.Investments.ContributionLeg {
        .init(accountId: UUID(), bookedAt: day(n).addingTimeInterval(15 * 3600), netEur: d(amount))
    }

    private func price(_ n: Int, _ eur: String) -> F.PricePoint {
        F.PricePoint(date: day(n), priceEur: d(eur))
    }

    // MARK: - ISIN

    func testISINCheckDigit() {
        // Every ISIN the fund tests use. They are made up, with a valid check digit.
        for isin in [a, b, c, "ZZ0000000D07", e, f] {
            XCTAssertTrue(F.isValidISIN(isin), isin)
        }
        XCTAssertFalse(F.isValidISIN("ZZ0000000A01"))
        XCTAssertFalse(F.isValidISIN("ZZ0000000A0"))
        XCTAssertFalse(F.isValidISIN("zz0000000a00"))
        XCTAssertFalse(F.isValidISIN("1Z0000000A00"))
        XCTAssertFalse(F.isValidISIN("ZZ0000000A0A"))
        XCTAssertFalse(F.isValidISIN("ZZ00000-0A00"))
    }

    // MARK: - Switches

    func testPairsSaleWithBuyOfAnotherFundWithinAWeekAndTwoPercent() {
        let trades = [
            trade(a, 0, .buy, "100", "1000"),
            trade(a, 10, .sell, "100", "1200"),
            trade(b, 12, .buy, "60", "1195"),
        ]
        XCTAssertEqual(F.pairSwitches(trades), [F.SwitchPair(sellIndex: 1, buyIndex: 2)])
    }

    func testSwitchNearMissesOnDateAmountAndFund() {
        let sell = trade(a, 10, .sell, "100", "1000")
        func pairs(_ buy: F.Trade) -> [F.SwitchPair] { F.pairSwitches([sell, buy]) }
        let paired = [F.SwitchPair(sellIndex: 0, buyIndex: 1)]

        XCTAssertEqual(pairs(trade(b, 10, .buy, "50", "1000")), paired)
        XCTAssertEqual(pairs(trade(b, 17, .buy, "50", "1000")), paired)
        XCTAssertEqual(pairs(trade(b, 18, .buy, "50", "1000")), [])
        XCTAssertEqual(pairs(trade(b, 9, .buy, "50", "1000")), [])
        // 2% of the larger amount.
        XCTAssertEqual(pairs(trade(b, 12, .buy, "50", "980")), paired)
        XCTAssertEqual(pairs(trade(b, 12, .buy, "50", "979.99")), [])
        XCTAssertEqual(pairs(trade(b, 12, .buy, "50", "1020.40")), paired)
        XCTAssertEqual(pairs(trade(b, 12, .buy, "50", "1020.41")), [])
        XCTAssertEqual(pairs(trade(a, 12, .buy, "50", "1000")), [])
        XCTAssertEqual(F.pairSwitches([sell, trade(b, 12, .sell, "50", "1000")]), [])
    }

    func testSwitchPairingTakesTheSmallestTotalAmountGapAndUsesEachOrderOnce() {
        let trades = [
            trade(a, 10, .sell, "100", "1000"),
            trade("ZZ0000000D07", 11, .sell, "80", "1000"),
            trade(b, 11, .buy, "40", "1008"),
            trade(b, 11, .buy, "40", "1002"),
            trade(c, 14, .buy, "20", "1000"),
        ]
        // c's exact buy and the nearer of b's amounts, though b's buys are closer in date.
        // Either sale can take c's buy for the same total of days: the earlier sale takes
        // the earlier buy.
        XCTAssertEqual(F.pairSwitches(trades), [
            F.SwitchPair(sellIndex: 0, buyIndex: 3),
            F.SwitchPair(sellIndex: 1, buyIndex: 4),
        ])
    }

    func testSwitchesChainedThroughAFundAllPair() {
        let trades = [
            trade(a, 0, .sell, "100", "6000.00"),
            trade(b, 1, .buy, "60", "6001.20"),
            trade(b, 7, .sell, "60", "6001.25"),
            trade(c, 7, .buy, "50", "6000.10"),
        ]
        // a's sale is closest in amount to c's buy, but taking it would leave b's legs unpaired.
        XCTAssertEqual(F.pairSwitches(trades), [
            F.SwitchPair(sellIndex: 0, buyIndex: 1),
            F.SwitchPair(sellIndex: 2, buyIndex: 3),
        ])
    }

    func testSwitchPairingPairsAsManyLegsAsItCanBeforeLookingAtAmounts() {
        let trades = [
            trade(a, 10, .sell, "100", "1000"),
            trade(e, 10, .sell, "90", "981"),
            trade(b, 11, .buy, "50", "1000"),
            trade(c, 11, .buy, "40", "1019"),
        ]
        // b's buy matches a's sale exactly, but it is the only buy within 2% of e's sale.
        XCTAssertEqual(F.pairSwitches(trades), [
            F.SwitchPair(sellIndex: 0, buyIndex: 3),
            F.SwitchPair(sellIndex: 1, buyIndex: 2),
        ])
    }

    func testALegWithNoPartnerLeftIsLeftUnpaired() {
        let trades = [
            trade(a, 10, .sell, "100", "1000"),
            trade(b, 11, .buy, "50", "1004"),
            trade(c, 12, .buy, "40", "1000"),
        ]
        XCTAssertEqual(F.pairSwitches(trades), [F.SwitchPair(sellIndex: 0, buyIndex: 2)])
    }

    func testSwitchPairingIgnoresTheOrderOfItsInput() {
        let trades = [
            trade(a, 0, .sell, "100", "1000"),
            trade(c, 1, .sell, "100", "1000"),
            trade(f, 1, .sell, "100", "1000"),
            trade(b, 1, .buy, "50", "1000"),
            trade(e, 2, .buy, "50", "1000"),
            trade(a, 30, .buy, "100", "1000"),
        ]
        // c's and f's sales take b's and e's buys a day in all either way round, and a's sale is
        // left over. In order of date, then fund, the earlier sale takes the earlier buy.
        let expected = [[1, 3], [2, 4]]
        for order in permutations(Array(trades.indices)) {
            let pairs = F.pairSwitches(order.map { trades[$0] })
            XCTAssertEqual(pairs.map { [order[$0.sellIndex], order[$0.buyIndex]] }.sorted { $0[0] < $1[0] },
                           expected, "\(order)")
        }
    }

    private func permutations(_ items: [Int]) -> [[Int]] {
        guard let first = items.first else { return [[]] }
        return permutations(Array(items.dropFirst())).flatMap { rest in
            (0...rest.count).map { i in
                var order = rest
                order.insert(first, at: i)
                return order
            }
        }
    }

    func testTwoSwitchesInOneWeekKeepTheirOwnAmounts() {
        let trades = [
            trade(a, 10, .sell, "100", "1000"),
            trade(c, 11, .sell, "100", "1010"),
            trade(b, 11, .buy, "50", "1000"),
            trade("ZZ0000000D07", 12, .buy, "50", "1010"),
        ]
        // The second sale and the first buy share a day, but their amounts are 10 apart.
        XCTAssertEqual(F.pairSwitches(trades), [
            F.SwitchPair(sellIndex: 0, buyIndex: 2),
            F.SwitchPair(sellIndex: 1, buyIndex: 3),
        ])
    }

    // MARK: - Positions

    func testFIFOPartialSalesAndRealisedGain() {
        // Out of order on purpose: lots follow the trade dates.
        let trades = [
            trade(a, 5, .sell, "15", "240"),
            trade(a, 1, .buy, "10", "100"),
            trade(a, 2, .buy, "10", "150"),
        ]

        let positions = F.positions(trades, prices: [a: 16])

        // The sale takes all of the first lot (100) and half of the second (75).
        XCTAssertEqual(positions, [F.Position(isin: a, units: 5, costEur: 75, realisedGainEur: 65, priceEur: 16)])
        XCTAssertEqual(positions[0].averagePriceEur, 15)
        XCTAssertEqual(positions[0].valueEur, 80)
        XCTAssertEqual(positions[0].unrealisedGainEur, 5)
    }

    func testPartialSaleConsumesALotProportionally() {
        let positions = F.positions([
            trade(a, 1, .buy, "8", "100"),
            trade(a, 2, .sell, "2", "30"),
        ])
        XCTAssertEqual(positions[0].units, 6)
        XCTAssertEqual(positions[0].costEur, 75)
        XCTAssertEqual(positions[0].realisedGainEur, 5)
        XCTAssertNil(positions[0].valueEur)
        XCTAssertNil(positions[0].unrealisedGainEur)
    }

    func testPartialSalesSplittingALotThreeWaysStayInCents() {
        let positions = F.positions([
            trade(a, 1, .buy, "3", "100"),
            trade(a, 2, .sell, "1", "40"),
            trade(a, 3, .buy, "3", "100"),
            trade(a, 4, .sell, "1", "40"),
            trade(a, 5, .sell, "2", "80"),
        ])

        // Costs taken: 100/3 → 33.33, then 66.67/2 → 33.34, then the last 33.33 plus a third
        // of the second lot, 33.33. The remaining two units carry 66.67.
        XCTAssertEqual(positions[0].units, 2)
        XCTAssertEqual(positions[0].costEur, d("66.67"))
        XCTAssertEqual(positions[0].realisedGainEur, d("26.67"))
        for value in [positions[0].costEur, positions[0].realisedGainEur] {
            var rounded = Decimal(), input = value
            NSDecimalRound(&rounded, &input, 2, .plain)
            XCTAssertEqual(rounded, value, "\(value) has a tail past the cent")
        }
    }

    func testSoldOutFundKeepsRealisedGainAndDropsRoundingDust() {
        let positions = F.positions([
            trade(a, 1, .buy, "12.345", "250.50"),
            trade(b, 1, .buy, "10", "100"),
            // CSV units are rounded to 3 places: the full exit can leave a thousandth behind.
            trade(a, 9, .sell, "12.344", "260"),
            trade(b, 9, .sell, "10", "90"),
        ])

        XCTAssertEqual(positions.map(\.isin), [a, b])
        XCTAssertEqual(positions[0], F.Position(isin: a, units: 0, costEur: 0, realisedGainEur: d("9.5"), priceEur: nil))
        XCTAssertEqual(positions[1].realisedGainEur, -10)
        XCTAssertNil(positions[0].averagePriceEur)
        XCTAssertEqual(positions[0].valueEur, 0)
        XCTAssertEqual(positions[0].unrealisedGainEur, 0)
    }

    func testSaleGainsAreFirstInFirstOutByIndex() {
        let trades = [
            trade(a, 7, .sell, "50", "600"),
            trade(a, 1, .buy, "50", "300"),
            trade(b, 1, .buy, "10", "100"),
            trade(a, 2, .buy, "50", "700"),
            trade(a, 5, .sell, "50", "1000"),
            trade(b, 6, .sell, "10", "80"),
        ]
        // The day-5 sale takes the 300 lot, the day-7 one the 700 lot.
        XCTAssertEqual(F.saleGains(trades), [0: -100, 4: 700, 5: -20])
        XCTAssertEqual(F.positions(trades).map(\.realisedGainEur), [600, -20])
    }

    // MARK: - Cash

    func testCashRunsFromTheAnchorAndFindsTheLowestDay() {
        let trades = [
            trade(a, 0, .buy, "1", "999"),
            trade(a, 2, .buy, "10", "600"),
            trade(b, 3, .buy, "5", "500"),
            trade(a, 4, .sell, "3", "200"),
        ]
        // The anchor is cash at the end of its day, so day-0 movements are already in it.
        let legs = [leg(0, "77"), leg(1, "1000"), leg(5, "-50")]

        let ledger = F.cashLedger(anchorEur: 20, anchorDate: day(0).addingTimeInterval(9 * 3600),
                                  legs: legs, trades: trades)

        XCTAssertEqual(ledger.days, [
            F.CashDay(date: day(0), cashEur: 20),
            F.CashDay(date: day(1), cashEur: 1020),
            F.CashDay(date: day(2), cashEur: 420),
            F.CashDay(date: day(3), cashEur: -80),
            F.CashDay(date: day(4), cashEur: 120),
            F.CashDay(date: day(5), cashEur: 70),
        ])
        XCTAssertEqual(ledger.currentEur, 70)
        // Below zero: a sale or a transfer in is missing.
        XCTAssertEqual(ledger.lowest, F.CashDay(date: day(3), cashEur: -80))
        XCTAssertEqual(ledger.cash(on: day(3).addingTimeInterval(20 * 3600)), -80)
        XCTAssertEqual(ledger.cash(on: day(30)), 70)
    }

    func testCashBeforeTheAnchorWorksBackwards() {
        // Anchored on a later reading rather than an opening balance.
        let ledger = F.cashLedger(anchorEur: 300, anchorDate: day(10),
                                  legs: [leg(2, "1000")], trades: [trade(a, 4, .buy, "10", "700")])

        XCTAssertEqual(ledger.cash(on: day(1)), 0)
        XCTAssertEqual(ledger.cash(on: day(3)), 1000)
        XCTAssertEqual(ledger.cash(on: day(4)), 300)
        XCTAssertEqual(ledger.cash(on: day(12)), 300)
        XCTAssertEqual(ledger.currentEur, 300)
        XCTAssertEqual(ledger.lowest, F.CashDay(date: day(4), cashEur: 300))
    }

    // MARK: - Daily value

    func testDayValueCarriesPricesForwardAWeekAndNeverReturnsAPartialTotal() {
        let trades = [
            trade(a, 1, .buy, "10", "100"),
            trade(b, 2, .buy, "4", "200"),
            trade(b, 20, .sell, "4", "220"),
        ]
        // Cash: 0, then 300 in and 100 out on day 1, 200 out on day 2, 220 in on day 20.
        let cash = F.cashLedger(anchorEur: 0, anchorDate: day(0), legs: [leg(1, "300")], trades: trades)
        let prices = [a: [price(30, "13"), price(0, "10"), price(3, "12")], b: [price(2, "50")]]
        func value(_ n: Int) -> F.DayValue { F.value(on: day(n), trades: trades, prices: prices, cash: cash) }

        XCTAssertEqual(value(0), F.DayValue(date: day(0), valueEur: 0, missingISINs: []))
        XCTAssertEqual(value(1), F.DayValue(date: day(1), valueEur: 300, missingISINs: []))
        XCTAssertEqual(value(5), F.DayValue(date: day(5), valueEur: 320, missingISINs: []))
        // b's day-2 price is seven days old on day 9 and too old on day 10.
        XCTAssertEqual(value(9).valueEur, 320)
        XCTAssertEqual(value(10), F.DayValue(date: day(10), valueEur: nil, missingISINs: [b]))
        XCTAssertEqual(value(11), F.DayValue(date: day(11), valueEur: nil, missingISINs: [a, b]))
        // b is sold out and needs no price; a's next price is still in the future.
        XCTAssertEqual(value(21), F.DayValue(date: day(21), valueEur: nil, missingISINs: [a]))
        XCTAssertEqual(value(30), F.DayValue(date: day(30), valueEur: 350, missingISINs: []))

        XCTAssertEqual(F.values(on: [day(5), day(10), day(30)], trades: trades, prices: prices, cash: cash),
                       [value(5), value(10), value(30)])
    }

    func testDayValueIgnoresRoundingDustLeftByAFullExit() {
        let trades = [trade(a, 1, .buy, "12.345", "250.50"), trade(a, 9, .sell, "12.344", "260")]
        let cash = F.cashLedger(anchorEur: d("250.50"), anchorDate: day(0), legs: [], trades: trades)
        XCTAssertEqual(F.value(on: day(30), trades: trades, prices: [:], cash: cash),
                       F.DayValue(date: day(30), valueEur: 260, missingISINs: []))
    }
}

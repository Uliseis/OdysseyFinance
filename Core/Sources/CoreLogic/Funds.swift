import Foundation

extension CoreLogic {
    // Fund holdings rebuilt from broker orders: switches, FIFO positions, cash at the broker
    // and the account's value on a given day. Dates are UTC days.
    public enum Funds {
        // Order exports round units to 3 places, so a full exit can leave a thousandth or two
        // behind. That is rounding, not a holding.
        static let unitsDust = Decimal(string: "0.002")!
        // An older price is a stale reading, not the fund's value that day.
        static let priceMaxAgeDays = 7

        public enum Side: String, Equatable, Sendable {
            case buy
            case sell
        }

        public struct Trade: Equatable, Sendable {
            public let isin: String
            public let date: Date
            public let side: Side
            public let units: Decimal
            public let amountEur: Decimal

            public init(isin: String, date: Date, side: Side, units: Decimal, amountEur: Decimal) {
                self.isin = isin
                self.date = date
                self.side = side
                self.units = units
                self.amountEur = amountEur
            }
        }

        // ISO 6166: two letters, nine letters or digits, then a Luhn check digit computed over
        // the code with each letter expanded to two digits (A = 10 … Z = 35).
        public static func isValidISIN(_ isin: String) -> Bool {
            let chars = Array(isin)
            let letters: ClosedRange<Character> = "A"..."Z", digits: ClosedRange<Character> = "0"..."9"
            guard chars.count == 12,
                  chars[0...1].allSatisfy(letters.contains),
                  chars[2...10].allSatisfy({ letters.contains($0) || digits.contains($0) }),
                  digits.contains(chars[11]) else { return false }
            let expanded = chars.flatMap { String(Int(String($0), radix: 36)!) }
            var sum = 0
            for (i, ch) in expanded.reversed().enumerated() {
                var n = ch.wholeNumberValue!
                if i % 2 == 1 { n *= 2; if n > 9 { n -= 9 } }
                sum += n
            }
            return sum % 10 == 0
        }

        // MARK: - Switches

        public struct SwitchPair: Equatable, Sendable {
            // Indices into the trades passed to pairSwitches.
            public let sellIndex: Int
            public let buyIndex: Int
        }

        // A switch sells one fund and buys another with the proceeds, settling up to a week
        // later for an amount that differs by fees and rounding: up to 2% of the larger one.
        // Legs pair all at once, since taking the closest pair first can break a chain of
        // switches: as many pairs as possible, then the smallest total amount gap, then the
        // smallest total day gap, then the earlier sale with the earlier buy.
        public static func pairSwitches(_ trades: [Trade]) -> [SwitchPair] {
            // By content, so the input's order never settles a tie.
            func ordered(_ side: Side) -> [Int] {
                trades.indices.filter { trades[$0].side == side }.sorted {
                    let x = trades[$0], y = trades[$1]
                    return (x.date, x.isin, x.amountEur, x.units) < (y.date, y.isin, y.amountEur, y.units)
                }
            }
            let sells = ordered(.sell), buys = ordered(.buy)
            guard !sells.isEmpty, !buys.isEmpty else { return [] }
            // Rows are sells, columns buys. A padding row or column, or a pair that can't be
            // a switch, leaves its legs unpaired.
            let n = max(sells.count, buys.count)
            let cost: [[PairCost]] = (0..<n).map { row in
                (0..<n).map { col in
                    guard row < sells.count, col < buys.count else { return PairCost(unpaired: 1) }
                    let sell = trades[sells[row]], buy = trades[buys[col]]
                    let dayGap = days(from: sell.date, to: buy.date)
                    let amountGap = relativeGap(sell.amountEur, buy.amountEur)
                    guard buy.isin != sell.isin, (0...7).contains(dayGap), amountGap <= Decimal(2) / 100 else {
                        return PairCost(unpaired: 2)
                    }
                    // The largest sum of rank products pairs ranks in order (rearrangement inequality).
                    return PairCost(amountGap: millionths(amountGap), dayGap: dayGap, rank: -row * col)
                }
            }
            return zip(sells.indices, cheapestAssignment(cost)).compactMap { row, col in
                cost[row][col].unpaired == 0 ? SwitchPair(sellIndex: sells[row], buyIndex: buys[col]) : nil
            }.sorted { $0.sellIndex < $1.sellIndex }
        }

        // Compared field by field, so one more pair outweighs any gap.
        private struct PairCost: Comparable, AdditiveArithmetic {
            var unpaired = 0, amountGap = 0, dayGap = 0, rank = 0

            static let zero = PairCost()
            static let infinity = PairCost(unpaired: .max)

            static func + (l: Self, r: Self) -> Self {
                .init(unpaired: l.unpaired + r.unpaired, amountGap: l.amountGap + r.amountGap,
                      dayGap: l.dayGap + r.dayGap, rank: l.rank + r.rank)
            }
            static func - (l: Self, r: Self) -> Self {
                .init(unpaired: l.unpaired - r.unpaired, amountGap: l.amountGap - r.amountGap,
                      dayGap: l.dayGap - r.dayGap, rank: l.rank - r.rank)
            }
            static func < (l: Self, r: Self) -> Bool {
                (l.unpaired, l.amountGap, l.dayGap, l.rank) < (r.unpaired, r.amountGap, r.dayGap, r.rank)
            }
        }

        // The Hungarian method on a square matrix: each row's column in the assignment with
        // the smallest total. Rows, columns and potentials are 1-based; column 0 holds the row
        // being placed.
        private static func cheapestAssignment(_ cost: [[PairCost]]) -> [Int] {
            let n = cost.count
            var u = [PairCost](repeating: .zero, count: n + 1), v = u
            var rowAt = [Int](repeating: 0, count: n + 1), way = rowAt
            for row in 1...n {
                rowAt[0] = row
                var col0 = 0
                var minv = [PairCost](repeating: .infinity, count: n + 1)
                var used = [Bool](repeating: false, count: n + 1)
                repeat {
                    used[col0] = true
                    let row0 = rowAt[col0]
                    var delta = PairCost.infinity, col1 = 0
                    for col in 1...n where !used[col] {
                        let reduced = cost[row0 - 1][col - 1] - u[row0] - v[col]
                        if reduced < minv[col] { minv[col] = reduced; way[col] = col0 }
                        if minv[col] < delta { delta = minv[col]; col1 = col }
                    }
                    for col in 0...n {
                        if used[col] { u[rowAt[col]] += delta; v[col] -= delta } else { minv[col] -= delta }
                    }
                    col0 = col1
                } while rowAt[col0] != 0
                repeat {
                    let col1 = way[col0]
                    rowAt[col0] = rowAt[col1]
                    col0 = col1
                } while col0 != 0
            }
            var colOf = [Int](repeating: 0, count: n)
            for col in 1...n { colOf[rowAt[col] - 1] = col - 1 }
            return colOf
        }

        // MARK: - Positions

        public struct Position: Equatable, Sendable {
            public let isin: String
            public let units: Decimal
            // FIFO cost of the units still held.
            public let costEur: Decimal
            public let realisedGainEur: Decimal
            public let priceEur: Decimal?

            public var averagePriceEur: Decimal? { units > 0 ? costEur / units : nil }
            // A sold-out fund is worth nothing, price or not.
            public var valueEur: Decimal? { units == 0 ? 0 : priceEur.map { units * $0 } }
            public var unrealisedGainEur: Decimal? { valueEur.map { $0 - costEur } }
        }

        // One position per fund traded, sold-out ones included so their realised gain stays visible.
        public static func positions(_ trades: [Trade], prices: [String: Decimal] = [:]) -> [Position] {
            let (lots, gains) = firstInFirstOut(trades)
            var realised: [String: Decimal] = [:]
            for (i, gain) in gains { realised[trades[i].isin, default: 0] += gain }
            return lots.keys.sorted().map { isin in
                let held = lots[isin]!
                return Position(
                    isin: isin,
                    units: held.reduce(0) { $0 + $1.units },
                    costEur: held.reduce(0) { $0 + $1.cost },
                    realisedGainEur: realised[isin] ?? 0,
                    priceEur: prices[isin])
            }
        }

        // What each sale realised, by its index in trades.
        static func saleGains(_ trades: [Trade]) -> [Int: Decimal] {
            firstInFirstOut(trades).gains
        }

        private typealias Lot = (units: Decimal, cost: Decimal)

        // The lots each fund still holds, and what each sale realised by its index in trades.
        private static func firstInFirstOut(_ trades: [Trade]) -> (lots: [String: [Lot]], gains: [Int: Decimal]) {
            var lots: [String: [Lot]] = [:]
            var gains: [Int: Decimal] = [:]
            for i in chronological(trades) {
                let trade = trades[i]
                var held = lots[trade.isin] ?? []
                switch trade.side {
                case .buy:
                    held.append((trade.units, trade.amountEur))
                case .sell:
                    let costBefore = held.reduce(0) { $0 + $1.cost }
                    var toSell = trade.units
                    var soldCost: Decimal = 0
                    while toSell > 0, let lot = held.first {
                        let take = min(toSell, lot.units)
                        // In cents, so the lot left behind stays in cents too: an unrounded
                        // share carries a 38-digit tail into every later cost and gain.
                        let cost = take == lot.units ? lot.cost : cents(lot.cost * take / lot.units)
                        soldCost += cost
                        toSell -= take
                        if take == lot.units { held.removeFirst() } else { held[0] = (lot.units - take, lot.cost - cost) }
                    }
                    if held.reduce(0, { $0 + $1.units }) <= unitsDust {
                        held = []
                        soldCost = costBefore
                    }
                    gains[i] = trade.amountEur - soldCost
                }
                lots[trade.isin] = held
            }
            return (lots, gains)
        }

        // MARK: - Cash

        public struct CashDay: Equatable, Sendable {
            public let date: Date
            // At the end of that day.
            public let cashEur: Decimal
        }

        public struct CashLedger: Equatable, Sendable {
            // The anchor day plus every day money moved, oldest first.
            public let days: [CashDay]
            // Before the first of those days.
            public let openingEur: Decimal

            public var currentEur: Decimal { days.last!.cashEur }
            // Below zero means a sale or a transfer in is missing from the data.
            public var lowest: CashDay { days.min { $0.cashEur < $1.cashEur }! }

            public func cash(on day: Date) -> Decimal {
                let start = Funds.dayStart(day)
                return days.last { $0.date <= start }?.cashEur ?? openingEur
            }
        }

        // The anchor is the cash at the end of anchorDate. Transfers in or out (legs) and trades
        // on later days move it forward; earlier ones are unwound so days before it have a balance too.
        public static func cashLedger(
            anchorEur: Decimal, anchorDate: Date,
            legs: [Investments.ContributionLeg], trades: [Trade]
        ) -> CashLedger {
            let anchorDay = dayStart(anchorDate)
            var moved: [Date: Decimal] = [anchorDay: 0]
            for leg in legs { moved[dayStart(leg.bookedAt), default: 0] += leg.netEur }
            for t in trades { moved[dayStart(t.date), default: 0] += t.side == .buy ? -t.amountEur : t.amountEur }

            let dates = moved.keys.sorted()
            let a = dates.firstIndex(of: anchorDay)!
            var cash = [Decimal](repeating: anchorEur, count: dates.count)
            for i in dates.indices where i > a { cash[i] = cash[i - 1] + moved[dates[i]]! }
            for i in dates.indices.reversed() where i < a { cash[i] = cash[i + 1] - moved[dates[i + 1]]! }
            return CashLedger(
                days: zip(dates, cash).map { CashDay(date: $0, cashEur: $1) },
                openingEur: cash[0] - moved[dates[0]]!)
        }

        // MARK: - Daily value

        public struct PricePoint: Equatable, Sendable {
            public let date: Date
            public let priceEur: Decimal

            public init(date: Date, priceEur: Decimal) {
                self.date = date
                self.priceEur = priceEur
            }
        }

        public struct DayValue: Equatable, Sendable {
            public let date: Date
            // nil when a fund held that day has no usable price: a total without it would
            // read as a loss that never happened.
            public let valueEur: Decimal?
            public let missingISINs: [String]
        }

        // Units held at the end of the day at the latest price no more than a week old, plus cash.
        public static func value(
            on day: Date, trades: [Trade], prices: [String: [PricePoint]], cash: CashLedger
        ) -> DayValue {
            let start = dayStart(day)
            let end = utc.date(byAdding: .day, value: 1, to: start)!
            let oldest = utc.date(byAdding: .day, value: -priceMaxAgeDays, to: start)!
            var units: [String: Decimal] = [:]
            for t in trades where t.date < end {
                units[t.isin, default: 0] += t.side == .buy ? t.units : -t.units
            }
            var total = cash.cash(on: start)
            var missing: [String] = []
            for (isin, held) in units.sorted(by: { $0.key < $1.key }) where held > unitsDust {
                let latest = prices[isin]?.filter { $0.date >= oldest && $0.date < end }.max { $0.date < $1.date }
                guard let latest else { missing.append(isin); continue }
                total += held * latest.priceEur
            }
            return DayValue(date: start, valueEur: missing.isEmpty ? total : nil, missingISINs: missing)
        }

        public static func values(
            on days: [Date], trades: [Trade], prices: [String: [PricePoint]], cash: CashLedger
        ) -> [DayValue] {
            days.map { value(on: $0, trades: trades, prices: prices, cash: cash) }
        }

        // MARK: - Helpers

        private static let utc: Calendar = {
            var cal = Calendar(identifier: .iso8601)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return cal
        }()

        static func dayStart(_ date: Date) -> Date { utc.startOfDay(for: date) }

        // Whole UTC days from one date's day to the other's.
        static func days(from start: Date, to end: Date) -> Int {
            utc.dateComponents([.day], from: dayStart(start), to: dayStart(end)).day!
        }

        // The difference as a share of the larger amount.
        static func relativeGap(_ a: Decimal, _ b: Decimal) -> Decimal {
            let larger = max(a, b)
            return larger > 0 ? abs(a - b) / larger : 0
        }

        // A share in whole millionths (hundredths of a basis point).
        private static func millionths(_ share: Decimal) -> Int {
            var input = share * 1_000_000, rounded = Decimal()
            NSDecimalRound(&rounded, &input, 0, .plain)
            return NSDecimalNumber(decimal: rounded).intValue
        }

        private static func cents(_ value: Decimal) -> Decimal {
            var input = value
            var rounded = Decimal()
            NSDecimalRound(&rounded, &input, 2, .plain)
            return rounded
        }

        // Indices by date, keeping the given order within a day.
        private static func chronological(_ trades: [Trade]) -> [Int] {
            trades.indices.sorted { (trades[$0].date, $0) < (trades[$1].date, $1) }
        }
    }
}

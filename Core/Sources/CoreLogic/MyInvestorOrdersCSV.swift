import Foundation

extension CoreLogic {
    // MyInvestor funds-orders export: ';'-separated, newest first, order date only. It has no
    // buy/sell column and no price, so the side of each order is inferred from its units and
    // the units still held today.
    public enum MyInvestorOrdersCSV {
        public static let columns = ["Fecha de la orden", "ISIN", "Importe estimado", "Nº de participaciones", "Estado"]

        public enum Status: Equatable, Sendable {
            case done
            case inProgress
            case cancelled
            case rejected
        }

        public struct Row: Equatable, Sendable {
            public let date: Date
            public let isin: String
            public let amountEur: Decimal
            // Only known once the order is done.
            public let units: Decimal?
            public let status: Status

            public init(date: Date, isin: String, amountEur: Decimal, units: Decimal?, status: Status) {
                self.date = date
                self.isin = isin
                self.amountEur = amountEur
                self.units = units
                self.status = status
            }
        }

        public struct Parsed: Equatable, Sendable {
            // Every row in file order. Only done rows become trades; the counts say how many didn't.
            public let rows: [Row]
            public let skippedInProgress: Int
            public let skippedCancelled: Int
            public let skippedRejected: Int
        }

        // `line` counts the header as line 1.
        public enum ParseError: Error, Equatable {
            case unknownHeader([String])
            case wrongFieldCount(line: Int)
            case invalidDate(line: Int, String)
            case invalidISIN(line: Int, String)
            case invalidAmount(line: Int, String)
            case invalidUnits(line: Int, String)
            case unknownStatus(line: Int, String)
            case missingUnits(line: Int)
        }

        public static func parse(_ text: String) throws -> Parsed {
            var records = StatementCSV.records(text, separator: ";")
            var header = records.isEmpty ? [] : records.removeFirst().map(trimmed)
            while header.last == "" { header.removeLast() }
            guard header == columns else { throw ParseError.unknownHeader(header) }

            var rows: [Row] = []
            for (i, record) in records.enumerated() {
                let line = i + 2
                let fields = record.map(trimmed)
                if fields.allSatisfy(\.isEmpty) { continue }
                guard fields.count >= columns.count, fields.dropFirst(columns.count).allSatisfy(\.isEmpty) else {
                    throw ParseError.wrongFieldCount(line: line)
                }
                let (dateText, isin, amountText, unitsText, statusText) = (fields[0], fields[1], fields[2], fields[3], fields[4])

                guard let date = parseDate(dateText) else { throw ParseError.invalidDate(line: line, dateText) }
                guard Funds.isValidISIN(isin) else { throw ParseError.invalidISIN(line: line, isin) }
                guard let amount = parseAmount(amountText) else { throw ParseError.invalidAmount(line: line, amountText) }
                guard let status = statuses[statusText.lowercased()] else {
                    throw ParseError.unknownStatus(line: line, statusText)
                }
                var units: Decimal?
                if !unitsText.isEmpty {
                    guard let parsed = parseUnits(unitsText) else { throw ParseError.invalidUnits(line: line, unitsText) }
                    units = parsed
                }
                if status == .done, units == nil { throw ParseError.missingUnits(line: line) }
                rows.append(Row(date: date, isin: isin, amountEur: amount, units: units, status: status))
            }
            return Parsed(
                rows: rows,
                skippedInProgress: rows.count { $0.status == .inProgress },
                skippedCancelled: rows.count { $0.status == .cancelled },
                skippedRejected: rows.count { $0.status == .rejected })
        }

        // MARK: - Side inference

        public enum Reading: Equatable, Sendable {
            case resolved([Funds.Side])
            case noReading
            case ambiguous
        }

        public struct FundReading: Equatable, Sendable {
            public let isin: String
            // Done orders, oldest first. A resolved reading's sides line up with these.
            public let orders: [Row]
            public let reading: Reading

            public var trades: [Funds.Trade]? {
                guard case .resolved(let sides) = reading else { return nil }
                return zip(orders, sides).map { order, side in
                    Funds.Trade(isin: isin, date: order.date, side: side, units: order.units ?? 0, amountEur: order.amountEur)
                }
            }
        }

        public struct Inference: Equatable, Sendable {
            // Sorted by ISIN.
            public let funds: [FundReading]
            // Held today but no done order in the export: bought before its window.
            public let heldWithoutOrders: [String: Decimal]
        }

        // heldUnits is today's units per fund still held; a fund missing from it is fully sold.
        public static func infer(orders: [Row], heldUnits: [String: Decimal]) -> Inference {
            var byISIN: [String: [Row]] = [:]
            // The export is newest first, so reversing it puts same-day orders in the order placed.
            for row in orders.reversed() where row.status == .done && row.units != nil {
                byISIN[row.isin, default: []].append(row)
            }
            let funds = byISIN.keys.sorted().map { isin in
                let chronological = byISIN[isin]!.enumerated()
                    .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
                    .map(\.element)
                // Grouping keeps each day's rows in order, so the days flatten back to chronological.
                let days = Dictionary(grouping: chronological, by: \.date)
                    .sorted { $0.key < $1.key }
                    .map { $0.value.map { $0.units! } }
                return FundReading(
                    isin: isin,
                    orders: chronological,
                    reading: readSides(days, target: heldUnits[isin] ?? 0))
            }
            return Inference(
                funds: funds,
                heldWithoutOrders: heldUnits.filter { byISIN[$0.key] == nil && $0.value > 0 })
        }

        // Units are rounded to 3 places in the export, so the slack grows with the number of
        // orders added up.
        static func tolerance(orders: Int) -> Decimal {
            max(Decimal(string: "0.002")!, Decimal(string: "0.0005")! * Decimal(orders))
        }

        // days holds each day's units, oldest day first; a resolved reading's sides follow the
        // same order. Every buy/sell assignment where the first day buys something, no day
        // closes below zero units and the last balance lands on the target. The export doesn't
        // say in what order a day's orders ran, so only the day's close counts, as if its buys
        // came first. Two fits are as good as many.
        static func readSides(_ days: [[Decimal]], target: Decimal) -> Reading {
            let units = days.flatMap { $0 }
            let tol = tolerance(orders: units.count)
            var remaining = [Decimal](repeating: 0, count: units.count + 1)
            for i in units.indices.reversed() { remaining[i] = remaining[i + 1] + units[i] }
            // The units still to come on the day of order i - 1: the most that day's close can
            // rise from here. Zero where a new day starts, because the previous one has closed.
            var restOfDay = [Decimal](repeating: 0, count: units.count + 1)
            var end = 0
            for day in days {
                let start = end
                end += day.count
                for i in start..<end where i > start { restOfDay[i] = remaining[i] - remaining[end] }
            }
            let firstDayEnd = days.first?.count ?? 0

            // The future from a state depends only on these three, which keeps the memo sound.
            struct State: Hashable { let index: Int; let balance: Decimal; let bought: Bool }
            var sides: [Funds.Side] = []
            var solutions: [[Funds.Side]] = []
            // A state that led nowhere once leads nowhere again; without this a long history
            // of similar units explores the same balances exponentially often.
            var deadEnds = Set<State>()

            func walk(_ i: Int, _ balance: Decimal, _ bought: Bool) {
                guard balance + restOfDay[i] >= -tol, i != firstDayEnd || bought else { return }
                if i == units.count {
                    if abs(balance - target) <= tol { solutions.append(sides) }
                    return
                }
                guard abs(target - balance) <= remaining[i] + tol else { return }
                let state = State(index: i, balance: balance, bought: bought)
                if deadEnds.contains(state) { return }
                let found = solutions.count
                for side in [Funds.Side.buy, .sell] {
                    sides.append(side)
                    walk(i + 1, side == .buy ? balance + units[i] : balance - units[i], bought || side == .buy)
                    sides.removeLast()
                    if solutions.count >= 2 { return }
                }
                if solutions.count == found { deadEnds.insert(state) }
            }
            walk(0, 0, false)

            switch solutions.count {
            case 0: return .noReading
            case 1: return .resolved(solutions[0])
            default: return .ambiguous
            }
        }

        // MARK: - Fields

        private static let statuses: [String: Status] = [
            "finalizada": .done,
            "en curso": .inProgress,
            "pendiente": .inProgress,
            "cancelada": .cancelled,
            "rechazada": .rejected,
        ]

        private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        static func parseDate(_ text: String) -> Date? {
            guard text.wholeMatch(of: /\d{2}\/\d{2}\/\d{4}/) != nil, let date = utcDay.date(from: text),
                  utcDay.string(from: date) == text else { return nil }
            return date
        }

        // "1250 EUR", "1250.50 EUR": '.' decimals, no grouping. Anything else could be a
        // thousands separator read the wrong way, so it is refused rather than guessed.
        private static func parseAmount(_ text: String) -> Decimal? {
            guard let match = text.wholeMatch(of: /(\d+(?:\.\d+)?) EUR/) else { return nil }
            return Decimal(string: String(match.1))
        }

        // "12,500": ',' decimals, no grouping.
        private static func parseUnits(_ text: String) -> Decimal? {
            guard text.wholeMatch(of: /\d+(?:,\d+)?/) != nil,
                  let units = Decimal(string: text.replacingOccurrences(of: ",", with: ".")), units > 0 else { return nil }
            return units
        }

        private static let utcDay = StatementCSV.formatter("dd/MM/yyyy", tz: "UTC")
    }
}

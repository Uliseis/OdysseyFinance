import Foundation

extension CoreLogic {
    // MyInvestor cash-movements export: ';'-separated, newest first. Every euro in or out of
    // the account's cash: fund orders, transfers, interest, pension and robo contributions,
    // promotions and tax, with no column saying which.
    public enum MyInvestorMovementsCSV {
        public static let columns = ["Fecha de operación", "Fecha de valor", "Concepto", "Importe", "Divisa"]

        public struct Row: Equatable, Sendable {
            public let operationDate: Date
            public let valueDate: Date
            // Free text; fund names come truncated. May be empty.
            public let concept: String
            // Negative for money out.
            public let amountEur: Decimal

            public init(operationDate: Date, valueDate: Date, concept: String, amountEur: Decimal) {
                self.operationDate = operationDate
                self.valueDate = valueDate
                self.concept = concept
                self.amountEur = amountEur
            }
        }

        // `line` counts the header as line 1.
        public enum ParseError: Error, Equatable {
            case unknownHeader([String])
            case wrongFieldCount(line: Int)
            case invalidDate(line: Int, String)
            case invalidAmount(line: Int, String)
            case unsupportedCurrency(line: Int, String)
        }

        public static func parse(_ text: String) throws -> [Row] {
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
                let (operationText, valueText, concept, amountText, currency) = (fields[0], fields[1], fields[2], fields[3], fields[4])

                guard let operationDate = MyInvestorOrdersCSV.parseDate(operationText) else {
                    throw ParseError.invalidDate(line: line, operationText)
                }
                guard let valueDate = MyInvestorOrdersCSV.parseDate(valueText) else {
                    throw ParseError.invalidDate(line: line, valueText)
                }
                guard let amount = parseAmount(amountText) else { throw ParseError.invalidAmount(line: line, amountText) }
                guard currency == "EUR" else { throw ParseError.unsupportedCurrency(line: line, currency) }
                rows.append(Row(operationDate: operationDate, valueDate: valueDate, concept: concept, amountEur: amount))
            }
            return rows
        }

        // MARK: - Matching orders

        // Concepts that are never a fund order. Only a safety net: the matching rules already
        // leave most of them out, so the list stays short.
        static let nonFundPrefixes = [
            "PERIODO", "TRANSFER MYINVESTOR", "Transferencia", "Aportacion",
            "INTERESES DEP", "APERTURA DEP", "PROMOCION", "retencion",
        ]

        // Spain's flat withholding on a fund sale's gain, taken before the credit lands.
        static let withholdingRate = Decimal(string: "0.19")!

        // The movement index settling each order, by order index: a buy's debit or a sale's
        // credit dated 0-6 days after the order and within 2% of its estimate. A sale's credit
        // can also be short by the tax withheld on its gain at the estimate (`gains`, by order
        // index; none if missing). Each movement settles one order, the smallest amount gap
        // relative to the larger amount first, then the smallest date gap.
        public static func match(_ orders: [Funds.Trade], to movements: [Row], gains: [Int: Decimal] = [:]) -> [Int: Int] {
            var candidates: [(amountGap: Decimal, dayGap: Int, order: Int, movement: Int)] = []
            for (m, movement) in movements.enumerated() where !isNonFund(movement.concept) {
                for (o, order) in orders.enumerated() where (order.side == .buy) == (movement.amountEur < 0) {
                    let dayGap = Funds.days(from: order.date, to: movement.operationDate)
                    let amount = abs(movement.amountEur)
                    let slack = order.amountEur * 2 / 100
                    let withheld = order.side == .sell ? max(0, gains[o] ?? 0) * withholdingRate : 0
                    guard (0...6).contains(dayGap),
                          amount >= order.amountEur - withheld - slack, amount <= order.amountEur + slack else { continue }
                    candidates.append((Funds.relativeGap(amount, order.amountEur), dayGap, o, m))
                }
            }
            candidates.sort { ($0.amountGap, $0.dayGap, $0.order, $0.movement) < ($1.amountGap, $1.dayGap, $1.order, $1.movement) }
            var matched: [Int: Int] = [:]
            var used = Set<Int>()
            for c in candidates where matched[c.order] == nil && !used.contains(c.movement) {
                matched[c.order] = c.movement
                used.insert(c.movement)
            }
            return matched
        }

        private static func isNonFund(_ concept: String) -> Bool {
            nonFundPrefixes.contains { concept.range(of: $0, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }
        }

        // MARK: - Fields

        private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        // "-1.250", "12.345,67", "1000": '.' groups thousands, ',' marks up to two decimals.
        // Anything else could be the other convention read the wrong way, so it is refused.
        private static func parseAmount(_ text: String) -> Decimal? {
            guard text.wholeMatch(of: /-?(?:\d{1,3}(?:\.\d{3})+|\d+)(?:,\d{1,2})?/) != nil else { return nil }
            return Decimal(string: text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
        }
    }
}

import Foundation
import CoreLogic

// What a MyInvestor import did, or why it was refused, in plain words. `names` holds fund
// names by ISIN from the price cache; a fund without one is named by its ISIN.
enum FundImportText {
    static func summary(_ s: CoreLogic.FundTrades.ImportSummary) -> [String] {
        let by = Money.format(s.amountsCorrectedEur, currency: "EUR")
        var lines = [
            "\(pluralized(s.inserted, "new order")) saved.",
            "\(pluralized(s.alreadyPresent, "order")) already saved.",
            "\(pluralized(s.matchedToCash, "order")) matched to cash movements.",
            "\(s.switchPairs) \(s.switchPairs == 1 ? "switch" : "switches") between funds"
                + (s.switchPairs > 0 ? ", \(s.switchPairsAdded) new." : "."),
            "\(pluralized(s.amountsCorrected, "saved amount")) corrected to the cash really moved"
                + (s.amountsCorrected > 0 ? " (\(s.amountsCorrectedEur > 0 ? "+" : "")\(by))." : "."),
        ]
        if s.skippedInProgress > 0 {
            let them = s.skippedInProgress == 1 ? "it" : "them"
            lines.append("\(pluralized(s.skippedInProgress, "order")) still in progress, not saved: a later export brings \(them) back finished.")
        }
        let dropped = s.skippedCancelled + s.skippedRejected
        if dropped > 0 { lines.append("\(pluralized(dropped, "cancelled or rejected order")) skipped.") }
        return lines
    }

    // For a fund imported before whose new orders may have sold some of it, so its field
    // starts empty.
    static func unitsHint(_ guess: CoreLogic.FundTrades.HeldUnitsGuess) -> String? {
        guard let saved = guess.savedUnits, guess.newOrders > 0 else { return nil }
        let units = saved.formatted(.number.precision(.fractionLength(0...6)))
        return "saved \(units) units · \(pluralized(guess.newOrders, "new order")) — enter today's units from MyInvestor"
    }

    static func refusal(_ error: Error, names: [String: String]) -> String {
        func funds(_ isins: [String]) -> String { isins.map { names[$0] ?? $0 }.formatted(.list(type: .and)) }
        func orders(_ keys: [String]) -> String { keys.map { order($0, names: names) }.joined(separator: "\n") }
        switch error {
        case let e as CoreLogic.FundTrades.ImportError:
            switch e {
            case .notInvestmentAccount:
                return "Only an investment account can hold fund orders."
            case .archived:
                return "This account is archived. Unarchive it before importing."
            case .heldWithoutOrders(let isins):
                return "The orders export has no finished order for \(funds(isins)), so the units entered for it can't be explained. Leave them empty until an order is finished, or export the orders from the very first one."
            case .unreadableFunds(let noReading, let ambiguous):
                var why: [String] = []
                if !noReading.isEmpty {
                    why.append("The orders for \(funds(noReading)) can't add up to the units entered. Check the units against MyInvestor, and that the export reaches back to the first order.")
                }
                if !ambiguous.isEmpty {
                    why.append("The orders for \(funds(ambiguous)) add up to the units entered in more than one way, so which were buys and which were sales can't be told.")
                }
                return why.joined(separator: "\n\n")
            case .sideConflicts(let keys):
                return "With the units entered, these orders saved before would change from a buy to a sale or the other way round:\n\(orders(keys))\nCheck the units for those funds."
            case .unitsMismatch(let isins):
                return "The orders saved before and the new ones don't add up to the units entered for \(funds(isins)). Check the units against MyInvestor. If they're right, an order whose amount MyInvestor has since restated would be counted twice."
            case .unmatchedOrders(let keys):
                return "No cash movement or switch partner for:\n\(orders(keys))\nExport the cash movements over the same period as the orders, or import again once the switch's other order is finished."
            }
        case CoreLogic.MyInvestorOrdersCSV.ParseError.unknownHeader(let header):
            return header == CoreLogic.MyInvestorMovementsCSV.columns
                ? "That's the cash-movements export. Choose the orders export here."
                : "That file isn't MyInvestor's orders export: its first line is “\(firstLine(header))”."
        case let e as CoreLogic.MyInvestorOrdersCSV.ParseError:
            return ordersLine(e)
        case CoreLogic.MyInvestorMovementsCSV.ParseError.unknownHeader(let header):
            return header == CoreLogic.MyInvestorOrdersCSV.columns
                ? "That's the orders export. Choose the cash-movements export here."
                : "That file isn't MyInvestor's cash-movements export: its first line is “\(firstLine(header))”."
        case let e as CoreLogic.MyInvestorMovementsCSV.ParseError:
            return movementsLine(e)
        default:
            return "The orders weren’t saved."
        }
    }

    private static func ordersLine(_ e: CoreLogic.MyInvestorOrdersCSV.ParseError) -> String {
        let at = { (line: Int) in "Line \(line) of the orders export" }
        switch e {
        case .unknownHeader: return "That file isn't MyInvestor's orders export."
        case .wrongFieldCount(let line): return "\(at(line)) doesn't have the five columns expected."
        case .invalidDate(let line, let text): return "\(at(line)) has a date that can't be read: “\(text)”."
        case .invalidISIN(let line, let text): return "\(at(line)) has an ISIN that isn't valid: “\(text)”."
        case .invalidAmount(let line, let text): return "\(at(line)) has an amount that can't be read: “\(text)”."
        case .invalidUnits(let line, let text): return "\(at(line)) has units that can't be read: “\(text)”."
        case .unknownStatus(let line, let text): return "\(at(line)) has a status this app doesn't know: “\(text)”."
        case .missingUnits(let line): return "\(at(line)) is a finished order without units."
        }
    }

    private static func movementsLine(_ e: CoreLogic.MyInvestorMovementsCSV.ParseError) -> String {
        let at = { (line: Int) in "Line \(line) of the cash-movements export" }
        switch e {
        case .unknownHeader: return "That file isn't MyInvestor's cash-movements export."
        case .wrongFieldCount(let line): return "\(at(line)) doesn't have the five columns expected."
        case .invalidDate(let line, let text): return "\(at(line)) has a date that can't be read: “\(text)”."
        case .invalidAmount(let line, let text): return "\(at(line)) has an amount that can't be read: “\(text)”."
        case .unsupportedCurrency(let line, let text): return "\(at(line)) is in \(text); only euros can be imported."
        }
    }

    // A wrong file can be one long line; its start is enough to recognise it.
    private static func firstLine(_ header: [String]) -> String {
        let line = header.joined(separator: ";")
        return line.count > 80 ? line.prefix(80) + "…" : line
    }

    // An import key reads "myinvestor:v1:<day>:<ISIN>:<units>:<amount>#<n>". Anything else is
    // shown as it is.
    private static func order(_ key: String, names: [String: String]) -> String {
        let parts = key.split(separator: ":").map(String.init)
        guard parts.count == 6, let day = FX.isoDayToDate(parts[2]),
              let units = Decimal(string: parts[4]),
              let amount = parts[5].split(separator: "#").first.flatMap({ Decimal(string: String($0)) }) else {
            return key
        }
        let date = day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
        let fund = names[parts[3]] ?? parts[3]
        return "• \(date), \(fund): \(units.formatted(.number.precision(.fractionLength(0...3)))) units, \(Money.format(amount, currency: "EUR"))"
    }
}

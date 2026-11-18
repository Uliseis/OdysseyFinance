import Foundation
import SwiftData
import CoreModel

extension CoreLogic {
    // Fund trades saved on an investment account (D16): importing MyInvestor's orders and
    // cash-movements exports, reading the trades back for Funds, and the cash held at the broker.
    public enum FundTrades {
        public struct ImportSummary: Equatable, Sendable {
            public let inserted: Int
            public let alreadyPresent: Int
            public let skippedInProgress: Int
            public let skippedCancelled: Int
            public let skippedRejected: Int
            // Orders in the export settled by a cash movement. The rest are switch legs.
            public let matchedToCash: Int
            // Switches among the export's orders, already grouped or not, and the ones grouped now.
            public let switchPairs: Int
            public let switchPairsAdded: Int
            // Saved trades whose amount this import replaced with the real one (saved earlier
            // from the estimate, say), and the sum of new minus old.
            public let amountsCorrected: Int
            public let amountsCorrectedEur: Decimal
            // From every trade on the account after the import.
            public let positions: [Funds.Position]
        }

        public enum ImportError: Error, Equatable {
            case notInvestmentAccount
            case archived
            // ISINs held today with no done order in the export: bought before its window, so
            // the export is incomplete.
            case heldWithoutOrders([String])
            // ISINs whose done orders fit no buy/sell reading, or more than one.
            case unreadableFunds(noReading: [String], ambiguous: [String])
            // Import keys already saved with the other side.
            case sideConflicts([String])
            // ISINs whose saved and new trades don't add up to the units held today: an order
            // saved twice under a restated amount, say.
            case unitsMismatch([String])
            // Import keys of done orders with neither a cash movement nor a switch partner: the
            // movements export misses them, or the switch's other leg isn't done yet.
            case unmatchedOrders([String])
        }

        // All or nothing: one error and nothing is written. In-progress orders aren't saved:
        // MyInvestor still counts their cash in the account balance, and a later export brings
        // them back as done. They do hold on to the debit already taken for them, so no done
        // order takes it. A trade's amount is the cash its order moved; an order that moved
        // none is a switch leg, and a switch sale is worth what reached the fund it bought.
        @MainActor @discardableResult
        public static func importOrders(
            ordersCSV: String, movementsCSV: String, heldUnits: [String: Decimal],
            into account: Account, in ctx: ModelContext, now: Date = .now
        ) throws -> ImportSummary {
            guard account.group?.kind == .investment else { throw ImportError.notInvestmentAccount }
            guard !account.archived else { throw ImportError.archived }
            let parsed = try MyInvestorOrdersCSV.parse(ordersCSV)
            let movements = try MyInvestorMovementsCSV.parse(movementsCSV)
            let inference = MyInvestorOrdersCSV.infer(orders: parsed.rows, heldUnits: heldUnits)
            guard inference.heldWithoutOrders.isEmpty else {
                throw ImportError.heldWithoutOrders(inference.heldWithoutOrders.keys.sorted())
            }

            var noReading: [String] = []
            var ambiguous: [String] = []
            var incoming: [(key: String, trade: Funds.Trade)] = []
            for fund in inference.funds {
                switch fund.reading {
                case .noReading: noReading.append(fund.isin)
                case .ambiguous: ambiguous.append(fund.isin)
                case .resolved: incoming += keyed(fund.trades ?? [])
                }
            }
            guard noReading.isEmpty, ambiguous.isEmpty else {
                throw ImportError.unreadableFunds(noReading: noReading, ambiguous: ambiguous)
            }

            let existing = try savedTrades(of: account, in: ctx)
            let byKey = Dictionary(existing.compactMap { t in t.importKey.map { ($0, t) } }) { first, _ in first }
            var fresh: [(key: String, trade: Funds.Trade)] = []
            var conflicts: [String] = []
            for item in incoming {
                if let saved = byKey[item.key] {
                    if trade(from: saved).side != item.trade.side { conflicts.append(item.key) }
                } else {
                    fresh.append(item)
                }
            }
            guard conflicts.isEmpty else { throw ImportError.sideConflicts(conflicts.sorted()) }

            // Saved and new trades together must come to today's units. Otherwise an order is
            // saved twice (a restated amount gives it a second key) or a trade is missing.
            var net: [String: (units: Decimal, count: Int)] = [:]
            for t in existing.map(trade(from:)) + fresh.map(\.trade) {
                net[t.isin, default: (0, 0)].units += t.side == .buy ? t.units : -t.units
                net[t.isin, default: (0, 0)].count += 1
            }
            let mismatched = Set(net.keys).union(heldUnits.keys).filter { isin in
                let (units, count) = net[isin] ?? (0, 0)
                return abs(units - (heldUnits[isin] ?? 0)) > MyInvestorOrdersCSV.tolerance(orders: count)
            }
            guard mismatched.isEmpty else { throw ImportError.unitsMismatch(mismatched.sorted()) }

            // Only the saved amount takes the real figure: keys stay built from the estimate, so
            // they don't move between exports.
            let orders = incoming.map(\.trade)
            // A sale's credit is net of the tax withheld on its gain, so the matcher takes each
            // sale's gain at its estimate. Lots go as saved trades are read: by day, buys first.
            let sequence = incoming.indices.sorted {
                (orders[$0].date, orders[$0].side == .buy ? 0 : 1, incoming[$0].key)
                    < (orders[$1].date, orders[$1].side == .buy ? 0 : 1, incoming[$1].key)
            }
            let gains = Funds.saleGains(sequence.map { orders[$0] })
            // Matched as buys: a sale in progress has no credit yet.
            let inProgress = parsed.rows.filter { $0.status == .inProgress }.map {
                Funds.Trade(isin: $0.isin, date: $0.date, side: .buy, units: 0, amountEur: $0.amountEur)
            }
            let cash = MyInvestorMovementsCSV.match(
                orders + inProgress, to: movements,
                gains: Dictionary(uniqueKeysWithValues: gains.map { (sequence[$0.key], $0.value) })
            ).filter { $0.key < orders.count }
            // For a sale to cash this is net of the tax withheld on the gain.
            let moved = orders.indices.map { i in cash[i].map { abs(movements[$0].amountEur) } ?? orders[i].amountEur }

            // A leg already saved in a switch keeps its partner, even if a closer one turns up.
            var groups: [UUID: [FundTrade]] = [:]
            for t in existing { if let g = t.switchGroupId { groups[g, default: []].append(t) } }
            var savedPartner: [Int: FundTrade] = [:]
            var open: [Int] = []
            for i in orders.indices where cash[i] == nil {
                if let leg = byKey[incoming[i].key], let g = leg.switchGroupId,
                   let partner = groups[g]?.first(where: { $0 !== leg }) {
                    savedPartner[i] = partner
                } else {
                    open.append(i)
                }
            }
            let newPairs = Funds.pairSwitches(open.map { orders[$0] }).map { (sell: open[$0.sellIndex], buy: open[$0.buyIndex]) }
            let paired = Set(newPairs.flatMap { [$0.sell, $0.buy] })
            let unpaired = open.filter { !paired.contains($0) }
            guard unpaired.isEmpty else { throw ImportError.unmatchedOrders(unpaired.map { incoming[$0].key }.sorted()) }

            let index = Dictionary(uniqueKeysWithValues: incoming.enumerated().map { ($1.key, $0) })
            var amounts = moved
            for pair in newPairs { amounts[pair.sell] = moved[pair.buy] }
            for (i, partner) in savedPartner where orders[i].side == .sell {
                amounts[i] = partner.importKey.flatMap { index[$0] }.map { moved[$0] } ?? partner.amountEur
            }

            var corrected = 0
            var correctedEur: Decimal = 0
            for (i, item) in incoming.enumerated() {
                guard let saved = byKey[item.key], saved.amountEur != amounts[i] else { continue }
                corrected += 1
                correctedEur += amounts[i] - saved.amountEur
                saved.amountEur = amounts[i]
            }
            var models = byKey
            let inserted = fresh.map { key, t in
                let model = FundTrade(
                    account: account, isin: t.isin, tradeDate: t.date, side: t.side == .buy ? .buy : .sell,
                    units: t.units, amountEur: amounts[index[key]!], importKey: key, createdAt: now, updatedAt: now)
                ctx.insert(model)
                models[key] = model
                return model
            }
            for pair in newPairs {
                let sell = models[incoming[pair.sell].key]!, buy = models[incoming[pair.buy].key]!
                // A leg whose partner is gone lends its group to the new one.
                let group = sell.switchGroupId ?? buy.switchGroupId ?? UUID()
                sell.switchGroupId = group
                buy.switchGroupId = group
            }
            do {
                try ctx.saveTouchingChanges(now: now)
            } catch {
                // Otherwise the writes stay pending and ride along with the next save.
                ctx.rollbackRefetching()
                throw error
            }

            return ImportSummary(
                inserted: inserted.count,
                alreadyPresent: incoming.count - fresh.count,
                skippedInProgress: parsed.skippedInProgress,
                skippedCancelled: parsed.skippedCancelled,
                skippedRejected: parsed.skippedRejected,
                matchedToCash: cash.count,
                switchPairs: newPairs.count + Set(savedPartner.values.compactMap(\.switchGroupId)).count,
                switchPairsAdded: newPairs.count,
                amountsCorrected: corrected,
                amountsCorrectedEur: correctedEur,
                positions: Funds.positions(chronological(existing + inserted).map(trade(from:))))
        }

        public struct HeldUnitsGuess: Equatable, Sendable {
            public let isin: String
            // nil when the account has no saved trades for the fund.
            public let savedUnits: Decimal?
            // The export's done orders for the fund that aren't saved yet.
            public let newOrders: Int

            public init(isin: String, savedUnits: Decimal?, newOrders: Int) {
                self.isin = isin
                self.savedUnits = savedUnits
                self.newOrders = newOrders
            }

            // Only with nothing new: saved units plus the new orders read as buys would pass the
            // import's units check even when one of them was a sale.
            public var prefill: Decimal? { newOrders == 0 ? savedUnits : nil }
        }

        // For the units held today that an import asks for, for every ISIN in the orders export,
        // sorted: what the fund's saved trades add up to and how many of the export's done
        // orders are new. For a fund without saved trades nothing says how much was sold.
        @MainActor
        public static func guessHeldUnits(
            ordersCSV: String, for account: Account, in ctx: ModelContext
        ) throws -> [HeldUnitsGuess] {
            let parsed = try MyInvestorOrdersCSV.parse(ordersCSV)
            let saved = try savedTrades(of: account, in: ctx)
            let savedKeys = Set(saved.compactMap(\.importKey))
            let held = Dictionary(uniqueKeysWithValues:
                Funds.positions(chronological(saved).map(trade(from:))).map { ($0.isin, $0.units) })
            // The done orders in the order an import keys them. A key leaves out the side, so the
            // readings are left unused.
            var newOrders: [String: Int] = [:]
            for fund in MyInvestorOrdersCSV.infer(orders: parsed.rows, heldUnits: [:]).funds {
                let trades = fund.orders.map {
                    Funds.Trade(isin: fund.isin, date: $0.date, side: .buy, units: $0.units ?? 0, amountEur: $0.amountEur)
                }
                newOrders[fund.isin] = keyed(trades).filter { !savedKeys.contains($0.key) }.count
            }
            return Set(parsed.rows.map(\.isin)).sorted().map { isin in
                HeldUnitsGuess(isin: isin, savedUnits: held[isin], newOrders: newOrders[isin] ?? 0)
            }
        }

        @MainActor
        public static func trades(for account: Account, in ctx: ModelContext) throws -> [Funds.Trade] {
            chronological(try savedTrades(of: account, in: ctx)).map(trade(from:))
        }

        // Pinned to the UTC day like the cost-basis opening: the day decides which transfers
        // and trades the anchor already includes.
        @MainActor
        public static func setBrokerCashAnchor(
            _ account: Account, amountEur: Decimal?, at date: Date?, in ctx: ModelContext
        ) throws {
            account.brokerCashAnchorEur = amountEur
            account.brokerCashAnchorAt = (amountEur == nil ? nil : date).map(Funds.dayStart)
            try ctx.saveTouchingChanges()
        }

        // nil until the anchor has both an amount and a day.
        @MainActor
        public static func cashLedger(for account: Account, in ctx: ModelContext) throws -> Funds.CashLedger? {
            guard let anchor = account.brokerCashAnchorEur, let day = account.brokerCashAnchorAt else { return nil }
            return Funds.cashLedger(
                anchorEur: anchor, anchorDate: day,
                legs: try Investments.listContributionLegs(for: [account.id], in: ctx),
                trades: try trades(for: account, in: ctx))
        }

        // MARK: - Helpers

        // myinvestor:v1:<day>:<ISIN>:<units>:<amount>#<n>. Identical orders are numbered
        // oldest first, so a later export that adds newer ones leaves the earlier keys alone.
        private static func keyed(_ trades: [Funds.Trade]) -> [(key: String, trade: Funds.Trade)] {
            var seen: [String: Int] = [:]
            return trades.map { t in
                let base = "myinvestor:v1:\(keyDay.string(from: t.date)):\(t.isin):\(t.units):\(t.amountEur)"
                seen[base, default: 0] += 1
                return ("\(base)#\(seen[base]!)", t)
            }
        }

        // From the store: after a rollback, account.fundTrades can still hold a trade that was
        // never saved.
        @MainActor
        private static func savedTrades(of account: Account, in ctx: ModelContext) throws -> [FundTrade] {
            let accountId = account.id
            return try ctx.fetch(FetchDescriptor<FundTrade>(predicate: #Predicate { $0.account?.id == accountId }))
        }

        // The order within a day isn't stored. Buys go first so a same-day sale never runs ahead
        // of the units it sells; FIFO takes the older lots first either way.
        private static func chronological(_ trades: [FundTrade]) -> [FundTrade] {
            trades.sorted {
                ($0.tradeDate, $0.side == .buy ? 0 : 1, $0.importKey ?? "", $0.id.uuidString)
                    < ($1.tradeDate, $1.side == .buy ? 0 : 1, $1.importKey ?? "", $1.id.uuidString)
            }
        }

        private static func trade(from model: FundTrade) -> Funds.Trade {
            Funds.Trade(isin: model.isin, date: model.tradeDate, side: model.side == .buy ? .buy : .sell,
                        units: model.units, amountEur: model.amountEur)
        }

        private static let keyDay = StatementCSV.formatter("yyyy-MM-dd", tz: "UTC")
    }
}

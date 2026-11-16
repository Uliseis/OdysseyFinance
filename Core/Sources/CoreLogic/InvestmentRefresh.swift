import Foundation
import SwiftData
import CoreModel
import CoreIntegrations

extension CoreLogic {
    // Pulls today's market value for every investment account that has a live source and
    // records it as that day's snapshot. Accounts without a source keep their typed snapshot;
    // contributions since it are added by Investments.computeAccountMetrics, so a stale
    // snapshot is only ever wrong by market movement, never by money paid in.
    public enum InvestmentRefresh {
        public struct Outcome: Equatable, Sendable {
            public var updated: [UUID] = []
            // Values that weren't saved, and why.
            public var failures: [String] = []
            // Worth knowing but nothing refused, like a value saved from a cached price.
            public var notices: [String] = []
        }

        public static let cryptoPrefix = "crypto:"
        public static let trading212Source = "t212"
        public static let fundsSource = "funds"

        // Below the free EODHD plan's 20 a day: this count is per device, the plan's is not.
        public static let fundRequestsPerDay = 15
        // NAVs arrive a day late, a few days over a holiday close; older, the fund isn't being priced.
        static let fundPriceMaxBusinessDays = 4
        // A day's NAV move stays well inside this; past it a wrong share class or a misplaced
        // decimal is likelier than the market.
        static let fundJumpLimit = Decimal(string: "0.15")!

        // A mistyped holding quantity produces a plausible-looking number that is wrong by
        // orders of magnitude (0,04512345 BTC read as 4512345 wrote a €257bn valuation).
        // Automatic writes are refused past this factor; typing a value by hand is not
        // guarded, because typing it IS the confirmation.
        public static let implausibleFactor: Decimal = 100

        public static func isImplausible(_ candidate: Decimal, previous: Decimal?) -> Bool {
            guard let previous, previous > 0, candidate > 0 else { return false }
            return candidate > previous * implausibleFactor
                || candidate * implausibleFactor < previous
        }

        public static func coinId(from source: String?) -> String? {
            guard let source, source.hasPrefix(cryptoPrefix) else { return nil }
            let id = String(source.dropFirst(cryptoPrefix.count))
            return id.isEmpty ? nil : id
        }

        @MainActor
        public static func liveValuedAccounts(in ctx: ModelContext) throws -> [Account] {
            try ctx.fetch(FetchDescriptor<Account>(
                predicate: #Predicate { $0.archived == false && $0.liveValueSource != nil }
            ))
        }

        @MainActor private static var current: Task<Outcome, Never>?

        // A call made while a run is going (the foreground sync and a pull to refresh) gets that
        // run's outcome: a second run would load the same fund price cache, fetch the same
        // prices again and lose count of the requests. The run is a task of its own, so a caller
        // that goes away (a pull to refresh whose screen closes) doesn't cut it short for the rest.
        @MainActor
        @discardableResult
        public static func run(
            in ctx: ModelContext,
            keychain: any MarketKeys = MarketKeychain(),
            crypto: any CryptoPriceSource = CryptoPriceClient(),
            fundPrices: @escaping (_ apiKey: String) -> any FundPriceSource = { EODHDClient(apiKey: $0) },
            fundPriceCache: any FundPriceCacheStore = FundPriceCacheFile(),
            now: Date = .now
        ) async -> Outcome {
            if let current { return await current.value }
            let task = Task {
                defer { current = nil }
                return await refreshAll(
                    in: ctx, keychain: keychain, crypto: crypto, fundPrices: fundPrices,
                    fundPriceCache: fundPriceCache, now: now)
            }
            current = task
            return await task.value
        }

        @MainActor
        private static func refreshAll(
            in ctx: ModelContext, keychain: any MarketKeys, crypto: any CryptoPriceSource,
            fundPrices: (_ apiKey: String) -> any FundPriceSource, fundPriceCache: any FundPriceCacheStore,
            now: Date
        ) async -> Outcome {
            var outcome = Outcome()
            guard let accounts = try? liveValuedAccounts(in: ctx), !accounts.isEmpty else {
                return outcome
            }

            // One request for every coin held, not one per account.
            let coinIds = Array(Set(accounts.compactMap { coinId(from: $0.liveValueSource) }))
            var prices: [String: Decimal] = [:]
            if !coinIds.isEmpty {
                do { prices = try await crypto.prices(for: coinIds) }
                catch { outcome.failures.append("Crypto prices: \(error)") }
            }

            var t212: Trading212Summary?
            if accounts.contains(where: { $0.liveValueSource == trading212Source }) {
                do {
                    let creds = try keychain.loadTrading212()
                    t212 = try await Trading212Client(credentials: creds).accountSummary()
                } catch {
                    outcome.failures.append("Trading 212: \(error)")
                }
            }

            var funds: [UUID: (market: Decimal, cash: Decimal)] = [:]
            let fundAccounts = accounts.filter { $0.liveValueSource == fundsSource }
            if !fundAccounts.isEmpty {
                funds = await fundValues(
                    fundAccounts, in: ctx, keychain: keychain, source: fundPrices,
                    cache: fundPriceCache, now: now, outcome: &outcome)
            }

            for account in accounts {
                guard let source = account.liveValueSource else { continue }
                var market: Decimal?
                var cash: Decimal?

                if source == trading212Source, let t212 {
                    market = t212.totalValueEur
                    cash = t212.cashEur
                } else if let coin = coinId(from: source), let price = prices[coin] {
                    guard let qty = account.assetQuantity else {
                        outcome.failures.append("\(account.displayName): no quantity set")
                        continue
                    }
                    market = qty * price
                } else if source == fundsSource, let value = funds[account.id] {
                    market = value.market
                    cash = value.cash
                }

                guard let market, market > 0 else { continue }

                // Compare against the newest reading that wasn't itself written today, so a
                // bad value recorded an hour ago can still be corrected by a good one.
                // UTC day, matching recordValuation's overwrite window — on a local calendar
                // the two disagree either side of midnight and the guard would compare
                // against the very row about to be replaced.
                var cal = Calendar(identifier: .iso8601)
                cal.timeZone = TimeZone(identifier: "UTC")!
                let today = cal.startOfDay(for: now)
                let previous = (try? Investments.listValuations(for: [account.id], in: ctx))?
                    .last(where: { $0.asOf < today })?
                    .marketValueEur
                if isImplausible(market, previous: previous) {
                    outcome.failures.append(
                        "\(account.displayName): \(Self.plain(market)) is far from the last "
                        + "reading (\(Self.plain(previous ?? 0))). Check the quantity; not saved.")
                    continue
                }

                do {
                    try Investments.recordValuation(
                        account: account, marketValueEur: market, cashValueEur: cash,
                        asOf: now, notes: "auto: \(source)", in: ctx, now: now)
                    outcome.updated.append(account.id)
                } catch {
                    outcome.failures.append("\(account.displayName): \(error)")
                }
            }
            return outcome
        }

        // MARK: - Funds

        // Each funds account's value (held units at cached prices, plus broker cash) and its
        // cash, refreshing the prices first. A fund that can't be priced refuses its account
        // whole: a total without it would read as a loss that never happened.
        @MainActor
        private static func fundValues(
            _ accounts: [Account], in ctx: ModelContext, keychain: any MarketKeys,
            source makeSource: (String) -> any FundPriceSource, cache store: any FundPriceCacheStore,
            now: Date, outcome: inout Outcome
        ) async -> [UUID: (market: Decimal, cash: Decimal)] {
            let apiKey: String
            do {
                apiKey = try keychain.loadEODHD()
            } catch {
                // A locked device fails the read too; asking for the key again wouldn't help.
                let why = error as? MarketKeyError == .notFound
                    ? "add the EODHD key in Settings" : "the EODHD key couldn't be read (\(error))"
                for account in accounts { outcome.failures.append("\(account.displayName): \(why); not saved.") }
                return [:]
            }
            var ready: [(account: Account, held: [Funds.Position], cash: Decimal)] = []
            for account in accounts {
                do {
                    guard let ledger = try FundTrades.cashLedger(for: account, in: ctx) else {
                        outcome.failures.append("\(account.displayName): set the cash at the broker first; not saved.")
                        continue
                    }
                    let held = Funds.positions(try FundTrades.trades(for: account, in: ctx)).filter { $0.units > 0 }
                    ready.append((account, held, ledger.currentEur))
                } catch {
                    outcome.failures.append("\(account.displayName): \(error)")
                }
            }

            let today = Funds.dayStart(now)
            let refresh = await refreshPrices(
                Set(ready.flatMap { $0.held.map(\.isin) }).sorted(),
                store: store, source: makeSource(apiKey), today: today)
            let cache = refresh.cache
            if refresh.keyRejected { outcome.failures.append("EODHD rejected the key; check it in Settings.") }
            if let why = refresh.saveFailure { outcome.notices.append("Fund prices weren't cached: \(why)") }

            var values: [UUID: (market: Decimal, cash: Decimal)] = [:]
            var notices: Set<String> = []
            for (account, held, cash) in ready {
                var market = cash
                var problems: [String] = []
                for position in held {
                    let entry = cache.funds[position.isin]
                    let label = entry?.name ?? position.isin
                    let why = refresh.notRefreshed[position.isin].map { " (\($0))" } ?? ""
                    if let entry, entry.currency != "EUR" {
                        problems.append("\(label): priced in \(entry.currency), not EUR")
                    } else if let entry, let pending = entry.pendingPrice, let pendingDay = entry.pendingDay {
                        let from = pendingDay == entry.priceDay ? entry.previousPrice : entry.price
                        problems.append("\(label): new price awaiting confirmation (\(pending) for \(isoDay(pendingDay)) "
                            + "is more than \(fundJumpLimit * 100)% from \(from.map { "\($0)" } ?? "the one before"); "
                            + "a later day's price confirms or replaces it)")
                    } else if let price = entry?.price, let priceDay = entry?.priceDay {
                        if businessDays(after: priceDay, through: today) > fundPriceMaxBusinessDays {
                            problems.append("\(label): its latest price is from \(isoDay(priceDay)), "
                                + "more than \(fundPriceMaxBusinessDays) business days ago\(why)")
                        } else {
                            market += position.units * price
                            if !why.isEmpty {
                                notices.insert("\(label): not refreshed\(why); valued at its price of \(isoDay(priceDay)).")
                            }
                        }
                    } else {
                        problems.append("\(label): no price yet\(why)")
                    }
                }
                if problems.isEmpty {
                    values[account.id] = (market, cash)
                } else {
                    outcome.failures.append("\(account.displayName): \(problems.joined(separator: "; ")); not saved.")
                }
            }
            outcome.notices += notices.sorted()
            return values
        }

        private struct PriceRefresh {
            var cache: FundPriceCache
            // By ISIN: why a fund's cached price, if it has one, wasn't refreshed.
            var notRefreshed: [String: String] = [:]
            var keyRejected = false
            var saveFailure: String?
        }

        // A name and currency once per fund, a price at most once per fund per UTC day, and no
        // request past the daily cap. Saved after every request, so a process killed mid-run
        // still counts what it sent.
        @MainActor
        private static func refreshPrices(
            _ isins: [String], store: any FundPriceCacheStore, source: any FundPriceSource, today: Date
        ) async -> PriceRefresh {
            let loaded = store.load()
            var result = PriceRefresh(cache: loaded ?? FundPriceCache())
            func save() {
                do { try store.save(result.cache) } catch { result.saveFailure = "\(error)" }
            }
            if loaded == nil {
                // An unreadable cache can't say how many requests today already made: assume all
                // of them. Nothing is sent, so the file isn't written over and keeps its prices and
                // held jumps for when it can be read again.
                result.cache.requestDay = today
                result.cache.requestCount = fundRequestsPerDay
            }
            if result.cache.requestDay != today {
                result.cache.requestDay = today
                result.cache.requestCount = 0
                result.cache.failedLookups = [:]
            }
            let capReached = "no EODHD requests left today"
            let notListed = "EODHD doesn't list this ISIN as a fund"
            // A rejected key fails every request the same way, so it ends the run's requests.
            func keepFetching(after error: any Error, isin: String, notFound: String) -> Bool {
                switch error as? FundPriceError {
                case .unauthorized:
                    result.keyRejected = true
                    return false
                case .rateLimited:
                    result.cache.requestCount = fundRequestsPerDay
                default:
                    break
                }
                result.notRefreshed[isin] = describe(error, notFound: notFound)
                return true
            }
            for isin in isins {
                if result.cache.funds[isin] == nil {
                    if result.cache.failedLookups[isin] == today {
                        result.notRefreshed[isin] = notListed
                        continue
                    }
                    guard result.cache.requestCount < fundRequestsPerDay else {
                        result.notRefreshed[isin] = capReached
                        continue
                    }
                    result.cache.requestCount += 1
                    defer { save() }
                    do {
                        let info = try await source.lookup(isin: isin)
                        result.cache.funds[isin] = FundPriceCache.Entry(name: info.name, currency: info.currency)
                    } catch {
                        if isCancellation(error) {
                            result.cache.requestCount -= 1
                            break
                        }
                        if error as? FundPriceError == .notFound { result.cache.failedLookups[isin] = today }
                        if keepFetching(after: error, isin: isin, notFound: notListed) { continue } else { break }
                    }
                }
                guard var entry = result.cache.funds[isin], entry.currency == "EUR", entry.fetchedDay != today else {
                    continue
                }
                guard result.cache.requestCount < fundRequestsPerDay else {
                    result.notRefreshed[isin] = capReached
                    continue
                }
                result.cache.requestCount += 1
                defer { save() }
                do {
                    let quote = try await source.latest(isin: isin, currency: entry.currency)
                    entry.fetchedDay = today
                    accept(quote, into: &entry)
                    result.cache.funds[isin] = entry
                } catch {
                    if isCancellation(error) {
                        result.cache.requestCount -= 1
                        break
                    }
                    if error as? FundPriceError == .notFound {
                        entry.fetchedDay = today
                        result.cache.funds[isin] = entry
                    }
                    if !keepFetching(after: error, isin: isin, notFound: "EODHD has no recent price for it") { break }
                }
            }
            return result
        }

        // Takes the quote into the entry, or holds it as pending when it jumps. A quote older
        // than the cached or pending price is ignored. The jump is measured against a price of
        // an earlier day, so a NAV re-published for the cached day is checked against the day
        // before it.
        private static func accept(_ quote: FundQuote, into entry: inout FundPriceCache.Entry) {
            if let newest = [entry.priceDay, entry.pendingDay].compactMap({ $0 }).max(), quote.day < newest { return }
            // A cached price too old to value with says nothing about how far the market has
            // moved since, so it's no reference.
            let stale = entry.priceDay.map {
                businessDays(after: $0, through: quote.day) > fundPriceMaxBusinessDays
            } == true
            var previous = entry.priceDay == quote.day ? entry.previousPrice : stale ? nil : entry.price
            if let reference = previous, isJump(quote.price, from: reference) {
                // Two different days agreeing on the new level is a real move, not a bad print.
                guard let pending = entry.pendingPrice, let pendingDay = entry.pendingDay,
                      quote.day > pendingDay, !isJump(quote.price, from: pending) else {
                    entry.pendingPrice = quote.price
                    entry.pendingDay = quote.day
                    return
                }
                previous = pending
            }
            entry.previousPrice = previous
            entry.price = quote.price
            entry.priceDay = quote.day
            entry.pendingPrice = nil
            entry.pendingDay = nil
        }

        private static func isJump(_ price: Decimal, from reference: Decimal) -> Bool {
            reference > 0 && abs(price - reference) / reference > fundJumpLimit
        }

        // A request cut short by a cancelled task isn't counted against the day's cap.
        private static func isCancellation(_ error: any Error) -> Bool {
            error is CancellationError || (error as? URLError)?.code == .cancelled
        }

        // Monday to Friday, UTC, after `day` up to and including `end`'s day.
        static func businessDays(after day: Date, through end: Date) -> Int {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let last = cal.startOfDay(for: end)
            var current = cal.startOfDay(for: day)
            var count = 0
            while current < last {
                current = cal.date(byAdding: .day, value: 1, to: current)!
                // Gregorian weekdays: 1 is Sunday, 7 Saturday.
                let weekday = cal.component(.weekday, from: current)
                if weekday != 1 && weekday != 7 { count += 1 }
            }
            return count
        }

        // The client's errors without the request: its URL carries the key.
        private static func describe(_ error: Error, notFound: String) -> String {
            switch error as? FundPriceError {
            case .notFound: notFound
            case .unauthorized: "EODHD rejected the key"
            case .rateLimited: "EODHD's daily limit is reached"
            case .badResponse(let status, _): "EODHD answered \(status)"
            case .parse: "EODHD's answer couldn't be read"
            case nil: error.localizedDescription
            }
        }

        private static func isoDay(_ day: Date) -> String {
            day.formatted(.iso8601.year().month().day())
        }

        // No currency formatter in Core; the message only needs to be readable.
        private static func plain(_ value: Decimal) -> String {
            var rounded = Decimal()
            var input = value
            NSDecimalRound(&rounded, &input, 2, .plain)
            return "\(rounded) EUR"
        }
    }
}

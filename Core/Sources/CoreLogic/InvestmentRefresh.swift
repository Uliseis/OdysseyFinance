import Foundation
import Security
import SwiftData
import CoreModel
import CoreIntegrations

extension CoreLogic {
    // Pulls today's market value for every investment account that has a live source and
    // records it as that day's snapshot; fund prices arrive a day or two late, so they value
    // each weekday up to their own date instead. Accounts without a source keep their typed
    // snapshot; contributions since it are added by Investments.computeAccountMetrics, so a
    // stale snapshot is only ever wrong by market movement, never by money paid in.
    public enum InvestmentRefresh {
        public struct Outcome: Equatable, Sendable {
            public var updated: [UUID] = []
            // Values that weren't saved, and why.
            public var failures: [String] = []
            // Worth knowing but nothing refused, like a value saved from a cached price.
            public var notices: [String] = []
            // Accounts with a live source; none means there was nothing to refresh.
            public var liveAccounts = 0
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
        // Weekdays valued in one refresh; a longer gap since the last value keeps the latest ones.
        static let fundGapDays = 60
        // Daily prices older than this leave the cache, however far back a request reached.
        static let fundHistoryDays = 400

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

        // For a background task about to expire: the run is a task of its own, so cancelling
        // its caller leaves it going, and iOS suspends the app as soon as the task ends.
        @MainActor
        public static func cancel() {
            current?.cancel()
        }

        // When the background refresh may next start: the first 6:00 local at least six hours
        // away. A fund's price changes once a day and iOS starts the task later than asked
        // anyway, so a run each morning is enough, and never one straight after another.
        public static func nextBackgroundRun(after now: Date, timeZone: TimeZone = .current) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let earliest = now.addingTimeInterval(6 * 3600)
            var run = cal.date(bySettingHour: 6, minute: 0, second: 0, of: now) ?? earliest
            while run < earliest {
                guard let next = cal.date(byAdding: .day, value: 1, to: run) else { return earliest }
                run = next
            }
            return run
        }

        // nil keeps the run already booked: booking again from a launch between midnight and
        // 6:00 would push that morning's run to the next day.
        public static func backgroundRunToBook(
            after now: Date, alreadyBooked: Bool, timeZone: TimeZone = .current
        ) -> Date? {
            alreadyBooked ? nil : nextBackgroundRun(after: now, timeZone: timeZone)
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
            outcome.liveAccounts = accounts.count

            // One request for every coin held, not one per account.
            let coinIds = Array(Set(accounts.compactMap { coinId(from: $0.liveValueSource) }))
            var prices: [String: Decimal] = [:]
            if !coinIds.isEmpty {
                do { prices = try await crypto.prices(for: coinIds) }
                catch { outcome.failures.append("Crypto prices: \(requestProblem(error))") }
            }

            var t212: Trading212Summary?
            if accounts.contains(where: { $0.liveValueSource == trading212Source }) {
                do {
                    let creds = try keychain.loadTrading212()
                    t212 = try await Trading212Client(credentials: creds).accountSummary()
                } catch let error as MarketKeyError {
                    outcome.failures.append("Trading 212: \(keyProblem(error, named: "API key"))")
                } catch {
                    outcome.failures.append("Trading 212: \(requestProblem(error))")
                }
            }

            let fundAccounts = accounts.filter { $0.liveValueSource == fundsSource }
            if !fundAccounts.isEmpty {
                await refreshFunds(
                    fundAccounts, in: ctx, keychain: keychain, source: fundPrices,
                    cache: fundPriceCache, now: now, outcome: &outcome)
            }

            for account in accounts where account.liveValueSource != fundsSource {
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

        private struct FundAccount {
            let account: Account
            let trades: [Funds.Trade]
            let ledger: Funds.CashLedger
            let legs: [Investments.ContributionLeg]
            let valuations: [PortfolioValuation]
            let held: [String]
            // Held now or traded since the last value, so held on some day still to be valued.
            let priced: Set<String>

            var lastDay: Date? { valuations.last.map { Funds.dayStart($0.asOf) } }
        }

        // Every funds account is valued, after refreshing the prices, on each weekday since its
        // last valuation up to its newest fund price, dated by the prices rather than the refresh.
        @MainActor
        private static func refreshFunds(
            _ accounts: [Account], in ctx: ModelContext, keychain: any MarketKeys,
            source makeSource: (String) -> any FundPriceSource, cache store: any FundPriceCacheStore,
            now: Date, outcome: inout Outcome
        ) async {
            let apiKey: String
            do {
                apiKey = try keychain.loadEODHD()
            } catch {
                let why = keyProblem(error, named: "EODHD key")
                for account in accounts { outcome.failures.append("\(account.displayName): \(why); not saved.") }
                return
            }
            var ready: [FundAccount] = []
            for account in accounts {
                do {
                    guard let ledger = try FundTrades.cashLedger(for: account, in: ctx) else {
                        outcome.failures.append("\(account.displayName): set the cash at the broker first; not saved.")
                        continue
                    }
                    let trades = try FundTrades.trades(for: account, in: ctx)
                    let valuations = try Investments.listValuations(for: [account.id], in: ctx)
                    let lastDay = valuations.last.map { Funds.dayStart($0.asOf) }
                    let held = Funds.positions(trades).filter { $0.units > 0 }.map(\.isin)
                    let traded = trades.filter { t in lastDay.map { Funds.dayStart(t.date) > $0 } ?? false }.map(\.isin)
                    ready.append(FundAccount(
                        account: account, trades: trades, ledger: ledger,
                        legs: try Investments.listContributionLegs(for: [account.id], in: ctx),
                        valuations: valuations, held: held, priced: Set(held + traded)))
                } catch {
                    outcome.failures.append("\(account.displayName): \(error)")
                }
            }

            let today = Funds.dayStart(now)
            // By ISIN: a week before the oldest last value among the accounts that need its prices.
            var since: [String: Date] = [:]
            for fund in ready {
                guard let lastDay = fund.lastDay else { continue }
                let from = lastDay.addingTimeInterval(-7 * 86_400)
                for isin in fund.priced { since[isin] = min(since[isin] ?? from, from) }
            }
            let refresh = await refreshPrices(
                ready.reduce(into: Set<String>()) { $0.formUnion($1.priced) }.sorted(), since: since,
                store: store, source: makeSource(apiKey), today: today)
            if refresh.keyRejected { outcome.failures.append("EODHD rejected the key; check it in Settings.") }
            if let then = refresh.unreadableCache {
                outcome.notices.append("The fund price cache couldn't be read; \(then).")
            }
            if let why = refresh.saveFailure { outcome.notices.append("Fund prices weren't cached: \(why)") }

            var fundNotices: Set<String> = []
            var accountNotices: [String] = []
            for fund in ready {
                accountNotices += recordValues(
                    of: fund, refresh: refresh, today: today, in: ctx, now: now,
                    fundNotices: &fundNotices, outcome: &outcome)
            }
            outcome.notices += fundNotices.sorted() + accountNotices
        }

        // A held fund that can't be priced refuses the account; a day one held fund has no price
        // for is left out. A total without it would read as a loss that never happened. Returns
        // the account's notices.
        @MainActor
        private static func recordValues(
            of fund: FundAccount, refresh: PriceRefresh, today: Date, in ctx: ModelContext, now: Date,
            fundNotices: inout Set<String>, outcome: inout Outcome
        ) -> [String] {
            let name = fund.account.displayName
            let cache = refresh.cache
            var problems: [String] = []
            var awaiting: [String] = []
            var newest: [Date] = []
            // A held jump stops the values at the fund's last accepted day.
            var until: Date?
            for isin in fund.held {
                let entry = cache.funds[isin]
                let label = entry?.name ?? isin
                let why = refresh.notRefreshed[isin].map { " (\($0))" } ?? ""
                if let entry, entry.currency != "EUR" {
                    problems.append("\(label): priced in \(entry.currency), not EUR")
                } else if let price = entry?.price, let priceDay = entry?.priceDay {
                    if businessDays(after: priceDay, through: today) > fundPriceMaxBusinessDays {
                        problems.append("\(label): its latest price is from \(isoDay(priceDay)), "
                            + "more than \(fundPriceMaxBusinessDays) business days ago\(why)")
                    } else if let pending = entry?.pendingPrice, let pendingDay = entry?.pendingDay {
                        let from = pendingDay == priceDay ? entry?.previousPrice : price
                        awaiting.append("\(label): new price awaiting confirmation (\(pending) for \(isoDay(pendingDay)) "
                            + "is more than \(fundJumpLimit * 100)% from \(from.map { "\($0)" } ?? "the one before"); "
                            + "a later day's price confirms or replaces it)")
                        newest.append(priceDay)
                        until = min(until ?? priceDay, priceDay)
                    } else {
                        newest.append(priceDay)
                        if !why.isEmpty {
                            fundNotices.insert("\(label): not refreshed\(why); valued at its price of \(isoDay(priceDay)).")
                        }
                    }
                } else {
                    problems.append("\(label): no price yet\(why)")
                }
            }
            guard problems.isEmpty else {
                outcome.failures.append("\(name): \(problems.joined(separator: "; ")); not saved.")
                return []
            }

            // Every weekday after the last value up to the newest price, then that day itself: an
            // automatic value already on it is replaced when it differs. Without funds held, cash
            // is known today.
            let through = min(newest.max() ?? today, until ?? .distantFuture)
            if !awaiting.isEmpty {
                outcome.failures.append("\(name): \(awaiting.joined(separator: "; ")); no value after \(Funds.dayRange(through...through)).")
            }
            let lastDay = fund.lastDay
            if let lastDay, through < lastDay {
                return ["\(name): no new prices since \(Funds.dayRange(lastDay...lastDay))."]
            }
            var days = lastDay.map { $0 == through ? [] : weekdays(after: $0, before: through) } ?? []
            days.append(through)
            let capped = days.count > fundGapDays
            days = Array(days.suffix(fundGapDays))

            let prices = cache.funds.compactMapValues { $0.currency == "EUR" ? $0.dailyPrices : nil }
            var previous = fund.valuations.last { Funds.dayStart($0.asOf) < days[0] }?.marketValueEur
            let note = "auto: \(fundsSource)"
            var recorded: [Date] = []
            var unpriced: [Date] = []
            var missing: Set<String> = []
            var refused = false
            var kept: Date?
            for day in days {
                let value = Funds.value(on: day, trades: fund.trades, prices: prices, cash: fund.ledger)
                guard let total = value.valueEur else {
                    unpriced.append(day)
                    missing.formUnion(value.missingISINs)
                    continue
                }
                let market = Funds.cents(total)
                let cash = Funds.cents(fund.ledger.cash(on: day))
                guard market > 0 else { continue }
                // The value includes the transfers booked on its day, so it's dated late enough
                // that Investments doesn't add a timed one on top again.
                let asOf = fund.legs.map(\.bookedAt).filter { Funds.dayStart($0) == day }.max() ?? day
                if let existing = fund.valuations.last, Funds.dayStart(existing.asOf) == day {
                    // Typed in or sent by Claude: someone meant that figure for that day.
                    guard existing.notes?.hasPrefix(note) == true else {
                        kept = day
                        continue
                    }
                    if existing.marketValueEur == market, existing.cashValueEur == cash, existing.asOf == asOf {
                        continue
                    }
                }
                if isImplausible(market, previous: previous) {
                    outcome.failures.append(
                        "\(name): \(Self.plain(market)) is far from the last "
                        + "reading (\(Self.plain(previous ?? 0))). Check the quantity; not saved.")
                    refused = true
                    break
                }
                do {
                    try Investments.recordValuation(
                        account: fund.account, marketValueEur: market, cashValueEur: cash,
                        asOf: asOf, notes: note, in: ctx, now: now)
                    recorded.append(day)
                    previous = market
                } catch {
                    outcome.failures.append("\(name): \(error)")
                    refused = true
                    break
                }
            }

            var notices: [String] = []
            if let first = recorded.first, let last = recorded.last {
                outcome.updated.append(fund.account.id)
                notices.append("\(name): values recorded for \(count(recorded.count, "day")) "
                    + "(\(Funds.dayRange(first...last))).")
            }
            if capped, let lastDay {
                notices.append("\(name): the gap since \(Funds.dayRange(lastDay...lastDay)) is longer than "
                    + "\(fundGapDays) weekdays; only the latest \(fundGapDays) were filled.")
            }
            if let first = unpriced.first, let last = unpriced.last {
                let labels = missing.sorted().map { cache.funds[$0]?.name ?? $0 }
                outcome.failures.append("\(name): \(count(unpriced.count, "day")) not valued "
                    + "(\(Funds.dayRange(first...last))): no price in the week before for \(labels.joined(separator: ", ")).")
            }
            if let kept {
                notices.append("\(name): kept the value entered on \(Funds.dayRange(kept...kept)).")
            } else if recorded.isEmpty, unpriced.isEmpty, !refused, let lastDay {
                notices.append("\(name): no new prices since \(Funds.dayRange(lastDay...lastDay)).")
            }
            return notices
        }

        private struct PriceRefresh {
            var cache: FundPriceCache
            // By ISIN: why a fund's cached price, if it has one, wasn't refreshed.
            var notRefreshed: [String: String] = [:]
            var keyRejected = false
            var saveFailure: String?
            // What a cache that couldn't be read means for this run.
            var unreadableCache: String?
        }

        // A name and currency once per fund, a price at most once per fund per UTC day, and no
        // request past the daily cap. Saved with the count before every request, so a process
        // killed mid-request still counts it, and again after with its answer.
        @MainActor
        private static func refreshPrices(
            _ isins: [String], since: [String: Date], store: any FundPriceCacheStore,
            source: any FundPriceSource, today: Date
        ) async -> PriceRefresh {
            let loaded = store.load()
            var result = PriceRefresh(cache: loaded ?? FundPriceCache())
            func save() {
                do { try store.save(result.cache) } catch { result.saveFailure = "\(error)" }
            }
            if loaded == nil {
                // Counts are saved before each request, so a cache last written before today
                // counted none of today's: start again, and the first request writes over it.
                // Written today, or at an unknown time, it can't say how many today made: assume
                // all of them and send nothing, so a cache that can be read again keeps its prices
                // and held jumps.
                if let modified = store.modificationDate(), Funds.dayStart(modified) < today {
                    result.unreadableCache = "it starts again from the prices fetched now"
                } else {
                    result.cache.requestDay = today
                    result.cache.requestCount = fundRequestsPerDay
                    result.unreadableCache = "no fund prices are fetched today"
                }
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
                    save()
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
                save()
                defer { save() }
                do {
                    let quotes = try await source.recent(isin: isin, currency: entry.currency, since: since[isin])
                    entry.fetchedDay = today
                    accept(quotes, into: &entry)
                    backfill(quotes, into: &entry)
                    let kept = dailyPricesKept(since: since[isin], today: today)
                    entry.history.removeAll { $0.date < kept }
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

        // Takes a fetched series into the entry. The days after the newest accepted price are
        // accepted in order up to the first that jumps from the one before; the newest day then
        // goes through the pending check against the last accepted price, held when it jumps.
        // A series no newer than the cached or pending price is ignored, and days already
        // accepted aren't checked again. A jump is measured against a price of an earlier day,
        // so a NAV re-published for the cached day is checked against the day before it.
        private static func accept(_ series: [FundQuote], into entry: inout FundPriceCache.Entry) {
            guard let newest = series.last else { return }
            if let latest = [entry.priceDay, entry.pendingDay].compactMap({ $0 }).max(), newest.day < latest { return }
            var last = entry.priceDay.flatMap { day in entry.price.map { Funds.PricePoint(date: day, priceEur: $0) } }
            var previous = entry.previousPrice
            var accepted: [Funds.PricePoint] = []
            var held: [Funds.PricePoint] = []
            for quote in series.dropLast() where entry.priceDay.map({ quote.day > $0 }) ?? true {
                let point = Funds.PricePoint(date: quote.day, priceEur: quote.price)
                let reference = usable(last, on: point.date)
                if held.isEmpty, reference.map({ !isJump(point.priceEur, from: $0) }) ?? true {
                    previous = reference
                    last = point
                    accepted.append(point)
                } else {
                    held.append(point)
                }
            }
            var reference = newest.day == entry.priceDay ? entry.previousPrice : usable(last, on: newest.day)
            if let jumpedFrom = reference, isJump(newest.price, from: jumpedFrom) {
                // Two different days agreeing on the new level is a real move, not a bad print.
                guard let pending = entry.pendingPrice, let pendingDay = entry.pendingDay,
                      newest.day > pendingDay, !isJump(newest.price, from: pending) else {
                    take(accepted, previous: previous, into: &entry)
                    entry.pendingPrice = newest.price
                    entry.pendingDay = newest.day
                    return
                }
                // So are the days leading up to it that agree with each other.
                var leading = held
                if pendingDay > (last?.date ?? .distantPast), !held.contains(where: { $0.date == pendingDay }) {
                    leading.append(Funds.PricePoint(date: pendingDay, priceEur: pending))
                    leading.sort { $0.date < $1.date }
                }
                var confirmed: [Funds.PricePoint] = []
                for point in leading.reversed() {
                    guard !isJump(confirmed.first?.priceEur ?? newest.price, from: point.priceEur) else { break }
                    confirmed.insert(point, at: 0)
                }
                accepted += confirmed
                reference = confirmed.last?.priceEur ?? pending
            }
            take(accepted + [Funds.PricePoint(date: newest.day, priceEur: newest.price)], previous: reference, into: &entry)
            entry.pendingPrice = nil
            entry.pendingDay = nil
        }

        // The points become the entry's newest daily prices, the last of them its price.
        private static func take(_ points: [Funds.PricePoint], previous: Decimal?, into entry: inout FundPriceCache.Entry) {
            guard let top = points.last else { return }
            let days = Set(points.map(\.date))
            entry.history = entry.dailyPrices.filter { !days.contains($0.date) } + points
            entry.price = top.priceEur
            entry.priceDay = top.date
            entry.previousPrice = previous
        }

        // Days before the newest accepted price that the cache doesn't have yet, brought by a
        // request reaching back for an older gap, join the daily prices; the price itself stays.
        // A day that moves more than the limit from every day beside it is a misprint and is
        // left out.
        private static func backfill(_ series: [FundQuote], into entry: inout FundPriceCache.Entry) {
            guard let priceDay = entry.priceDay else { return }
            let known = entry.dailyPrices
            let knownDays = Set(known.map(\.date))
            let older = series.filter { $0.day < priceDay && !knownDays.contains($0.day) }
            guard !older.isEmpty else { return }
            let all = (known + older.map { Funds.PricePoint(date: $0.day, priceEur: $0.price) }).sorted { $0.date < $1.date }
            entry.history = all.indices.filter { i in
                guard !knownDays.contains(all[i].date) else { return true }
                let beside = [i - 1, i + 1].filter(all.indices.contains).map { all[$0].priceEur }
                return !beside.allSatisfy { isJump(all[i].priceEur, from: $0) }
            }.map { all[$0] }
        }

        // A price too old to value with says nothing about how far the market has moved since,
        // so it's no reference.
        private static func usable(_ point: Funds.PricePoint?, on day: Date) -> Decimal? {
            guard let point, businessDays(after: point.date, through: day) <= fundPriceMaxBusinessDays else { return nil }
            return point.priceEur
        }

        private static func isJump(_ price: Decimal, from reference: Decimal) -> Bool {
            reference > 0 && abs(price - reference) / reference > fundJumpLimit
        }

        // From two weeks back, the price source's own window, or from where the request reached
        // when that's earlier, but never more than fundHistoryDays.
        static func dailyPricesKept(since: Date?, today: Date) -> Date {
            let window = today.addingTimeInterval(-14 * 86_400)
            return max(min(since ?? window, window), today.addingTimeInterval(-Double(fundHistoryDays) * 86_400))
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

        // Monday to Friday, UTC, after `day` and before `end`'s day.
        private static func weekdays(after day: Date, before end: Date) -> [Date] {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let last = cal.startOfDay(for: end)
            var current = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day))!
            var days: [Date] = []
            while current < last {
                if !cal.isDateInWeekend(current) { days.append(current) }
                current = cal.date(byAdding: .day, value: 1, to: current)!
            }
            return days
        }

        private static func count(_ n: Int, _ noun: String) -> String {
            "\(n) \(noun)\(n == 1 ? "" : "s")"
        }

        // The keys can't be read until the phone is unlocked once after boot, which a background
        // run may hit: asking for the key again wouldn't help then.
        private static func keyProblem(_ error: any Error, named key: String) -> String {
            switch error as? MarketKeyError {
            case .notFound: "add the \(key) in Settings"
            case .keychain(errSecInteractionNotAllowed): "the \(key) can't be read until the iPhone is unlocked after a restart"
            default: "the \(key) couldn't be read (\(error))"
            }
        }

        // Trading 212's and CoinGecko's errors in a few words, without the answer's body.
        private static func requestProblem(_ error: any Error) -> String {
            if let t212 = error as? Trading212Error, t212.status == 401 || t212.status == 403 {
                return "the API key was rejected; check it in Settings"
            }
            switch (error as? Trading212Error)?.status ?? (error as? CryptoPriceError)?.status {
            case .some(429): return "rate limited, try again later"
            case .some(let status): return "the server answered \(status)"
            case nil: return (error as? URLError)?.localizedDescription ?? "\(error)"
            }
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

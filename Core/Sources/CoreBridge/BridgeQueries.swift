import Foundation
import SwiftData
import CoreModel
import CoreLogic

// What Claude reads. Every figure comes from the same CoreLogic the app runs, over the replica.
public enum BridgeQueries {
    public struct Overview: Codable, Sendable {
        public var exportedAt: Date
        public var snapshotAgeMinutes: Int
        public var space: String
        public var spaces: [Space]
        public var netWorth: Decimal
        public var cash: Decimal
        public var liabilities: Decimal
        public var investments: Decimal
        public var groups: [Group]
        public var currentPeriod: Month?
        public var uncategorizedCount: Int
        public var accounts: [AccountLine]
        public var connections: [ConnectionLine]
    }

    public struct Space: Codable, Sendable { public var id: UUID; public var name: String; public var isDefault: Bool }
    public struct Group: Codable, Sendable { public var name: String; public var kind: String?; public var eur: Decimal; public var accounts: Int }

    public struct AccountLine: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var institution: String
        public var group: String?
        public var groupKind: String?
        public var space: String?
        public var currency: String
        public var balanceEur: Decimal?
        public var balanceNative: Decimal?
        // valuation | anchor | opening | bank: which rule produced the balance.
        public var balanceSource: String
        public var anchorAt: Date?
        public var connected: Bool
        public var archived: Bool
        public var excluded: Bool
        public var pendingApproval: Bool
        public var feedSince: Date?
        public var lastTransactionAt: Date?
        public var uncategorized: Int
    }

    public struct ConnectionLine: Codable, Sendable {
        public var id: UUID
        public var institution: String?
        public var connector: String
        public var status: String
        public var expiresAt: Date?
        public var daysUntilExpiry: Int?
        public var lastSyncAt: Date?
        public var lastError: String?
        public var accounts: Int
    }

    public struct Month: Codable, Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var income: Decimal
        public var expense: Decimal
        public var net: Decimal
    }

    public struct CategoryTotal: Codable, Sendable, Equatable {
        public var category: String
        public var total: Decimal
    }

    public struct TransactionQuery: Codable, Sendable {
        public var accountIds: [UUID]?
        public var from: Date?
        public var to: Date?
        public var category: String?
        public var uncategorized: Bool?
        // Case-insensitive, over description, counterparty, the bank's creditor/debtor and externalId.
        public var text: String?
        // On the absolute EUR amount.
        public var minAmount: Decimal?
        public var maxAmount: Decimal?
        public var direction: TxDirection?
        // nil: any; true: only transfer legs; false: no transfer legs.
        public var transfers: Bool?
        public var includeExcludedAccounts: Bool?
        public var limit: Int?
        public var offset: Int?

        public init(
            accountIds: [UUID]? = nil, from: Date? = nil, to: Date? = nil, category: String? = nil,
            uncategorized: Bool? = nil, text: String? = nil, minAmount: Decimal? = nil, maxAmount: Decimal? = nil,
            direction: TxDirection? = nil, transfers: Bool? = nil, includeExcludedAccounts: Bool? = nil,
            limit: Int? = nil, offset: Int? = nil
        ) {
            self.accountIds = accountIds; self.from = from; self.to = to; self.category = category
            self.uncategorized = uncategorized; self.text = text; self.minAmount = minAmount
            self.maxAmount = maxAmount; self.direction = direction; self.transfers = transfers
            self.includeExcludedAccounts = includeExcludedAccounts; self.limit = limit; self.offset = offset
        }
    }

    public struct TransactionPage: Codable, Sendable {
        public var total: Int
        public var rows: [TxLine]
    }

    public struct TxLine: Codable, Sendable {
        public var id: UUID
        public var externalId: String
        public var accountId: UUID?
        public var account: String?
        public var bookedAt: Date
        public var valueAt: Date?
        public var amount: Decimal
        public var currency: String
        public var amountEur: Decimal?
        public var direction: TxDirection
        public var description: String?
        public var counterparty: String?
        public var category: String?
        public var categorySource: CategorySource
        public var isTransfer: Bool
        public var transferGroupId: UUID?
        public var pairedTxId: UUID?
        public var routedFromTxId: UUID?
        public var mirrorTxIds: [UUID]?
        public var routeId: UUID?
        public var sharedGroupId: UUID?
        public var bankCode: String?
        public var creditor: String?
        public var debtor: String?
    }

    public struct RuleLine: Codable, Sendable {
        public var order: Int
        public var id: UUID
        public var pattern: String
        public var field: RuleField
        public var matchType: RuleMatch
        public var category: String?
        public var priority: Int
    }

    public struct RouteLine: Codable, Sendable {
        public var id: UUID
        public var pattern: String
        public var field: RuleField
        public var matchType: RuleMatch
        public var source: String?
        public var target: String?
        public var direction: TxDirection?
        public var priority: Int
        public var enabled: Bool
        // Editing or disabling the route deletes every one of these.
        public var mirrorCount: Int
    }

    public struct CategoryLine: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var kind: String
        public var parent: String?
        public var transactions: Int
    }

    public struct TransferCandidate: Codable, Sendable {
        public var debit: TxLine
        public var credit: TxLine
        public var daysApart: Int
        // What Transfers.detect would accept: at most 3 days apart.
        public var withinDetectWindow: Bool
    }

    public struct SyncStatus: Codable, Sendable {
        public var connections: [ConnectionLine]
        public var runs: [Run]
        public struct Run: Codable, Sendable {
            public var institution: String?
            public var startedAt: Date
            public var finishedAt: Date?
            public var status: String
            public var inserted: Int
            public var error: String?
        }
    }

    public static let detectWindowDays = 3
}

@MainActor
extension BridgeReplica {
    private var ctx: ModelContext { context }

    // The phone's selected space unless told otherwise; the default space catches the rest.
    public func resolveSpace(_ requested: UUID?) throws -> (current: AccountSpace, defaultId: UUID)? {
        let spaces = try ctx.fetch(FetchDescriptor<AccountSpace>(sortBy: [SortDescriptor(\.sortOrder)]))
        guard let def = spaces.first(where: \.isDefault) ?? spaces.first else { return nil }
        let wanted = requested ?? snapshot.appState.currentSpaceId
        return (spaces.first { $0.id == wanted } ?? def, def.id)
    }

    public func overview(spaceId: UUID? = nil, includeArchived: Bool = false, now: Date) throws -> BridgeQueries.Overview {
        let spaces = try ctx.fetch(FetchDescriptor<AccountSpace>(sortBy: [SortDescriptor(\.sortOrder)]))
        let scope = try resolveSpace(spaceId)
        let summary = try scope.flatMap {
            try CoreLogic.Dashboard.summary(
                spaceId: $0.current.id, defaultSpaceId: $0.defaultId, months: 1, now: now,
                cycle: snapshot.appState.cycle, in: ctx)
        }

        let accounts = try ctx.fetch(FetchDescriptor<Account>()).filter { includeArchived || !$0.archived }
        let eur = try CoreLogic.Accounts.displayBalancesEur(accounts, in: ctx)
        let native = CoreLogic.Accounts.computeNativeBalances(accounts, in: ctx)
        let valued = Set(try CoreLogic.Investments.loadMetrics(
            for: accounts.filter { $0.group?.kind == .investment }, in: ctx).filter { $0.value.valueEur != nil }.keys)
        let txs = try ctx.fetch(FetchDescriptor<Transaction>())
        var lastTx: [UUID: Date] = [:]
        var uncategorized: [UUID: Int] = [:]
        for t in txs {
            guard let aid = t.account?.id else { continue }
            lastTx[aid] = max(lastTx[aid] ?? .distantPast, t.bookedAt)
            if Self.needsCategory(t) { uncategorized[aid, default: 0] += 1 }
        }

        let lines = accounts.sorted { ($0.group?.sortOrder ?? .max, $0.displayName) < ($1.group?.sortOrder ?? .max, $1.displayName) }
            .map { a in
                BridgeQueries.AccountLine(
                    id: a.id, name: a.displayName, institution: a.institution, group: a.group?.name,
                    groupKind: a.group?.kind.rawValue, space: a.space?.name, currency: a.currency,
                    balanceEur: eur[a.id], balanceNative: native[a.id],
                    balanceSource: valued.contains(a.id) ? "valuation"
                        : CoreLogic.Accounts.hasAnchor(a) ? "anchor"
                        : CoreLogic.Accounts.isManual(a) ? "opening" : "bank",
                    anchorAt: a.balanceAnchorAt, connected: a.connection != nil, archived: a.archived,
                    excluded: a.excluded, pendingApproval: Self.metadata(a)["pendingApproval"] != nil,
                    feedSince: CoreLogic.FeedAdoption.feedSince(of: a), lastTransactionAt: lastTx[a.id],
                    uncategorized: uncategorized[a.id] ?? 0)
            }

        return BridgeQueries.Overview(
            exportedAt: snapshot.exportedAt,
            snapshotAgeMinutes: max(0, Int(now.timeIntervalSince(snapshot.exportedAt) / 60)),
            space: scope?.current.name ?? "",
            spaces: spaces.map { .init(id: $0.id, name: $0.name, isDefault: $0.isDefault) },
            netWorth: summary?.totalNetWorth ?? 0, cash: summary?.cashTotal ?? 0,
            liabilities: summary?.liabilities ?? 0, investments: summary?.investmentValue ?? 0,
            groups: summary?.groups.map { .init(name: $0.name, kind: $0.kind?.rawValue, eur: $0.eur, accounts: $0.count) } ?? [],
            currentPeriod: summary?.flow.last.map(month),
            uncategorizedCount: txs.filter { Self.needsCategory($0) && CoreLogic.AccountStatus.isCountedInCashNetWorth($0.account) }.count,
            accounts: lines,
            connections: try connectionLines(now: now))
    }

    public func transactions(_ q: BridgeQueries.TransactionQuery) throws -> BridgeQueries.TransactionPage {
        let accountIds = q.accountIds.map(Set.init)
        let needle = q.text?.lowercased()
        let details = bankDetailsById
        let matches = try ctx.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.bookedAt, order: .reverse)]))
            .filter { t in
                guard let account = t.account else { return false }
                if let accountIds, !accountIds.contains(account.id) { return false }
                if accountIds == nil, q.includeExcludedAccounts != true, account.archived || account.excluded { return false }
                if let from = q.from, t.bookedAt < from { return false }
                if let to = q.to, t.bookedAt > to { return false }
                if let name = q.category, t.category?.name.caseInsensitiveCompare(name) != .orderedSame { return false }
                if q.uncategorized == true, !Self.needsCategory(t) { return false }
                if let d = q.direction, t.direction != d { return false }
                if let wantTransfer = q.transfers, t.isTransfer != wantTransfer { return false }
                let size = abs(t.amountEur ?? t.amount)
                if let min = q.minAmount, size < min { return false }
                if let max = q.maxAmount, size > max { return false }
                if let needle {
                    let d = details[t.id]
                    let hay = [t.transactionDescription, t.counterparty, d?.creditor, d?.debtor, t.externalId]
                    if !hay.contains(where: { $0?.lowercased().contains(needle) ?? false }) { return false }
                }
                return true
            }
        let offset = max(q.offset ?? 0, 0)
        let limit = min(max(q.limit ?? 100, 1), 1000)
        return .init(total: matches.count, rows: matches.dropFirst(offset).prefix(limit).map { line($0, details) })
    }

    public func monthlyFlow(months: Int, spaceId: UUID? = nil, now: Date) throws -> [BridgeQueries.Month] {
        guard let scope = try resolveSpace(spaceId), let s = try CoreLogic.Dashboard.summary(
            spaceId: scope.current.id, defaultSpaceId: scope.defaultId, months: max(1, months), now: now,
            cycle: snapshot.appState.cycle, in: ctx) else { return [] }
        return s.flow.map(month)
    }

    // Spending per category in the pay cycle that contains `date`, net of refunds.
    public func categoryBreakdown(containing date: Date, spaceId: UUID? = nil) throws -> [BridgeQueries.CategoryTotal] {
        guard let scope = try resolveSpace(spaceId), let s = try CoreLogic.Dashboard.summary(
            spaceId: scope.current.id, defaultSpaceId: scope.defaultId, months: 1, now: date,
            cycle: snapshot.appState.cycle, in: ctx) else { return [] }
        let names = Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<CoreModel.Category>()).map { ($0.id, $0.name) })
        return s.breakdown.map { .init(category: $0.categoryId.flatMap { names[$0] } ?? "Uncategorized", total: $0.total) }
    }

    // In the order the engine tries them: priority descending, then oldest first.
    public func rules() throws -> [BridgeQueries.RuleLine] {
        try ctx.fetch(FetchDescriptor<CategoryRule>(sortBy: [
            SortDescriptor(\.priority, order: .reverse), SortDescriptor(\.createdAt)]))
            .enumerated().map { i, r in
                .init(order: i + 1, id: r.id, pattern: r.pattern, field: r.field, matchType: r.matchType,
                      category: r.category?.name, priority: r.priority)
            }
    }

    public func routes() throws -> [BridgeQueries.RouteLine] {
        var mirrors: [UUID: Int] = [:]
        for t in try ctx.fetch(FetchDescriptor<Transaction>()) where t.routedFromTx != nil {
            if let rid = t.route?.id { mirrors[rid, default: 0] += 1 }
        }
        return try ctx.fetch(FetchDescriptor<TransferRoute>(sortBy: [
            SortDescriptor(\.priority, order: .reverse), SortDescriptor(\.createdAt)])).map { r in
            .init(id: r.id, pattern: r.pattern, field: r.field, matchType: r.matchType,
                  source: r.sourceAccount?.displayName, target: r.targetAccount?.displayName,
                  direction: r.direction, priority: r.priority, enabled: r.enabled, mirrorCount: mirrors[r.id] ?? 0)
        }
    }

    public func categories() throws -> [BridgeQueries.CategoryLine] {
        try ctx.fetch(FetchDescriptor<CoreModel.Category>(sortBy: [SortDescriptor(\.name)])).map {
            .init(id: $0.id, name: $0.name, kind: $0.kind, parent: $0.parent?.name, transactions: $0.transactions.count)
        }
    }

    // With a transaction: every row it could be paired with by hand. Without: unpaired
    // same-amount debit/credit pairs booked in the window, as Transfers.detect would see them.
    public func transferCandidates(
        txId: UUID?, from: Date?, to: Date?, limit: Int = 50
    ) throws -> [BridgeQueries.TransferCandidate] {
        let details = bankDetailsById
        let all = try ctx.fetch(FetchDescriptor<Transaction>()).filter { !$0.isTransfer }
        func candidate(_ a: Transaction, _ b: Transaction) -> BridgeQueries.TransferCandidate {
            let (debit, credit) = a.direction == .debit ? (a, b) : (b, a)
            let days = Int((abs(a.bookedAt.timeIntervalSince(b.bookedAt)) / 86_400).rounded(.down))
            return .init(debit: line(debit, details), credit: line(credit, details), daysApart: days,
                         withinDetectWindow: days <= BridgeQueries.detectWindowDays)
        }
        if let txId {
            guard let tx = findTransaction(txId) else { throw BridgeError.notFound("transaction \(txId)") }
            return all.filter { $0.direction != tx.direction && CoreLogic.Transfers.canPairManual(tx, $0) }
                .map { candidate(tx, $0) }
                .sorted { $0.daysApart < $1.daysApart }
                .prefix(limit).map { $0 }
        }
        let start = from ?? (to ?? .now).addingTimeInterval(-90 * 86_400)
        let end = to ?? .distantFuture
        let window = all.filter { $0.bookedAt >= start && $0.bookedAt <= end }
        // Bucket credits by cent so each debit only meets near-equal amounts.
        var credits: [Int: [Transaction]] = [:]
        for c in window where c.direction == .credit { credits[Self.cents(c), default: []].append(c) }
        var out: [BridgeQueries.TransferCandidate] = []
        for d in window where d.direction == .debit {
            let k = Self.cents(d)
            for c in (credits[k - 1] ?? []) + (credits[k] ?? []) + (credits[k + 1] ?? [])
            where abs(d.bookedAt.timeIntervalSince(c.bookedAt)) <= Double(BridgeQueries.detectWindowDays) * 86_400
                && CoreLogic.Transfers.canPairManual(d, c) {
                out.append(candidate(d, c))
            }
        }
        return out.sorted { $0.debit.bookedAt > $1.debit.bookedAt }.prefix(limit).map { $0 }
    }

    // Credits that could repay an expense, or expenses a credit could be repaying.
    public func paybackCandidates(txId: UUID, query: String = "", limit: Int = 50) throws -> [BridgeQueries.TxLine] {
        guard let tx = findTransaction(txId) else { throw BridgeError.notFound("transaction \(txId)") }
        let ids: [UUID] = tx.direction == .debit
            ? try CoreLogic.SharedExpenses.findCandidateReimbursements(primaryTxId: txId, query: query, in: ctx, limit: limit).map(\.id)
            : try CoreLogic.SharedExpenses.findCandidateRefundedExpenses(creditTxId: txId, query: query, in: ctx, limit: limit).map(\.id)
        let details = bankDetailsById
        return ids.compactMap(findTransaction).map { line($0, details) }
    }

    public func syncStatus(now: Date) throws -> BridgeQueries.SyncStatus {
        var runs = FetchDescriptor<SyncRun>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        runs.fetchLimit = 20
        return .init(connections: try connectionLines(now: now), runs: try ctx.fetch(runs).map {
            .init(institution: $0.connection?.institutionName, startedAt: $0.startedAt, finishedAt: $0.finishedAt,
                  status: $0.status.rawValue, inserted: $0.insertedTransactions, error: $0.error)
        })
    }

    // MARK: - helpers

    func findTransaction(_ id: UUID) -> Transaction? {
        (try? ctx.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })))?.first
    }

    // A row someone still has to categorize. Transfer legs and shared-group members are
    // skipped by the Dashboard, so their category changes nothing.
    static func needsCategory(_ t: Transaction) -> Bool {
        !t.isTransfer && t.sharedExpenseGroup == nil && t.category == nil
    }

    private static func cents(_ t: Transaction) -> Int {
        NSDecimalNumber(decimal: abs(t.amountEur ?? 0) * 100).rounding(accordingToBehavior: nil).intValue
    }

    private static func metadata(_ a: Account) -> [String: Any] {
        a.metadataJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private var bankDetailsById: [UUID: BankDetail] {
        Dictionary(snapshot.bankDetails.map { ($0.txId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func month(_ f: CoreLogic.Dashboard.MonthlyFlow) -> BridgeQueries.Month {
        .init(start: f.monthStart, end: CoreLogic.Dashboard.cycleStart(f.monthStart, cycle: snapshot.appState.cycle, offset: 1),
              income: f.income, expense: f.expense, net: f.income - f.expense)
    }

    private func connectionLines(now: Date) throws -> [BridgeQueries.ConnectionLine] {
        try ctx.fetch(FetchDescriptor<Connection>()).map { c in
            .init(id: c.id, institution: c.institutionName, connector: c.connector.rawValue, status: c.status.rawValue,
                  expiresAt: c.expiresAt,
                  daysUntilExpiry: c.expiresAt.map { Int(($0.timeIntervalSince(now) / 86_400).rounded(.down)) },
                  lastSyncAt: c.lastSyncAt, lastError: c.lastError,
                  accounts: c.accounts.filter { !$0.archived }.count)
        }
    }

    func line(_ t: Transaction, _ details: [UUID: BankDetail]) -> BridgeQueries.TxLine {
        let d = details[t.id]
        return .init(
            id: t.id, externalId: t.externalId, accountId: t.account?.id, account: t.account?.displayName,
            bookedAt: t.bookedAt, valueAt: t.valueAt, amount: t.amount, currency: t.currency, amountEur: t.amountEur,
            direction: t.direction, description: t.transactionDescription, counterparty: t.counterparty,
            category: t.category?.name, categorySource: t.categorySource, isTransfer: t.isTransfer,
            transferGroupId: t.transferGroup?.id,
            pairedTxId: t.transferGroup?.transactions.first { $0.id != t.id }?.id,
            routedFromTxId: t.routedFromTx?.id,
            mirrorTxIds: t.mirrors.isEmpty ? nil : t.mirrors.map(\.id),
            routeId: t.route?.id, sharedGroupId: t.sharedExpenseGroup?.id,
            bankCode: d?.code, creditor: d?.creditor, debtor: d?.debtor)
    }
}

public enum BridgeError: Error, CustomStringConvertible {
    case notFound(String)
    public var description: String {
        switch self { case .notFound(let what): "Not found: \(what)" }
    }
}


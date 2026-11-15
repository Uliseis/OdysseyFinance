import Foundation
import SwiftData
import CoreModel
import CoreSync

// An in-memory store rebuilt from a snapshot. CoreLogic saves inside every mutation, so
// previews must run here and never on a context over the real store.
@MainActor
public final class BridgeReplica {
    public let context: ModelContext
    public let snapshot: BridgeSnapshot

    public init(_ snapshot: BridgeSnapshot) throws {
        let schema = Schema(CoreModelSchema.allTypes)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let ctx = ModelContext(try ModelContainer(for: schema, configurations: [config]))
        ctx.autosaveEnabled = false
        Self.load(snapshot, into: ctx)
        try ctx.save()
        self.context = ctx
        self.snapshot = snapshot
    }

    // The field mapping mirrors ModelSnapshots.insertOrUpdate, but links through id
    // dictionaries: its per-relationship fetches scan every unsaved row and make a full
    // load quadratic. Each model is inserted before it is linked (iOS traps otherwise).
    // BridgeSnapshotTests' export → replica → export equality catches a missed field.
    private static func load(_ s: BridgeSnapshot, into ctx: ModelContext) {
        func index<M: PersistentModel>(_ models: [M], _ id: KeyPath<M, UUID>) -> [UUID: M] {
            Dictionary(models.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { a, _ in a })
        }
        func inserted<M: PersistentModel>(_ m: M) -> M { ctx.insert(m); return m }

        let connections = index(s.connections.map { c in inserted(Connection(
            id: c.id, connector: c.connector, institutionId: c.institutionId, institutionName: c.institutionName,
            sessionId: c.sessionId, accessTokenEnc: c.accessTokenEnc, refreshTokenEnc: c.refreshTokenEnc,
            metadataJSON: c.metadataJSON, status: c.status, expiresAt: c.expiresAt, lastSyncAt: c.lastSyncAt,
            lastError: c.lastError, createdAt: c.createdAt, updatedAt: c.updatedAt)) }, \.id)
        let groups = index(s.accountGroups.map { g in inserted(AccountGroup(
            id: g.id, name: g.name, color: g.color, kind: g.kind, sortOrder: g.sortOrder,
            createdAt: g.createdAt, updatedAt: g.updatedAt)) }, \.id)
        let spaces = index(s.accountSpaces.map { sp in inserted(AccountSpace(
            id: sp.id, name: sp.name, color: sp.color, isDefault: sp.isDefault, sortOrder: sp.sortOrder,
            createdAt: sp.createdAt, updatedAt: sp.updatedAt)) }, \.id)

        let categories = index(s.categories.map { c in inserted(CoreModel.Category(
            id: c.id, name: c.name, kind: c.kind, color: c.color, createdAt: c.createdAt, updatedAt: c.clock)) }, \.id)
        for c in s.categories { categories[c.id]?.parent = c.parentId.flatMap { categories[$0] } }

        for r in s.fxRates {
            ctx.insert(FxRate(id: r.id, date: r.date, currency: r.currency, rate: r.rate, createdAt: r.createdAt))
        }

        let accounts = index(s.accounts.map { a in
            let m = inserted(Account(
                id: a.id, externalId: a.externalId, type: a.type, institution: a.institution, name: a.name,
                alias: a.alias, currency: a.currency, iban: a.iban, balance: a.balance,
                balanceUpdatedAt: a.balanceUpdatedAt, metadataJSON: a.metadataJSON, archived: a.archived,
                excluded: a.excluded, manualOpeningBalance: a.manualOpeningBalance, balanceAnchor: a.balanceAnchor,
                balanceAnchorAt: a.balanceAnchorAt, costBasisOpeningEur: a.costBasisOpeningEur,
                costBasisOpeningAt: a.costBasisOpeningAt, liveValueSource: a.liveValueSource,
                assetQuantity: a.assetQuantity, createdAt: a.createdAt, updatedAt: a.clock))
            m.connection = a.connectionId.flatMap { connections[$0] }
            m.group = a.groupId.flatMap { groups[$0] }
            m.space = a.spaceId.flatMap { spaces[$0] }
            return m
        }, \.id)

        for r in s.categoryRules {
            let m = inserted(CategoryRule(
                id: r.id, pattern: r.pattern, field: r.field, matchType: r.matchType, priority: r.priority,
                createdAt: r.createdAt, updatedAt: r.clock))
            m.category = r.categoryId.flatMap { categories[$0] }
        }
        let routes = index(s.transferRoutes.map { r in
            let m = inserted(TransferRoute(
                id: r.id, pattern: r.pattern, field: r.field, matchType: r.matchType, direction: r.direction,
                priority: r.priority, enabled: r.enabled, createdAt: r.createdAt, updatedAt: r.updatedAt))
            m.sourceAccount = r.sourceAccountId.flatMap { accounts[$0] }
            m.targetAccount = r.targetAccountId.flatMap { accounts[$0] }
            return m
        }, \.id)
        let transferGroups = index(s.transferGroups.map { g in
            let m = inserted(TransferGroup(id: g.id, pairedAt: g.pairedAt, createdAt: g.createdAt, updatedAt: g.clock))
            m.route = g.routeId.flatMap { routes[$0] }
            return m
        }, \.id)
        for b in s.budgets {
            let m = inserted(Budget(
                id: b.id, amountEur: b.amountEur, period: b.period, startsOn: b.startsOn, active: b.active,
                createdAt: b.createdAt, updatedAt: b.updatedAt))
            m.category = b.categoryId.flatMap { categories[$0] }
        }
        for v in s.portfolioValuations {
            let m = inserted(PortfolioValuation(
                id: v.id, asOf: v.asOf, marketValueEur: v.marketValueEur, cashValueEur: v.cashValueEur,
                notes: v.notes, createdAt: v.createdAt, updatedAt: v.updatedAt))
            m.account = v.accountId.flatMap { accounts[$0] }
        }
        for r in s.syncRuns {
            let m = inserted(SyncRun(
                id: r.id, connector: r.connector, startedAt: r.startedAt, finishedAt: r.finishedAt,
                status: r.status, insertedTransactions: r.insertedTransactions, error: r.error, rawJSON: r.rawJSON))
            m.connection = r.connectionId.flatMap { connections[$0] }
        }

        let transactions = index(s.transactions.map { t in
            let m = inserted(Transaction(
                id: t.id, externalId: t.externalId, bookedAt: t.bookedAt, valueAt: t.valueAt, amount: t.amount,
                currency: t.currency, amountEur: t.amountEur, fxRateUsed: t.fxRateUsed, direction: t.direction,
                description: t.transactionDescription, counterparty: t.counterparty,
                categorySource: t.categorySource, isTransfer: t.isTransfer, rawJSON: t.rawJSON,
                createdAt: t.createdAt, updatedAt: t.clock))
            m.account = t.accountId.flatMap { accounts[$0] }
            m.category = t.categoryId.flatMap { categories[$0] }
            m.transferGroup = t.transferGroupId.flatMap { transferGroups[$0] }
            m.route = t.routeId.flatMap { routes[$0] }
            return m
        }, \.id)
        for t in s.transactions where t.routedFromTxId != nil {
            transactions[t.id]?.routedFromTx = t.routedFromTxId.flatMap { transactions[$0] }
        }

        let sharedGroups = index(s.sharedExpenseGroups.map { g in
            let m = inserted(SharedExpenseGroup(
                id: g.id, label: g.label, attributionMonth: g.attributionMonth,
                createdAt: g.createdAt, updatedAt: g.updatedAt))
            m.primaryTx = g.primaryTxId.flatMap { transactions[$0] }
            return m
        }, \.id)
        for t in s.transactions where t.sharedExpenseGroupId != nil {
            transactions[t.id]?.sharedExpenseGroup = t.sharedExpenseGroupId.flatMap { sharedGroups[$0] }
        }
    }
}

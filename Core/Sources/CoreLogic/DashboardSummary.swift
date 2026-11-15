import Foundation
import SwiftData
import CoreModel

extension CoreLogic.Spaces {
    // Ports lib/spaces.ts accountInSpaceClause: the default space also holds space-less accounts.
    public static func contains(_ account: Account, spaceId: UUID, defaultSpaceId: UUID) -> Bool {
        if spaceId == defaultSpaceId { return account.space == nil || account.space?.id == spaceId }
        return account.space?.id == spaceId
    }
}

extension CoreLogic.Dashboard {
    public struct GroupTotal: Equatable, Sendable {
        public let groupId: UUID?
        public let name: String
        public let color: String?
        public let kind: AccountGroupKind?
        public let eur: Decimal
        public let count: Int
    }

    public struct Summary: Equatable, Sendable {
        public let cashTotal: Decimal
        public let liabilities: Decimal
        public let investmentValue: Decimal
        public let groups: [GroupTotal]
        public let flow: [MonthlyFlow]
        public let breakdown: [CategorySpend]
        // Credit-group balances are negative (money owed), so they add straight in.
        public var totalNetWorth: Decimal { cashTotal + investmentValue + liabilities }
    }

    // The Dashboard tab's figures for one space. nil when no counted account is in it.
    @MainActor
    public static func summary(
        spaceId: UUID, defaultSpaceId: UUID, months: Int, now: Date, cycle: Cycle, in ctx: ModelContext
    ) throws -> Summary? {
        let inScope = try ctx.fetch(FetchDescriptor<Account>()).filter {
            CoreLogic.Spaces.contains($0, spaceId: spaceId, defaultSpaceId: defaultSpaceId)
                && CoreLogic.AccountStatus.isCountedInCashNetWorth($0)
        }
        if inScope.isEmpty { return nil }

        // Valuation for investment groups, so an included investment account's row agrees
        // with the hero's Invest figure and the Accounts/Investments tabs.
        let balances = try CoreLogic.Accounts.displayBalancesEur(inScope, in: ctx)
        var buckets: [UUID?: (group: AccountGroup?, eur: Decimal, count: Int)] = [:]
        for a in inScope {
            var b = buckets[a.group?.id] ?? (a.group, 0, 0)
            b.eur += balances[a.id] ?? 0
            b.count += 1
            buckets[a.group?.id] = b
        }
        let groups = buckets.values
            .sorted { ($0.group?.sortOrder ?? .max, $0.group?.name ?? "Ungrouped") < ($1.group?.sortOrder ?? .max, $1.group?.name ?? "Ungrouped") }
            .map { GroupTotal(groupId: $0.group?.id, name: $0.group?.name ?? "Ungrouped", color: $0.group?.color,
                              kind: $0.group?.kind, eur: $0.eur, count: $0.count) }

        var cashTotal: Decimal = 0
        var liabilities: Decimal = 0
        for g in groups {
            if g.kind == .credit { liabilities += g.eur }
            else if g.kind != .investment { cashTotal += g.eur }
        }
        // Investment value ignores `excluded` (investment accounts are typically off cash
        // net worth but still counted as investments), same scoping as the Investments tab.
        let invested = try CoreLogic.Investments.listAccountsInSpace(
            spaceId: spaceId, defaultSpaceId: defaultSpaceId, in: ctx).map(\.account)

        let accountIds = Set(inScope.map(\.id))
        return Summary(
            cashTotal: cashTotal,
            liabilities: liabilities,
            investmentValue: try CoreLogic.Investments.sumLatestValue(for: invested, in: ctx),
            groups: groups,
            flow: try monthlyCashFlow(
                months: months, accountIds: accountIds, incomeAccountIds: incomeAccountIds(from: inScope),
                now: now, cycle: cycle, in: ctx),
            breakdown: try categoryBreakdown(accountIds: accountIds, now: now, cycle: cycle, in: ctx))
    }
}

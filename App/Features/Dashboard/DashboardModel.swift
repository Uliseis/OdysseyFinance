import Foundation
import SwiftData
import CoreModel
import CoreLogic

struct DashboardModel {
    struct GroupBucket: Identifiable {
        let id: String
        let name: String
        let colorHex: String?
        let eur: Decimal
        let count: Int
        let kind: AccountGroupKind?
        let excluded: Bool
    }

    struct MonthBar: Identifiable {
        let id: Date
        let end: Date
        let label: String
        let income: Decimal
        let expense: Decimal
        var net: Decimal { income - expense }
    }

    struct CategorySlice: Identifiable {
        let id: String
        let name: String
        let colorHex: String?
        let total: Decimal
    }

    struct BudgetBar: Identifiable {
        let id: UUID
        let name: String
        let period: BudgetPeriod
        let spent: Decimal
        let amount: Decimal
        let pct: Double
        let over: Bool
    }

    var cashTotal: Decimal
    var liabilities: Decimal
    var investmentValue: Decimal
    var groups: [GroupBucket]
    var cashFlow: [MonthBar]
    var topCategories: [CategorySlice]
    var budgets: [BudgetBar]
    var hasAccounts: Bool

    // Credit-group balances are negative (money owed), so they add straight in.
    var totalNetWorth: Decimal { cashTotal + investmentValue + liabilities }
    var currentMonth: MonthBar? { cashFlow.last }
    var previousMonth: MonthBar? { cashFlow.count >= 2 ? cashFlow[cashFlow.count - 2] : nil }

    static let empty = DashboardModel(
        cashTotal: 0, liabilities: 0, investmentValue: 0,
        groups: [], cashFlow: [], topCategories: [], budgets: [], hasAccounts: false
    )

    @MainActor
    static func load(
        scope: SpaceScope, cycle: CoreLogic.Dashboard.Cycle = CycleSettings.current, in ctx: ModelContext, now: Date = .now
    ) -> DashboardModel {
        guard let currentId = scope.currentId, let defaultId = scope.defaultId,
              let summary = try? CoreLogic.Dashboard.summary(
                spaceId: currentId, defaultSpaceId: defaultId, months: 6, now: now, cycle: cycle, in: ctx)
        else { return empty }

        let groups = summary.groups.map { g in
            GroupBucket(
                id: g.groupId?.uuidString ?? "ungrouped", name: g.name, colorHex: g.color, eur: g.eur,
                count: g.count, kind: g.kind, excluded: g.kind == .credit || g.kind == .investment
            )
        }

        let formatter = cycle.startDay == 1 && !cycle.hasOneOffStarts ? monthFormatter : cycleFormatter
        let cashFlow = summary.flow.map {
            MonthBar(id: $0.monthStart,
                     end: CoreLogic.Dashboard.cycleStart($0.monthStart, cycle: cycle, offset: 1),
                     label: formatter.string(from: $0.monthStart),
                     income: $0.income, expense: $0.expense)
        }

        let cats = (try? ctx.fetch(FetchDescriptor<CoreModel.Category>())) ?? []
        let catById = Dictionary(uniqueKeysWithValues: cats.map { ($0.id, $0) })

        let topCategories = summary.breakdown.prefix(5).map { slice -> CategorySlice in
            let cat = slice.categoryId.flatMap { catById[$0] }
            return CategorySlice(
                id: slice.categoryId?.uuidString ?? "uncategorized",
                name: cat?.name ?? "Uncategorized",
                colorHex: cat?.color, total: slice.total
            )
        }

        let progress = (try? CoreLogic.Budgets.activeBudgetsProgress(at: now, in: ctx)) ?? []
        let budgets = progress
            .map { p -> BudgetBar in
                let amount = p.amountEur
                let pct = amount > 0 ? (p.spentEur / amount).doubleValue * 100 : 0
                return BudgetBar(
                    id: p.budgetId,
                    name: p.categoryId.flatMap { catById[$0]?.name } ?? "—",
                    period: p.period, spent: p.spentEur, amount: amount,
                    pct: pct, over: p.spentEur > amount
                )
            }
            .sorted { $0.pct > $1.pct }
            .prefix(5)
            .map { $0 }

        return DashboardModel(
            cashTotal: summary.cashTotal, liabilities: summary.liabilities, investmentValue: summary.investmentValue,
            groups: groups, cashFlow: cashFlow, topCategories: topCategories,
            budgets: budgets, hasAccounts: true
        )
    }

    private static let cycleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "MMM yyyy"
        return f
    }()
}

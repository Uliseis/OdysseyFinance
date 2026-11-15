import Foundation
import SwiftData
import CoreModel
import CoreLogic

public struct BridgeChange: Codable, Sendable, Equatable {
    public var id: UUID?
    public var label: String
    public var before: String?
    public var after: String?
}

public struct OpOutcome: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case applied, skipped, failed }
    public var index: Int
    public var op: String
    public var status: Status
    public var message: String
    public var changes: [BridgeChange]
}

public struct BatchOutcome: Codable, Sendable, Equatable {
    public var ops: [OpOutcome]
    // Reverses the batch, newest op first. nil when something applied can't be undone.
    public var undo: [BridgeOp]?
    // The switches that must all be on to apply this batch without review; nil when it needs
    // review anyway (an op outside the safe set, a categorize over a categorized row, a failure).
    public var autoApplyKinds: [AutoApplyKind]?

    public var appliedCount: Int { ops.filter { $0.status == .applied }.count }
    public var failedCount: Int { ops.filter { $0.status == .failed }.count }
}

public enum BridgeExecutorError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case ambiguousCategory(String)
    case invalid(String)
    case inUse(String)

    public var description: String {
        switch self {
        case .notFound(let what): "Not found: \(what)"
        case .ambiguousCategory(let name): "More than one category is called \(name)"
        case .invalid(let why): why
        case .inUse(let what): "\(what) is still in use"
        }
    }
}

// Runs a batch through CoreLogic. The same code previews on a replica and applies on the
// app's main context, so what the review sheet shows is what applying does. Ops run in
// order; a failed op is rolled back and the rest still run.
@MainActor
public enum BridgeExecutor {
    public static func run(_ batch: BridgeBatch, in ctx: ModelContext, now: Date = .now) -> BatchOutcome {
        var outcomes: [OpOutcome] = []
        var undo: [BridgeOp]? = []
        var kinds: Set<AutoApplyKind>? = []
        for (index, op) in batch.ops.enumerated() {
            var step = Step()
            let status: OpOutcome.Status
            do {
                try perform(op, &step, in: ctx, now: now)
                status = step.changes.isEmpty ? .skipped : .applied
            } catch {
                ctx.rollback()
                step.message = "\(error)"
                step.changes = []
                status = .failed
            }
            outcomes.append(OpOutcome(index: index, op: op.name, status: status, message: step.message, changes: step.changes))

            if status == .applied {
                if let opUndo = step.undo { undo?.insert(contentsOf: opUndo, at: 0) } else { undo = nil }
            }
            if status == .failed || step.needsReview { kinds = nil } else if let kind = op.autoApplyKind { kinds?.insert(kind) } else { kinds = nil }
        }
        return BatchOutcome(ops: outcomes, undo: undo, autoApplyKinds: kinds.map { $0.sorted { $0.rawValue < $1.rawValue } })
    }

    private struct Step {
        var message = ""
        var changes: [BridgeChange] = []
        var undo: [BridgeOp]?
        var needsReview = false
    }

    private static func perform(_ op: BridgeOp, _ step: inout Step, in ctx: ModelContext, now: Date) throws {
        switch op {
        case .categorize(let txIds, let name):
            let target = try name.map { try category(named: $0, in: ctx) }
            let txs = try txIds.map { try transaction($0, in: ctx) }
            let pending = txs.filter { !($0.category?.id == target?.id && $0.categorySource == .manual) }
            step.needsReview = pending.contains { $0.category != nil }
            step.changes = pending.map { change($0, before: label($0.category), after: label(target)) }
            step.undo = [.restoreCategories(pending.map { CategoryRestore(txId: $0.id, categoryId: $0.category?.id, source: $0.categorySource) })]
            if !pending.isEmpty { try CoreLogic.Categories.recategorize(pending, to: target, in: ctx) }
            step.message = pending.isEmpty
                ? "Already \(label(target))"
                : "\(pending.count) of \(txs.count) rows → \(label(target))"

        case .createCategory(let name, let kind, let parentName):
            if let existing = try findCategories(named: name, in: ctx).first {
                step.message = "\(existing.name) already exists"
                return
            }
            let parent = try parentName.map { try category(named: $0, in: ctx) }
            let created = try CoreLogic.Categories.create(name: name, kind: kind, parent: parent, in: ctx, now: now)
            step.changes = [BridgeChange(id: created.id, label: created.name, before: nil,
                                         after: kind.rawValue + (parent.map { " under \($0.name)" } ?? ""))]
            step.undo = [.deleteCategory(id: created.id)]
            step.message = "New \(kind.rawValue) category \(created.name)"

        case .createRule(let pattern, let categoryName, let field, let match, let priority):
            let target = try category(named: categoryName, in: ctx)
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            let duplicate = try ctx.fetch(FetchDescriptor<CategoryRule>()).contains {
                $0.pattern.lowercased() == trimmed.lowercased() && $0.field == field && $0.matchType == match
                    && $0.category?.id == target.id
            }
            if duplicate {
                step.message = "A rule for \(trimmed) → \(target.name) already exists"
                return
            }
            let matching = try CoreLogic.Categorize.preview(pattern: trimmed, field: field, matchType: match, in: ctx).count
            let rule = try CoreLogic.CategoryRules.create(
                pattern: trimmed, category: target, field: field, matchType: match, priority: priority, in: ctx, now: now)
            step.changes = [BridgeChange(id: rule.id, label: ruleLabel(rule), before: nil, after: "priority \(priority)")]
            step.undo = [.deleteRule(ruleId: rule.id)]
            step.message = "Matches \(matching) existing rows; new rows get it on sync. applyRules re-runs rules on old ones."

        case .updateRule(let ruleId, let pattern, let categoryName, let field, let match):
            let rule = try fetchOne(CategoryRule.self, ruleId, "rule", in: ctx)
            let before = ruleLabel(rule)
            let target = try categoryName.map { try category(named: $0, in: ctx) } ?? rule.category
            guard let target else { throw BridgeExecutorError.invalid("The rule has no category; name one") }
            let newPattern = pattern ?? rule.pattern, newField = field ?? rule.field, newMatch = match ?? rule.matchType
            if newPattern == rule.pattern && newField == rule.field && newMatch == rule.matchType && target.id == rule.category?.id {
                step.message = "Rule unchanged"
                return
            }
            try CoreLogic.CategoryRules.update(rule, pattern: newPattern, category: target, field: newField, matchType: newMatch, in: ctx)
            step.changes = [BridgeChange(id: rule.id, label: "rule", before: before, after: ruleLabel(rule))]
            step.message = "Rule updated; rows it already categorized keep their category until rules re-run"

        case .deleteRule(let ruleId):
            let rule = try fetchOne(CategoryRule.self, ruleId, "rule", in: ctx)
            step.changes = [BridgeChange(id: rule.id, label: ruleLabel(rule), before: "rule", after: nil)]
            try CoreLogic.CategoryRules.delete(rule, in: ctx)
            step.message = "Rule deleted; rows keep their category"

        case .applyRules(let txIds):
            let scope = try txIds.map { try $0.map { try transaction($0, in: ctx) } } ?? ctx.fetch(FetchDescriptor<Transaction>())
            let before = Dictionary(uniqueKeysWithValues: scope.map { ($0.id, ($0.category, $0.categorySource)) })
            try CoreLogic.Categorize.applyRulesToTransactions(in: ctx, txIds: txIds)
            let changed = scope.filter { before[$0.id]?.0?.id != $0.category?.id || before[$0.id]?.1 != $0.categorySource }
            step.changes = changed.map { change($0, before: label(before[$0.id]?.0 ?? nil), after: label($0.category)) }
            step.undo = [.restoreCategories(changed.map {
                CategoryRestore(txId: $0.id, categoryId: before[$0.id]?.0?.id, source: before[$0.id]?.1 ?? .bank)
            })]
            step.message = changed.isEmpty ? "Rules change nothing" : "Rules recategorize \(changed.count) rows"

        case .pairTransfer(let txIds):
            guard txIds.count == 2 else { throw BridgeExecutorError.invalid("pairTransfer takes exactly two txIds") }
            let a = try transaction(txIds[0], in: ctx), b = try transaction(txIds[1], in: ctx)
            if let group = a.transferGroup, group.id == b.transferGroup?.id {
                step.message = "Already paired"
                return
            }
            try CoreLogic.Transfers.pairManual(a, b, in: ctx)
            step.changes = [a, b].map { change($0, before: nil, after: "transfer") }
            step.message = "Paired as a transfer: both legs leave income and spending"

        case .unpairTransfer(let txId):
            let t = try transaction(txId, in: ctx)
            if let source = t.routedFromTx ?? (t.mirrors.isEmpty ? nil : t) {
                let mirrors = source.mirrors
                step.changes = [change(source, before: "transfer", after: nil)]
                    + mirrors.map { change($0, before: "mirror row", after: "deleted") }
                step.message = "Removes the route mirror; the route may book it again on the next sync unless it's changed"
            } else if let group = t.transferGroup {
                step.changes = group.transactions.map { change($0, before: "transfer", after: nil) }
                step.message = "Unpaired; both legs count in income and spending again"
            } else {
                step.message = "Not a transfer"
                return
            }
            try CoreLogic.Transfers.unpair(t, in: ctx)

        case .createSharedGroup(let groupLabel, let primaryTxId, let reimbursementTxIds):
            let primary = try transaction(primaryTxId, in: ctx)
            let paybacks = try reimbursementTxIds.map { try transaction($0, in: ctx) }
            try CoreLogic.SharedExpenses.createGroup(
                .init(label: groupLabel, primaryTxId: primaryTxId, reimbursementTxIds: reimbursementTxIds), in: ctx, now: now)
            step.changes = [change(primary, before: nil, after: "shared: \(groupLabel)")]
                + paybacks.map { change($0, before: label($0.category), after: "payback in \(groupLabel)") }
            let net = (primary.amountEur ?? primary.amount) + paybacks.reduce(Decimal(0)) { $0 + ($1.amountEur ?? $1.amount) }
            step.message = "Group nets to \(net) EUR under \(label(primary.category))"

        case .deleteSharedGroup(let groupId):
            let group = try fetchOne(SharedExpenseGroup.self, groupId, "shared-expense group", in: ctx)
            step.changes = group.members.map { change($0, before: "in \(group.label)", after: nil) }
            try CoreLogic.SharedExpenses.deleteGroup(group, in: ctx)
            step.message = "Group dissolved; its rows count on their own again"

        case .recordValuation(let accountId, let asOf, let market, let cash, let notes):
            let account = try fetchOne(Account.self, accountId, "account", in: ctx)
            guard account.group?.kind == .investment else {
                throw BridgeExecutorError.invalid("\(account.displayName) isn't an investment account")
            }
            // recordValuation replaces a same-day entry; which one it replaced is only known after.
            let before = Dictionary(uniqueKeysWithValues: try CoreLogic.Investments.listValuations(for: [accountId], in: ctx)
                .map { ($0.id, (market: $0.marketValueEur, cash: $0.cashValueEur, notes: $0.notes, asOf: $0.asOf)) })
            let saved = try CoreLogic.Investments.recordValuation(
                account: account, marketValueEur: market, cashValueEur: cash, asOf: asOf, notes: notes, in: ctx, now: now)
            let prior = before[saved.id]
            if let prior, prior.market == market, prior.cash == cash {
                step.message = "Same valuation already recorded"
                return
            }
            step.changes = [BridgeChange(id: saved.id, label: account.displayName,
                                         before: prior.map { "\($0.market)" }, after: "\(market)")]
            step.undo = [prior.map { .recordValuation(accountId: accountId, asOf: $0.asOf, marketValueEur: $0.market,
                                                      cashValueEur: $0.cash, notes: $0.notes) }
                         ?? .deleteValuation(id: saved.id)]
            step.message = prior == nil ? "New valuation" : "Replaces that day's valuation"

        case .importStatement(let accountId, let csv):
            let account = try fetchOne(Account.self, accountId, "account", in: ctx)
            let before = Dictionary(uniqueKeysWithValues: try rows(of: accountId, in: ctx).map { ($0.id, $0.externalId) })
            let summary = try CoreLogic.StatementImport.importCSV(csv, into: account, in: ctx, now: now)
            let after = try rows(of: accountId, in: ctx)
            let inserted = after.filter { before[$0.id] == nil }
            let rekeyed = after.filter { t in before[t.id].map { $0 != t.externalId } ?? false }
            let unmatched: [BridgeChange] = summary.unmatched.map { u in
                let day = u.bookedAt.formatted(.iso8601.year().month().day())
                return BridgeChange(id: u.id, label: "\(day) · \(u.description ?? "quick-add") · \(u.amount)",
                                    before: "quick-add", after: "no statement row: check it, or delete it with deleteTransactions")
            }
            step.changes = inserted.map { change($0, before: nil, after: "new row") }
                + rekeyed.map { change($0, before: "quick-add", after: "matched to the statement") }
                + unmatched
            step.message = "\(summary.parsed) statement rows: \(summary.inserted) new, \(summary.matchedManual) matched to quick-adds, "
                + "\(summary.skippedDuplicate) already there, \(summary.skippedTransfers) transfers skipped, \(summary.categorized) categorized by rules"
                + (summary.errors.isEmpty ? "" : ". Unreadable lines: \(summary.errors.joined(separator: "; "))")
            if summary.inserted + summary.matchedManual == 0 { step.changes = [] }

        case .deleteTransactions(let txIds):
            let txs = try txIds.map { try transaction($0, in: ctx) }
            step.changes = txs.map { change($0, before: label($0.category), after: "deleted") }
            for t in txs { try CoreLogic.Transactions.delete(t, in: ctx) }
            step.message = "\(txs.count) rows deleted, with any mirrors they had"

        case .adoptFeed(let feedAccountId, let manualAccountId):
            let feed = try fetchOne(Account.self, feedAccountId, "account", in: ctx)
            let manual = try fetchOne(Account.self, manualAccountId, "account", in: ctx)
            let feedName = feed.displayName, manualName = manual.displayName
            let summary = try CoreLogic.FeedAdoption.adopt(feed: feed, into: manual, in: ctx, now: now)
            step.changes = [BridgeChange(id: manualAccountId, label: manualName, before: "manual", after: "bank-fed"),
                            BridgeChange(id: feedAccountId, label: feedName, before: "discovered account", after: "merged and removed")]
            step.message = "\(summary.rekeyed) rows matched to manual ones, \(summary.mirrorsReplaced) route mirrors replaced by the real leg, "
                + "\(summary.moved) moved, \(summary.keptManualOnly) manual rows with no bank twin kept"

        case .undoPensionSplit(let debitTxId):
            let debit = try transaction(debitTxId, in: ctx)
            guard try CoreLogic.Automations.splitSource(of: debit, in: ctx) != nil else {
                throw BridgeExecutorError.invalid("Not a pension split leg")
            }
            let legs = debit.transferGroup?.transactions ?? [debit]
            step.changes = legs.map { change($0, before: "pension split", after: "deleted") }
            try CoreLogic.Automations.undoSplit(debitTxId: debitTxId, in: ctx)
            step.message = "Both legs removed; the arrival is remembered so it isn't split again"

        case .createRoute(let pattern, let targetId, let sourceId, let field, let match, let direction, let priority):
            let target = try fetchOne(Account.self, targetId, "account", in: ctx)
            let source = try sourceId.map { try fetchOne(Account.self, $0, "account", in: ctx) }
            let mirrors = try mirrorChanges(in: ctx) {
                try CoreLogic.TransferRoutes.createRoute(
                    pattern: pattern, target: target, source: source, field: field, matchType: match,
                    direction: direction, priority: priority, in: ctx, now: now)
            }
            step.changes = [BridgeChange(id: nil, label: "\(field.rawValue) \(match.rawValue) \"\(pattern)\" → \(target.displayName)",
                                         before: nil, after: "route")] + mirrors
            step.message = "New route; \(mirrors.count) mirror rows booked on \(target.displayName) for past matches"

        case .updateRoute(let routeId, let pattern, let targetId, let sourceId, let field, let match, let direction, let enabled):
            let route = try fetchOne(TransferRoute.self, routeId, "route", in: ctx)
            guard let currentTarget = route.targetAccount else { throw BridgeExecutorError.invalid("The route has no target account") }
            let target = try targetId.map { try fetchOne(Account.self, $0, "account", in: ctx) } ?? currentTarget
            let source = try sourceId.map { try fetchOne(Account.self, $0, "account", in: ctx) } ?? route.sourceAccount
            let before = routeLabel(route)
            let mirrors = try mirrorChanges(in: ctx) {
                try CoreLogic.TransferRoutes.updateRoute(
                    route, pattern: pattern ?? route.pattern, target: target, source: source, field: field ?? route.field,
                    matchType: match ?? route.matchType, direction: direction ?? route.direction,
                    enabled: enabled ?? route.enabled, in: ctx, now: now)
            }
            let after = routeLabel(route)
            if before == after && mirrors.isEmpty {
                step.message = "Route unchanged"
                return
            }
            step.changes = [BridgeChange(id: routeId, label: "route", before: before, after: after)] + mirrors
            step.message = "Route updated: \(mirrors.filter { $0.after == "deleted" }.count) mirrors removed, "
                + "\(mirrors.filter { $0.before == nil }.count) booked"

        case .deleteRoute(let routeId):
            let route = try fetchOne(TransferRoute.self, routeId, "route", in: ctx)
            let label = routeLabel(route)
            let mirrors = try mirrorChanges(in: ctx) { try CoreLogic.TransferRoutes.deleteRoute(route, in: ctx) }
            step.changes = [BridgeChange(id: routeId, label: label, before: "route", after: "deleted")] + mirrors
            step.message = "Route deleted with its \(mirrors.count) mirror rows; their source rows count as spending again"

        case .requestBankSync(let connectionIds):
            let all = try ctx.fetch(FetchDescriptor<Connection>()).filter { $0.connector == .enablebanking }
            let chosen = try connectionIds.map { ids in try ids.map { try fetchOne(Connection.self, $0, "connection", in: ctx) } } ?? all
            step.changes = chosen.map {
                BridgeChange(id: $0.id, label: $0.institutionName ?? "bank",
                             before: $0.lastSyncAt.map { "last synced \($0.formatted(.iso8601))" }, after: "sync requested")
            }
            step.undo = []
            step.message = "The phone syncs these banks after this batch"

        case .requestReconnect(let connectionId):
            let connection = try fetchOne(Connection.self, connectionId, "connection", in: ctx)
            step.changes = [BridgeChange(id: connectionId, label: connection.institutionName ?? "bank",
                                         before: connection.expiresAt.map { "consent until \($0.formatted(.iso8601.year().month().day()))" },
                                         after: "reconnect screen opens")]
            step.message = "Approving opens this bank's connection screen; you finish the reconnect with the bank"

        case .restoreCategories(let restores):
            for r in restores {
                let t = try transaction(r.txId, in: ctx)
                let target = try r.categoryId.map { try fetchOne(CoreModel.Category.self, $0, "category", in: ctx) }
                guard t.category?.id != target?.id || t.categorySource != r.source else { continue }
                step.changes.append(change(t, before: label(t.category), after: label(target)))
                t.category = target
                t.categorySource = r.source
            }
            try ctx.saveTouchingChanges()
            step.message = "\(step.changes.count) rows restored"

        case .deleteCategory(let id):
            let c = try fetchOne(CoreModel.Category.self, id, "category", in: ctx)
            // Deleting cascades to rules and budgets and clears rows: only an unused one goes.
            guard c.transactions.isEmpty, c.rules.isEmpty, c.budgets.isEmpty, c.children.isEmpty else {
                throw BridgeExecutorError.inUse(c.name)
            }
            step.changes = [BridgeChange(id: id, label: c.name, before: "category", after: nil)]
            try CoreLogic.Categories.delete(c, in: ctx)
            step.message = "Category removed"

        case .deleteValuation(let id):
            let v = try fetchOne(PortfolioValuation.self, id, "valuation", in: ctx)
            step.changes = [BridgeChange(id: id, label: v.account?.displayName ?? "valuation", before: "\(v.marketValueEur)", after: nil)]
            try CoreLogic.Investments.deleteValuation(v, in: ctx)
            step.message = "Valuation removed"
        }
    }

    // MARK: - lookups

    static func transaction(_ id: UUID, in ctx: ModelContext) throws -> Transaction {
        try fetchOne(Transaction.self, id, "transaction", in: ctx)
    }

    private static func fetchOne<M: PersistentModel & Identifiable>(
        _ type: M.Type, _ id: UUID, _ what: String, in ctx: ModelContext
    ) throws -> M where M.ID == UUID {
        // #Predicate can't take a generic key path, so filter after fetching.
        guard let found = try ctx.fetch(FetchDescriptor<M>()).first(where: { $0.id == id }) else {
            throw BridgeExecutorError.notFound("\(what) \(id.uuidString)")
        }
        return found
    }

    static func findCategories(named name: String, in ctx: ModelContext) throws -> [CoreModel.Category] {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try ctx.fetch(FetchDescriptor<CoreModel.Category>()).filter { $0.name.lowercased() == wanted }
    }

    static func category(named name: String, in ctx: ModelContext) throws -> CoreModel.Category {
        let found = try findCategories(named: name, in: ctx)
        guard found.count < 2 else { throw BridgeExecutorError.ambiguousCategory(name) }
        guard let category = found.first else { throw BridgeExecutorError.notFound("category \(name)") }
        return category
    }

    private static func rows(of accountId: UUID, in ctx: ModelContext) throws -> [Transaction] {
        try ctx.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.account?.id == accountId }))
    }

    // Mirror rows booked and removed by a route change, labelled before they go.
    private static func mirrorChanges(in ctx: ModelContext, _ body: () throws -> Any) throws -> [BridgeChange] {
        func mirrors() throws -> [UUID: Transaction] {
            Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<Transaction>()).filter { $0.routedFromTx != nil }.map { ($0.id, $0) })
        }
        let before = try mirrors().mapValues { change($0, before: "mirror", after: "deleted") }
        _ = try body()
        let after = try mirrors()
        return before.filter { after[$0.key] == nil }.values.sorted { $0.label < $1.label }
            + after.filter { before[$0.key] == nil }.values.map { change($0, before: nil, after: "mirror") }.sorted { $0.label < $1.label }
    }

    // MARK: - labels

    private static func label(_ category: CoreModel.Category?) -> String { category?.name ?? "Uncategorized" }

    private static func routeLabel(_ route: TransferRoute) -> String {
        "\(route.field.rawValue) \(route.matchType.rawValue) \"\(route.pattern)\" → \(route.targetAccount?.displayName ?? "?")"
            + (route.direction.map { " (\($0.rawValue)s)" } ?? "") + (route.enabled ? "" : ", disabled")
    }

    private static func ruleLabel(_ rule: CategoryRule) -> String {
        "\(rule.field.rawValue) \(rule.matchType.rawValue) \"\(rule.pattern)\" → \(label(rule.category))"
    }

    private static func change(_ t: Transaction, before: String?, after: String?) -> BridgeChange {
        let day = t.bookedAt.formatted(.iso8601.year().month().day())
        let text = t.transactionDescription ?? t.counterparty ?? t.externalId
        return BridgeChange(id: t.id, label: "\(day) · \(t.account?.displayName ?? "?") · \(text) · \(t.amount) \(t.currency)",
                            before: before, after: after)
    }
}

// What a batch does to the figures the user watches.
public struct BridgeEffect: Codable, Sendable, Equatable {
    public var netWorth: Decimal
    public var cycleIncome: Decimal
    public var cycleExpense: Decimal
    public var cycleNet: Decimal
    public var uncategorized: Int
}

public struct BatchPreview: Codable, Sendable, Equatable {
    public var outcome: BatchOutcome
    public var before: BridgeEffect
    public var after: BridgeEffect
}

@MainActor
extension BridgeReplica {
    // Applies the batch to this replica, so build a fresh replica for every preview.
    public func preview(_ batch: BridgeBatch, now: Date = .now) throws -> BatchPreview {
        let before = try effect(now: now)
        let outcome = BridgeExecutor.run(batch, in: context, now: now)
        return BatchPreview(outcome: outcome, before: before, after: try effect(now: now))
    }

    func effect(now: Date) throws -> BridgeEffect {
        let o = try overview(now: now)
        return BridgeEffect(
            netWorth: o.netWorth, cycleIncome: o.currentPeriod?.income ?? 0, cycleExpense: o.currentPeriod?.expense ?? 0,
            cycleNet: o.currentPeriod?.net ?? 0, uncategorized: o.uncategorizedCount)
    }
}

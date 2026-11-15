#if DEBUG
import Foundation
import SwiftData
import CoreModel
import CoreLogic

// One-shot data load for the manual credit card, gated on OFCC_IMPORT=1 (set via devicectl
// on a single launch). Two optional inputs in Documents/, both deleted after a successful run:
//   statement.csv   — a Revolut statement, fed through the same StatementImport the UI uses
//   cc-import.json  — {"rules":[…],"transactions":[…],"valuations":[…]} (a bare row array
//                     still decodes). Rows carry pre-computed externalIds (e.g. screenshot
//                     rows as revolutshot:v1:…). Rule seeds are created first so everything
//                     inserted this run categorizes; then every still-uncategorized row on the
//                     account is re-run against the rules so older quick-adds catch up too.
// Inserts go through the main context so SaveObserver pushes to CloudKit. Idempotent.
enum CCStatementImport {
    struct RuleSeed: Decodable {
        let pattern: String
        let category: String
        let priority: Int?
        // Set on an existing pattern to move that rule to another field.
        let field: String?
    }

    struct ValuationSeed: Decodable {
        let accountId: String
        let marketValueEur: String
        let cashValueEur: String?
        let notes: String?
    }

    struct CategorySeed: Decodable {
        let name: String
        let kind: String?
    }

    // Rows to categorize by hand (categorySource .manual, so rules never overwrite them).
    struct CategorizeSeed: Decodable {
        let category: String
        let externalIds: [String]
    }

    struct SharedGroupSeed: Decodable {
        let label: String
        let primaryExternalId: String
        let reimbursementExternalIds: [String]
    }

    struct PairSeed: Decodable {
        let debitExternalId: String
        let creditExternalId: String
    }

    // A route-style mirror leg into a tracked account the bank line never reached.
    struct MirrorSeed: Decodable {
        let sourceExternalId: String
        let targetAccountId: String
    }

    struct Payload: Decodable {
        var rules: [RuleSeed]?
        var transactions: [Row] = []
        var valuations: [ValuationSeed]?
        // Deleted before inserts, so a row can be replaced under the same externalId. An
        // auto-recurring id is also declined so the automation doesn't re-book it.
        var deleteExternalIds: [String]?
        // Debit-leg externalIds of pension splits to undo (both legs go, the arrival is
        // declined), and arrivals to decline up front so the automation never splits them.
        var undoPensionSplits: [String]?
        var declinePensionArrivals: [String]?
        var archiveAccountIds: [String]?
        var categories: [CategorySeed]?
        var categorize: [CategorizeSeed]?
        var sharedGroups: [SharedGroupSeed]?
        // yyyy-mm-dd: re-run the rules over every uncategorized row since then, on any account.
        var categorizeSince: String?
        var unpairExternalIds: [String]?
        var pairs: [PairSeed]?
        var mirrors: [MirrorSeed]?

        init(from decoder: Decoder) throws {
            if let bare = try? [Row](from: decoder) { transactions = bare; return }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rules = try c.decodeIfPresent([RuleSeed].self, forKey: .rules)
            transactions = try c.decodeIfPresent([Row].self, forKey: .transactions) ?? []
            valuations = try c.decodeIfPresent([ValuationSeed].self, forKey: .valuations)
            deleteExternalIds = try c.decodeIfPresent([String].self, forKey: .deleteExternalIds)
            undoPensionSplits = try c.decodeIfPresent([String].self, forKey: .undoPensionSplits)
            declinePensionArrivals = try c.decodeIfPresent([String].self, forKey: .declinePensionArrivals)
            archiveAccountIds = try c.decodeIfPresent([String].self, forKey: .archiveAccountIds)
            categories = try c.decodeIfPresent([CategorySeed].self, forKey: .categories)
            categorize = try c.decodeIfPresent([CategorizeSeed].self, forKey: .categorize)
            sharedGroups = try c.decodeIfPresent([SharedGroupSeed].self, forKey: .sharedGroups)
            categorizeSince = try c.decodeIfPresent(String.self, forKey: .categorizeSince)
            unpairExternalIds = try c.decodeIfPresent([String].self, forKey: .unpairExternalIds)
            pairs = try c.decodeIfPresent([PairSeed].self, forKey: .pairs)
            mirrors = try c.decodeIfPresent([MirrorSeed].self, forKey: .mirrors)
        }
        private enum CodingKeys: String, CodingKey {
            case rules, transactions, valuations, deleteExternalIds, undoPensionSplits, declinePensionArrivals
            case archiveAccountIds, categories, categorize, sharedGroups, categorizeSince
            case unpairExternalIds, pairs, mirrors
        }
    }

    struct Row: Decodable {
        let accountId: String?
        let externalId: String
        let bookedAt: String
        let valueAt: String?
        let amount: String
        let currency: String
        let direction: String
        let description: String?
        // A category name here books the row as a manual categorization (rules skip it).
        let category: String?
    }

    // Default target for rows without their own accountId: OFCC_ACCOUNT=<account uuid>, so no
    // live record id has to live in the source.
    static var accountId: UUID? {
        ProcessInfo.processInfo.environment["OFCC_ACCOUNT"].flatMap(UUID.init(uuidString:))
    }

    @MainActor
    static func runIfRequested(_ container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["OFCC_IMPORT"] == "1" else { return }
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        let jsonURL = docs.appendingPathComponent("cc-import.json")
        let csvURL = docs.appendingPathComponent("statement.csv")
        let payload = (try? Data(contentsOf: jsonURL)).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        let csv = try? String(contentsOf: csvURL, encoding: .utf8)
        guard payload != nil || csv != nil else {
            print("[CCImport] nothing in Documents — nothing to do"); return
        }
        let ctx = container.mainContext
        guard let acctId = accountId else {
            print("[CCImport] set OFCC_ACCOUNT=<account uuid>"); return
        }
        guard let account = try? ctx.fetch(FetchDescriptor<Account>(
            predicate: #Predicate { $0.id == acctId })).first else {
            print("[CCImport] target account not found"); return
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        for seed in payload?.categories ?? [] {
            let name = seed.name
            let exists = ((try? ctx.fetchCount(FetchDescriptor<CoreModel.Category>(
                predicate: #Predicate { $0.name == name }))) ?? 0) > 0
            if !exists {
                _ = try? CoreLogic.Categories.create(
                    name: name, kind: seed.kind.flatMap(CategoryKind.init(rawValue:)) ?? .expense, in: ctx)
            }
        }

        var seededRules = 0
        var updatedRules = 0
        for seed in payload?.rules ?? [] {
            let pattern = seed.pattern
            let field = seed.field.flatMap(RuleField.init(rawValue:))
            let existing = (try? ctx.fetch(FetchDescriptor<CategoryRule>(
                predicate: #Predicate { $0.pattern == pattern }))) ?? []
            if let rule = existing.first {
                if let field, rule.field != field, let category = rule.category {
                    try? CoreLogic.CategoryRules.update(
                        rule, pattern: rule.pattern, category: category,
                        field: field, matchType: rule.matchType, in: ctx)
                    updatedRules += 1
                }
                continue
            }
            let name = seed.category
            guard let category = try? ctx.fetch(FetchDescriptor<CoreModel.Category>(
                predicate: #Predicate { $0.name == name })).first else {
                print("[CCImport] no category named \(name) for rule \(pattern)"); continue
            }
            _ = try? CoreLogic.CategoryRules.create(
                pattern: pattern, category: category, field: field ?? .description,
                priority: seed.priority ?? -1000, in: ctx)
            seededRules += 1
        }
        try? ctx.save()

        if let csv {
            do {
                let s = try CoreLogic.StatementImport.importCSV(csv, into: account, in: ctx)
                print("[CCImport] csv parsed=\(s.parsed) inserted=\(s.inserted) matched=\(s.matchedManual) dup=\(s.skippedDuplicate) transfers=\(s.skippedTransfers) categorized=\(s.categorized) errors=\(s.errors)")
                try? FileManager.default.removeItem(at: csvURL)
            } catch {
                print("[CCImport] csv failed: \(error)")
            }
        }

        var deleted = 0
        for eid in payload?.deleteExternalIds ?? [] {
            for tx in (try? ctx.fetch(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.externalId == eid }))) ?? [] {
                do { try CoreLogic.Transactions.delete(tx, in: ctx); deleted += 1 }
                catch { print("[CCImport] delete refused \(eid): \(error)") }
            }
            if eid.hasPrefix(CoreLogic.Automations.recurringPrefix) { AutomationSettings.declineRecurring(eid) }
        }
        for eid in payload?.undoPensionSplits ?? [] {
            guard let debit = (try? ctx.fetch(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.externalId == eid })))?.first else { continue }
            do {
                if let arrival = try CoreLogic.Automations.undoSplit(debitTxId: debit.id, in: ctx) {
                    AutomationSettings.declineSplit(arrival)
                }
                deleted += 1
            } catch { print("[CCImport] undo split refused \(eid): \(error)") }
        }
        for eid in payload?.declinePensionArrivals ?? [] { AutomationSettings.declineSplit(eid) }
        var archived = 0
        for raw in payload?.archiveAccountIds ?? [] {
            guard let id = UUID(uuidString: raw), let target = try? ctx.fetch(FetchDescriptor<Account>(
                predicate: #Predicate { $0.id == id })).first else { continue }
            if (try? CoreLogic.Accounts.setArchived(target, true, in: ctx)) != nil { archived += 1 }
        }

        var insertedIds: [UUID] = []
        var skipped = 0
        for r in payload?.transactions ?? [] {
            let eid = r.externalId
            let targetId = r.accountId.flatMap(UUID.init(uuidString:)) ?? acctId
            guard let target = targetId == acctId ? account : try? ctx.fetch(FetchDescriptor<Account>(
                predicate: #Predicate { $0.id == targetId })).first else {
                print("[CCImport] no account \(targetId) for \(eid)"); continue
            }
            let exists = ((try? ctx.fetchCount(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.account?.id == targetId && $0.externalId == eid }))) ?? 0) > 0
            if exists { skipped += 1; continue }
            guard let booked = iso.date(from: r.bookedAt), let amount = Decimal(string: r.amount) else {
                print("[CCImport] bad row \(eid)"); continue
            }
            let tx = Transaction(
                account: target,
                externalId: eid,
                bookedAt: booked,
                valueAt: r.valueAt.flatMap { iso.date(from: $0) },
                amount: amount,
                currency: r.currency,
                amountEur: amount,
                fxRateUsed: 1,
                direction: r.direction == "credit" ? .credit : .debit,
                description: r.description,
                counterparty: nil,
                categorySource: .bank)
            if let name = r.category {
                tx.category = try? ctx.fetch(FetchDescriptor<CoreModel.Category>(
                    predicate: #Predicate { $0.name == name })).first
                if tx.category != nil { tx.categorySource = .manual }
            }
            ctx.insert(tx)
            insertedIds.append(tx.id)
        }
        do { try ctx.save() } catch { print("[CCImport] save failed: \(error)"); return }

        var valuations = 0
        for v in payload?.valuations ?? [] {
            guard let id = UUID(uuidString: v.accountId), let value = Decimal(string: v.marketValueEur),
                  let target = try? ctx.fetch(FetchDescriptor<Account>(
                    predicate: #Predicate { $0.id == id })).first else {
                print("[CCImport] bad valuation \(v.accountId)"); continue
            }
            _ = try? CoreLogic.Investments.recordValuation(
                account: target, marketValueEur: value,
                cashValueEur: v.cashValueEur.flatMap { Decimal(string: $0) },
                notes: v.notes, in: ctx)
            valuations += 1
        }

        func rows(_ ids: [String]) -> [Transaction] {
            ids.flatMap { eid in
                (try? ctx.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.externalId == eid }))) ?? []
            }
        }
        var handCategorized = 0
        for seed in payload?.categorize ?? [] {
            let name = seed.category
            guard let category = try? ctx.fetch(FetchDescriptor<CoreModel.Category>(
                predicate: #Predicate { $0.name == name })).first else {
                print("[CCImport] no category named \(name)"); continue
            }
            let txs = rows(seed.externalIds)
            try? CoreLogic.Categories.recategorize(txs, to: category, in: ctx)
            handCategorized += txs.count
        }

        var transferFixes = 0
        for tx in rows(payload?.unpairExternalIds ?? []) {
            do { try CoreLogic.Transfers.unpair(tx, in: ctx); transferFixes += 1 }
            catch { print("[CCImport] unpair refused \(tx.externalId): \(error)") }
        }
        for seed in payload?.pairs ?? [] {
            guard let debit = rows([seed.debitExternalId]).first,
                  let credit = rows([seed.creditExternalId]).first else { continue }
            do { _ = try CoreLogic.Transfers.pairManual(debit, credit, in: ctx); transferFixes += 1 }
            catch { print("[CCImport] pair refused \(seed.debitExternalId): \(error)") }
        }
        for seed in payload?.mirrors ?? [] {
            guard let source = rows([seed.sourceExternalId]).first,
                  let targetId = UUID(uuidString: seed.targetAccountId),
                  let target = try? ctx.fetch(FetchDescriptor<Account>(
                    predicate: #Predicate { $0.id == targetId })).first else { continue }
            do {
                if try CoreLogic.TransferRoutes.createMirror(from: source, to: target, in: ctx) != nil { transferFixes += 1 }
            } catch { print("[CCImport] mirror refused \(seed.sourceExternalId): \(error)") }
        }
        print("[CCImport] transferFixes=\(transferFixes)")

        var groups = 0
        for seed in payload?.sharedGroups ?? [] {
            guard let primary = rows([seed.primaryExternalId]).first else { continue }
            let reimbursements = rows(seed.reimbursementExternalIds)
            do {
                try CoreLogic.SharedExpenses.createGroup(.init(
                    label: seed.label, primaryTxId: primary.id,
                    reimbursementTxIds: reimbursements.map(\.id)), in: ctx)
                groups += 1
            } catch { print("[CCImport] shared group refused \(seed.label): \(error)") }
        }

        var sinceCategorized = 0
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        if let since = payload?.categorizeSince.flatMap({ day.date(from: $0) }) {
            let ids = ((try? ctx.fetch(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.category == nil && $0.bookedAt >= since }))) ?? []).map(\.id)
            sinceCategorized = (try? CoreLogic.Categorize.applyRulesToTransactions(in: ctx, txIds: ids))?.updated ?? 0
        }
        print("[CCImport] handCategorized=\(handCategorized) groups=\(groups) sinceCategorized=\(sinceCategorized)")

        let uncategorized = (try? ctx.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.account?.id == acctId && $0.category == nil }))) ?? []
        // A changed rule can reach rows on any account, so it re-runs everything.
        let cats = (try? CoreLogic.Categorize.applyRulesToTransactions(
            in: ctx, txIds: updatedRules > 0 ? nil : uncategorized.map(\.id) + insertedIds))?.updated ?? 0
        try? ctx.save()
        print("[CCImport] rules=\(seededRules) updatedRules=\(updatedRules) deleted=\(deleted) archived=\(archived) inserted=\(insertedIds.count) skipped=\(skipped) valuations=\(valuations) categorized=\(cats)")
        if payload != nil { try? FileManager.default.removeItem(at: jsonURL) }
    }
}
#endif

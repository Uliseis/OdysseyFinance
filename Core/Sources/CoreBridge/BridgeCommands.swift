import Foundation
import CoreModel

// A batch of changes Claude proposes: one review, one Face ID. Ops run in order, so a
// category created early in a batch can be used by name later in it.
public struct BridgeBatch: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    // Claude's one-paragraph reason, shown at the top of the review sheet.
    public var summary: String
    // exportedAt of the snapshot the batch was drafted against.
    public var basedOn: Date?
    public var ops: [BridgeOp]

    public init(id: UUID = UUID(), createdAt: Date = .now, summary: String, basedOn: Date? = nil, ops: [BridgeOp]) {
        self.id = id
        self.createdAt = createdAt
        self.summary = summary
        self.basedOn = basedOn
        self.ops = ops
    }
}

public struct CategoryRestore: Codable, Sendable, Equatable {
    public var txId: UUID
    public var categoryId: UUID?
    public var source: CategorySource
}

public struct FundTradeRestore: Codable, Sendable, Equatable {
    public var id: UUID
    public var amountEur: Decimal
    public var switchGroupId: UUID?
}

// Categories are named, as the policy and Claude name them; records are referenced by id.
public enum BridgeOp: Sendable, Equatable {
    case categorize(txIds: [UUID], category: String?)
    case createCategory(name: String, kind: CategoryKind, parent: String?)
    case createRule(pattern: String, category: String, field: RuleField, match: RuleMatch, priority: Int)
    case updateRule(ruleId: UUID, pattern: String?, category: String?, field: RuleField?, match: RuleMatch?)
    case deleteRule(ruleId: UUID)
    case applyRules(txIds: [UUID]?)
    case pairTransfer(txIds: [UUID])
    case unpairTransfer(txId: UUID)
    case createSharedGroup(label: String, primaryTxId: UUID, reimbursementTxIds: [UUID])
    case deleteSharedGroup(groupId: UUID)
    case recordValuation(accountId: UUID, asOf: Date, marketValueEur: Decimal, cashValueEur: Decimal?, notes: String?)
    case importStatement(accountId: UUID, csv: String)
    case deleteTransactions(txIds: [UUID])
    case adoptFeed(feedAccountId: UUID, manualAccountId: UUID)
    case undoPensionSplit(debitTxId: UUID)
    case createRoute(pattern: String, targetAccountId: UUID, sourceAccountId: UUID?, field: RuleField, match: RuleMatch,
                     direction: TxDirection?, priority: Int)
    case updateRoute(routeId: UUID, pattern: String?, targetAccountId: UUID?, sourceAccountId: UUID?, field: RuleField?,
                     match: RuleMatch?, direction: TxDirection?, enabled: Bool?)
    case deleteRoute(routeId: UUID)
    // Asks the phone to do what only it can (bank keys and SCA live there); no data changes here.
    case requestBankSync(connectionIds: [UUID]?)
    case requestReconnect(connectionId: UUID)
    case createTransaction(accountId: UUID, amount: Decimal, bookedAt: Date, description: String?, counterparty: String?,
                           category: String?)
    case mirrorTransfer(sourceTxId: UUID, targetAccountId: UUID)
    case createSharedGroupFromCredit(label: String, creditTxId: UUID, expenseTxIds: [UUID])
    case archiveAccount(accountId: UUID, archived: Bool)
    // Units held today per ISIN, as the broker shows them: the export doesn't say which orders sold.
    case importFundOrders(accountId: UUID, ordersCsv: String, movementsCsv: String, heldUnits: [String: Decimal])
    // A nil amount clears the anchor or opening.
    case setBrokerCashAnchor(accountId: UUID, amountEur: Decimal?, at: Date?)
    case setCostBasisOpening(accountId: UUID, amountEur: Decimal?, at: Date?)
    case setLiveSource(accountId: UUID, source: String?)
    // Only the phone builds these, to undo an auto-applied batch. Never accepted from the inbox.
    case restoreCategories([CategoryRestore])
    case deleteCategory(id: UUID)
    case deleteValuation(id: UUID)
    case restoreFundTrades(deleteIds: [UUID], restores: [FundTradeRestore])

    public var name: String {
        switch self {
        case .categorize: "categorize"
        case .createCategory: "createCategory"
        case .createRule: "createRule"
        case .updateRule: "updateRule"
        case .deleteRule: "deleteRule"
        case .applyRules: "applyRules"
        case .pairTransfer: "pairTransfer"
        case .unpairTransfer: "unpairTransfer"
        case .createSharedGroup: "createSharedGroup"
        case .deleteSharedGroup: "deleteSharedGroup"
        case .recordValuation: "recordValuation"
        case .importStatement: "importStatement"
        case .deleteTransactions: "deleteTransactions"
        case .adoptFeed: "adoptFeed"
        case .undoPensionSplit: "undoPensionSplit"
        case .createRoute: "createRoute"
        case .updateRoute: "updateRoute"
        case .deleteRoute: "deleteRoute"
        case .requestBankSync: "requestBankSync"
        case .requestReconnect: "requestReconnect"
        case .createTransaction: "createTransaction"
        case .mirrorTransfer: "mirrorTransfer"
        case .createSharedGroupFromCredit: "createSharedGroupFromCredit"
        case .archiveAccount: "archiveAccount"
        case .importFundOrders: "importFundOrders"
        case .setBrokerCashAnchor: "setBrokerCashAnchor"
        case .setCostBasisOpening: "setCostBasisOpening"
        case .setLiveSource: "setLiveSource"
        case .restoreCategories: "restoreCategories"
        case .deleteCategory: "deleteCategory"
        case .deleteValuation: "deleteValuation"
        case .restoreFundTrades: "restoreFundTrades"
        }
    }

    // Whether applying it records how to reverse it. One op that doesn't takes Undo away from
    // its whole batch, so Claude keeps these in batches of their own.
    public var isUndoable: Bool {
        switch self {
        case .categorize, .createCategory, .createRule, .applyRules, .recordValuation, .requestBankSync, .requestReconnect,
             .createTransaction, .mirrorTransfer, .archiveAccount, .importFundOrders, .setBrokerCashAnchor,
             .setCostBasisOpening, .setLiveSource: true
        default: false
        }
    }

    public var isUndoOnly: Bool {
        switch self {
        case .restoreCategories, .deleteCategory, .deleteValuation, .restoreFundTrades: true
        default: false
        }
    }

    // The Settings switch that lets this op apply without review, if any. A categorize only
    // qualifies when every row it touches is still uncategorized; the executor checks that.
    public var autoApplyKind: AutoApplyKind? {
        switch self {
        case .categorize(_, let category): category == nil ? nil : .categorizeUncategorized
        case .createCategory: .createCategory
        case .createRule: .createRule
        case .applyRules: .applyRules
        case .recordValuation: .recordValuation
        case .requestBankSync: .requestBankSync
        default: nil
        }
    }
}

public enum AutoApplyKind: String, Codable, Sendable, CaseIterable {
    case categorizeUncategorized, createCategory, createRule, applyRules, recordValuation, requestBankSync
}

// Flat JSON with an "op" discriminator: the shape Claude writes in tool calls.
extension BridgeOp: Codable {
    private enum Key: String, CodingKey {
        case op, txIds, txId, category, name, kind, parent, pattern, field, match, priority, ruleId
        case label, primaryTxId, reimbursementTxIds, groupId, accountId, asOf, marketValueEur
        case cashValueEur, notes, restores, id
        case csv, feedAccountId, manualAccountId, debitTxId, targetAccountId, sourceAccountId, direction, routeId
        case enabled, connectionIds, connectionId
        case amount, bookedAt, counterparty, sourceTxId, creditTxId, expenseTxIds, archived
        case ordersCsv, movementsCsv, heldUnits, amountEur, at, source, deleteIds
        case descriptionText = "description"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "categorize":
            self = .categorize(txIds: try c.decode([UUID].self, forKey: .txIds),
                               category: try c.decodeIfPresent(String.self, forKey: .category))
        case "createCategory":
            self = .createCategory(name: try c.decode(String.self, forKey: .name),
                                   kind: try c.decodeIfPresent(CategoryKind.self, forKey: .kind) ?? .expense,
                                   parent: try c.decodeIfPresent(String.self, forKey: .parent))
        case "createRule":
            self = .createRule(pattern: try c.decode(String.self, forKey: .pattern),
                               category: try c.decode(String.self, forKey: .category),
                               field: try c.decodeIfPresent(RuleField.self, forKey: .field) ?? .description,
                               match: try c.decodeIfPresent(RuleMatch.self, forKey: .match) ?? .contains,
                               priority: try c.decodeIfPresent(Int.self, forKey: .priority) ?? -1000)
        case "updateRule":
            self = .updateRule(ruleId: try c.decode(UUID.self, forKey: .ruleId),
                               pattern: try c.decodeIfPresent(String.self, forKey: .pattern),
                               category: try c.decodeIfPresent(String.self, forKey: .category),
                               field: try c.decodeIfPresent(RuleField.self, forKey: .field),
                               match: try c.decodeIfPresent(RuleMatch.self, forKey: .match))
        case "deleteRule":
            self = .deleteRule(ruleId: try c.decode(UUID.self, forKey: .ruleId))
        case "applyRules":
            self = .applyRules(txIds: try c.decodeIfPresent([UUID].self, forKey: .txIds))
        case "pairTransfer":
            self = .pairTransfer(txIds: try c.decode([UUID].self, forKey: .txIds))
        case "unpairTransfer":
            self = .unpairTransfer(txId: try c.decode(UUID.self, forKey: .txId))
        case "createSharedGroup":
            self = .createSharedGroup(label: try c.decode(String.self, forKey: .label),
                                      primaryTxId: try c.decode(UUID.self, forKey: .primaryTxId),
                                      reimbursementTxIds: try c.decode([UUID].self, forKey: .reimbursementTxIds))
        case "deleteSharedGroup":
            self = .deleteSharedGroup(groupId: try c.decode(UUID.self, forKey: .groupId))
        case "recordValuation":
            self = .recordValuation(accountId: try c.decode(UUID.self, forKey: .accountId),
                                    asOf: try c.decode(Date.self, forKey: .asOf),
                                    marketValueEur: try c.decode(Decimal.self, forKey: .marketValueEur),
                                    cashValueEur: try c.decodeIfPresent(Decimal.self, forKey: .cashValueEur),
                                    notes: try c.decodeIfPresent(String.self, forKey: .notes))
        case "importStatement":
            self = .importStatement(accountId: try c.decode(UUID.self, forKey: .accountId),
                                    csv: try c.decode(String.self, forKey: .csv))
        case "deleteTransactions":
            self = .deleteTransactions(txIds: try c.decode([UUID].self, forKey: .txIds))
        case "adoptFeed":
            self = .adoptFeed(feedAccountId: try c.decode(UUID.self, forKey: .feedAccountId),
                              manualAccountId: try c.decode(UUID.self, forKey: .manualAccountId))
        case "undoPensionSplit":
            self = .undoPensionSplit(debitTxId: try c.decode(UUID.self, forKey: .debitTxId))
        case "createRoute":
            self = .createRoute(pattern: try c.decode(String.self, forKey: .pattern),
                                targetAccountId: try c.decode(UUID.self, forKey: .targetAccountId),
                                sourceAccountId: try c.decodeIfPresent(UUID.self, forKey: .sourceAccountId),
                                field: try c.decodeIfPresent(RuleField.self, forKey: .field) ?? .description,
                                match: try c.decodeIfPresent(RuleMatch.self, forKey: .match) ?? .contains,
                                direction: try c.decodeIfPresent(TxDirection.self, forKey: .direction),
                                priority: try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0)
        case "updateRoute":
            self = .updateRoute(routeId: try c.decode(UUID.self, forKey: .routeId),
                                pattern: try c.decodeIfPresent(String.self, forKey: .pattern),
                                targetAccountId: try c.decodeIfPresent(UUID.self, forKey: .targetAccountId),
                                sourceAccountId: try c.decodeIfPresent(UUID.self, forKey: .sourceAccountId),
                                field: try c.decodeIfPresent(RuleField.self, forKey: .field),
                                match: try c.decodeIfPresent(RuleMatch.self, forKey: .match),
                                direction: try c.decodeIfPresent(TxDirection.self, forKey: .direction),
                                enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled))
        case "deleteRoute":
            self = .deleteRoute(routeId: try c.decode(UUID.self, forKey: .routeId))
        case "requestBankSync":
            self = .requestBankSync(connectionIds: try c.decodeIfPresent([UUID].self, forKey: .connectionIds))
        case "requestReconnect":
            self = .requestReconnect(connectionId: try c.decode(UUID.self, forKey: .connectionId))
        case "createTransaction":
            self = .createTransaction(accountId: try c.decode(UUID.self, forKey: .accountId),
                                      amount: try c.decode(Decimal.self, forKey: .amount),
                                      bookedAt: try c.decode(Date.self, forKey: .bookedAt),
                                      description: try c.decodeIfPresent(String.self, forKey: .descriptionText),
                                      counterparty: try c.decodeIfPresent(String.self, forKey: .counterparty),
                                      category: try c.decodeIfPresent(String.self, forKey: .category))
        case "mirrorTransfer":
            self = .mirrorTransfer(sourceTxId: try c.decode(UUID.self, forKey: .sourceTxId),
                                   targetAccountId: try c.decode(UUID.self, forKey: .targetAccountId))
        case "createSharedGroupFromCredit":
            self = .createSharedGroupFromCredit(label: try c.decode(String.self, forKey: .label),
                                                creditTxId: try c.decode(UUID.self, forKey: .creditTxId),
                                                expenseTxIds: try c.decode([UUID].self, forKey: .expenseTxIds))
        case "archiveAccount":
            self = .archiveAccount(accountId: try c.decode(UUID.self, forKey: .accountId),
                                   archived: try c.decodeIfPresent(Bool.self, forKey: .archived) ?? true)
        case "importFundOrders":
            self = .importFundOrders(accountId: try c.decode(UUID.self, forKey: .accountId),
                                     ordersCsv: try c.decode(String.self, forKey: .ordersCsv),
                                     movementsCsv: try c.decode(String.self, forKey: .movementsCsv),
                                     heldUnits: try c.decode([String: Decimal].self, forKey: .heldUnits))
        case "setBrokerCashAnchor":
            self = .setBrokerCashAnchor(accountId: try c.decode(UUID.self, forKey: .accountId),
                                        amountEur: try c.decodeIfPresent(Decimal.self, forKey: .amountEur),
                                        at: try c.decodeIfPresent(Date.self, forKey: .at))
        case "setCostBasisOpening":
            self = .setCostBasisOpening(accountId: try c.decode(UUID.self, forKey: .accountId),
                                        amountEur: try c.decodeIfPresent(Decimal.self, forKey: .amountEur),
                                        at: try c.decodeIfPresent(Date.self, forKey: .at))
        case "setLiveSource":
            self = .setLiveSource(accountId: try c.decode(UUID.self, forKey: .accountId),
                                  source: try c.decodeIfPresent(String.self, forKey: .source))
        case "restoreCategories":
            self = .restoreCategories(try c.decode([CategoryRestore].self, forKey: .restores))
        case "deleteCategory":
            self = .deleteCategory(id: try c.decode(UUID.self, forKey: .id))
        case "deleteValuation":
            self = .deleteValuation(id: try c.decode(UUID.self, forKey: .id))
        case "restoreFundTrades":
            self = .restoreFundTrades(deleteIds: try c.decode([UUID].self, forKey: .deleteIds),
                                      restores: try c.decode([FundTradeRestore].self, forKey: .restores))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "Unknown op \(op)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(name, forKey: .op)
        switch self {
        case .categorize(let txIds, let category):
            try c.encode(txIds, forKey: .txIds)
            try c.encodeIfPresent(category, forKey: .category)
        case .createCategory(let name, let kind, let parent):
            try c.encode(name, forKey: .name)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(parent, forKey: .parent)
        case .createRule(let pattern, let category, let field, let match, let priority):
            try c.encode(pattern, forKey: .pattern)
            try c.encode(category, forKey: .category)
            try c.encode(field, forKey: .field)
            try c.encode(match, forKey: .match)
            try c.encode(priority, forKey: .priority)
        case .updateRule(let ruleId, let pattern, let category, let field, let match):
            try c.encode(ruleId, forKey: .ruleId)
            try c.encodeIfPresent(pattern, forKey: .pattern)
            try c.encodeIfPresent(category, forKey: .category)
            try c.encodeIfPresent(field, forKey: .field)
            try c.encodeIfPresent(match, forKey: .match)
        case .deleteRule(let ruleId):
            try c.encode(ruleId, forKey: .ruleId)
        case .applyRules(let txIds):
            try c.encodeIfPresent(txIds, forKey: .txIds)
        case .pairTransfer(let txIds):
            try c.encode(txIds, forKey: .txIds)
        case .unpairTransfer(let txId):
            try c.encode(txId, forKey: .txId)
        case .createSharedGroup(let label, let primaryTxId, let reimbursementTxIds):
            try c.encode(label, forKey: .label)
            try c.encode(primaryTxId, forKey: .primaryTxId)
            try c.encode(reimbursementTxIds, forKey: .reimbursementTxIds)
        case .deleteSharedGroup(let groupId):
            try c.encode(groupId, forKey: .groupId)
        case .recordValuation(let accountId, let asOf, let market, let cash, let notes):
            try c.encode(accountId, forKey: .accountId)
            try c.encode(asOf, forKey: .asOf)
            try c.encode(market, forKey: .marketValueEur)
            try c.encodeIfPresent(cash, forKey: .cashValueEur)
            try c.encodeIfPresent(notes, forKey: .notes)
        case .importStatement(let accountId, let csv):
            try c.encode(accountId, forKey: .accountId)
            try c.encode(csv, forKey: .csv)
        case .deleteTransactions(let txIds):
            try c.encode(txIds, forKey: .txIds)
        case .adoptFeed(let feed, let manual):
            try c.encode(feed, forKey: .feedAccountId)
            try c.encode(manual, forKey: .manualAccountId)
        case .undoPensionSplit(let debitTxId):
            try c.encode(debitTxId, forKey: .debitTxId)
        case .createRoute(let pattern, let target, let source, let field, let match, let direction, let priority):
            try c.encode(pattern, forKey: .pattern)
            try c.encode(target, forKey: .targetAccountId)
            try c.encodeIfPresent(source, forKey: .sourceAccountId)
            try c.encode(field, forKey: .field)
            try c.encode(match, forKey: .match)
            try c.encodeIfPresent(direction, forKey: .direction)
            try c.encode(priority, forKey: .priority)
        case .updateRoute(let routeId, let pattern, let target, let source, let field, let match, let direction, let enabled):
            try c.encode(routeId, forKey: .routeId)
            try c.encodeIfPresent(pattern, forKey: .pattern)
            try c.encodeIfPresent(target, forKey: .targetAccountId)
            try c.encodeIfPresent(source, forKey: .sourceAccountId)
            try c.encodeIfPresent(field, forKey: .field)
            try c.encodeIfPresent(match, forKey: .match)
            try c.encodeIfPresent(direction, forKey: .direction)
            try c.encodeIfPresent(enabled, forKey: .enabled)
        case .deleteRoute(let routeId):
            try c.encode(routeId, forKey: .routeId)
        case .requestBankSync(let connectionIds):
            try c.encodeIfPresent(connectionIds, forKey: .connectionIds)
        case .requestReconnect(let connectionId):
            try c.encode(connectionId, forKey: .connectionId)
        case .createTransaction(let accountId, let amount, let bookedAt, let description, let counterparty, let category):
            try c.encode(accountId, forKey: .accountId)
            try c.encode(amount, forKey: .amount)
            try c.encode(bookedAt, forKey: .bookedAt)
            try c.encodeIfPresent(description, forKey: .descriptionText)
            try c.encodeIfPresent(counterparty, forKey: .counterparty)
            try c.encodeIfPresent(category, forKey: .category)
        case .mirrorTransfer(let source, let target):
            try c.encode(source, forKey: .sourceTxId)
            try c.encode(target, forKey: .targetAccountId)
        case .createSharedGroupFromCredit(let label, let credit, let expenses):
            try c.encode(label, forKey: .label)
            try c.encode(credit, forKey: .creditTxId)
            try c.encode(expenses, forKey: .expenseTxIds)
        case .archiveAccount(let accountId, let archived):
            try c.encode(accountId, forKey: .accountId)
            try c.encode(archived, forKey: .archived)
        case .importFundOrders(let accountId, let orders, let movements, let held):
            try c.encode(accountId, forKey: .accountId)
            try c.encode(orders, forKey: .ordersCsv)
            try c.encode(movements, forKey: .movementsCsv)
            try c.encode(held, forKey: .heldUnits)
        case .setBrokerCashAnchor(let accountId, let amount, let at), .setCostBasisOpening(let accountId, let amount, let at):
            try c.encode(accountId, forKey: .accountId)
            try c.encodeIfPresent(amount, forKey: .amountEur)
            try c.encodeIfPresent(at, forKey: .at)
        case .setLiveSource(let accountId, let source):
            try c.encode(accountId, forKey: .accountId)
            try c.encodeIfPresent(source, forKey: .source)
        case .restoreCategories(let restores):
            try c.encode(restores, forKey: .restores)
        case .deleteCategory(let id), .deleteValuation(let id):
            try c.encode(id, forKey: .id)
        case .restoreFundTrades(let deleteIds, let restores):
            try c.encode(deleteIds, forKey: .deleteIds)
            try c.encode(restores, forKey: .restores)
        }
    }
}

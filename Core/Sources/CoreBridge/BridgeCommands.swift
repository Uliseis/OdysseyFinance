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
    // Only the phone builds these, to undo an auto-applied batch. Never accepted from the inbox.
    case restoreCategories([CategoryRestore])
    case deleteCategory(id: UUID)
    case deleteValuation(id: UUID)

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
        case .restoreCategories: "restoreCategories"
        case .deleteCategory: "deleteCategory"
        case .deleteValuation: "deleteValuation"
        }
    }

    public var isUndoOnly: Bool {
        switch self {
        case .restoreCategories, .deleteCategory, .deleteValuation: true
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
        default: nil
        }
    }
}

public enum AutoApplyKind: String, Codable, Sendable, CaseIterable {
    case categorizeUncategorized, createCategory, createRule, applyRules, recordValuation
}

// Flat JSON with an "op" discriminator: the shape Claude writes in tool calls.
extension BridgeOp: Codable {
    private enum Key: String, CodingKey {
        case op, txIds, txId, category, name, kind, parent, pattern, field, match, priority, ruleId
        case label, primaryTxId, reimbursementTxIds, groupId, accountId, asOf, marketValueEur
        case cashValueEur, notes, restores, id
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
        case "restoreCategories":
            self = .restoreCategories(try c.decode([CategoryRestore].self, forKey: .restores))
        case "deleteCategory":
            self = .deleteCategory(id: try c.decode(UUID.self, forKey: .id))
        case "deleteValuation":
            self = .deleteValuation(id: try c.decode(UUID.self, forKey: .id))
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
        case .restoreCategories(let restores):
            try c.encode(restores, forKey: .restores)
        case .deleteCategory(let id), .deleteValuation(let id):
            try c.encode(id, forKey: .id)
        }
    }
}

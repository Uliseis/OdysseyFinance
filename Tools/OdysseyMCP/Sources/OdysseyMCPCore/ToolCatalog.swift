import Foundation
import MCP
import CoreBridge
import CoreModel

// The read tools. Each answers from the latest snapshot with the app's own CoreLogic and
// wraps the answer as {"asOf": <snapshot time>, "data": …} so staleness is always visible.
@MainActor
public final class ToolCatalog {
    let store: SnapshotStore
    let keys: SigningKeyStore
    let now: @Sendable () -> Date
    var drafts: [UUID: Draft] = [:]
    var files: BridgeFiles { store.files }

    public init(store: SnapshotStore, keys: SigningKeyStore = KeychainSigningKeyStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.keys = keys
        self.now = now
    }

    public nonisolated static let tools: [Tool] = readTools + changeTools

    nonisolated static let readTools: [Tool] = [
        tool("overview",
             """
             Net worth and its parts (cash, card liabilities, investments) for a space, every account's \
             balance with the rule behind it (bank balance, anchor + rows since, opening + all rows, or \
             investment valuation), bank connection health with days until consent expiry, the current \
             pay-cycle income/expense and the uncategorized count. Start here; check snapshotAgeMinutes.
             """,
             ["spaceId": uuid("Space to total; defaults to the one selected on the phone."),
              "includeArchived": bool("Also list archived accounts.")]),
        tool("query_transactions",
             """
             Search transactions, newest first. Amounts are signed (debits negative) in the account's \
             currency, amountEur in euros. Each row carries its category and who set it (bank, rule, \
             manual), transfer pairing, mirror links, shared-expense group, and for bank-fed rows the \
             bank's transaction code and creditor/debtor names. Archived and excluded accounts are left \
             out unless named in accountIds or includeExcludedAccounts is true.
             """,
             ["accountIds": .object(["type": "array", "items": ["type": "string", "format": "uuid"]]),
              "from": date("Earliest booking date, inclusive (YYYY-MM-DD or ISO 8601)."),
              "to": date("Latest booking date, inclusive; a bare date covers the whole day."),
              "category": string("Category name, case-insensitive."),
              "uncategorized": bool("Only rows that still need a category (not transfers, not in a shared group)."),
              "text": string("Case-insensitive match on description, counterparty, bank creditor/debtor or externalId."),
              "minAmount": number("Minimum absolute amount in EUR."),
              "maxAmount": number("Maximum absolute amount in EUR."),
              "direction": .object(["type": "string", "enum": ["debit", "credit"]]),
              "transfers": bool("true: only transfer legs; false: no transfer legs; omit for both."),
              "includeExcludedAccounts": bool("Include archived/excluded accounts."),
              "limit": integer("Rows to return, 1–1000 (default 100)."),
              "offset": integer("Rows to skip, for paging.")]),
        tool("monthly_flow",
             """
             Income and spending per pay cycle, oldest first, exactly as the Dashboard computes them: \
             transfers and shared-group members are skipped, a group's net counts under its primary's \
             category, a credit in a non-income category offsets spending, an uncategorized credit counts \
             as income. Recategorizing moves a credit between income and offset spending, so income − spending \
             stays put, except in a cycle whose credits outweigh its spending (spending is floored at zero). \
             Pairing transfers and mirrors do change it.
             """,
             ["months": integer("Number of cycles, default 6."),
              "spaceId": uuid("Space; defaults to the one selected on the phone.")]),
        tool("category_breakdown",
             "Spending per category (net of refunds and shared-group paybacks) for the pay cycle containing a date.",
             ["date": date("Any date in the cycle; defaults to today."),
              "spaceId": uuid("Space; defaults to the one selected on the phone.")]),
        tool("list_rules",
             """
             Categorisation rules in the order the engine tries them (priority descending, then oldest). \
             Patterns match case-insensitively; the first matching rule wins; rules never overwrite a \
             category set by hand.
             """, [:]),
        tool("list_routes",
             """
             Transfer routes: bank lines matched by pattern get a mirror leg booked on a manual account. \
             mirrorCount is how many mirrors each route created; editing or disabling a route deletes all of them.
             """, [:]),
        tool("list_categories", "Categories with kind (expense/income), parent and how many rows use each.", [:]),
        tool("transfer_candidates",
             """
             With txId: every row that transaction could be paired with as a transfer (opposite direction, \
             same amount within €0.01, same space, not a mirror or shared-group member), closest dates first. \
             Without txId: unpaired same-amount debit/credit pairs at most 3 days apart in a date window \
             (default the last 90 days). Pair only when certain.
             """,
             ["txId": uuid("Transaction to find partners for."),
              "from": date("Window start (without txId)."),
              "to": date("Window end (without txId)."),
              "limit": integer("Maximum results, default 50.")]),
        tool("payback_candidates",
             "For an expense: credits near it that could be paybacks. For a credit: expenses it could be repaying. Same space, not yet in a shared group.",
             ["txId": uuid("The expense or the credit."), "query": string("Optional text filter.")],
             required: ["txId"]),
        tool("sync_status", "Bank connections (status, consent expiry, last sync, last error) and the latest sync runs.", [:]),
        tool("snapshot_age",
             "When the phone last wrote the snapshot, and where it is. Cheap; doesn't load the data.", [:]),
    ]

    public func call(_ name: String, _ arguments: [String: Value]) async -> CallTool.Result {
        do {
            if let result = try changeTool(name, arguments) { return result }
            if name == "snapshot_age" { return try snapshotAge() }
            let replica = try store.replica()
            let args = try Arguments(arguments)
            let now = now()
            let data: any Encodable
            switch name {
            case "overview":
                data = try replica.overview(spaceId: args.uuid("spaceId"), includeArchived: args.bool("includeArchived") ?? false, now: now)
            case "query_transactions":
                data = try replica.transactions(args.decode(BridgeQueries.TransactionQuery.self))
            case "monthly_flow":
                data = try replica.monthlyFlow(months: args.int("months") ?? 6, spaceId: args.uuid("spaceId"), now: now)
            case "category_breakdown":
                data = try replica.categoryBreakdown(containing: args.date("date") ?? now, spaceId: args.uuid("spaceId"))
            case "list_rules": data = try replica.rules()
            case "list_routes": data = try replica.routes()
            case "list_categories": data = try replica.categories()
            case "transfer_candidates":
                data = try replica.transferCandidates(
                    txId: args.uuid("txId"), from: args.date("from"), to: args.date("to"), limit: args.int("limit") ?? 50)
            case "payback_candidates":
                guard let txId = try args.uuid("txId") else { throw ArgumentError("txId is required") }
                data = try replica.paybackCandidates(txId: txId, query: args.string("query") ?? "")
            case "sync_status": data = try replica.syncStatus(now: now)
            default: throw ArgumentError("Unknown tool \(name)")
            }
            return Self.result(try Self.json(Envelope(asOf: replica.snapshot.exportedAt, data: AnyEncodable(data))))
        } catch {
            return Self.result("\(error)", isError: true)
        }
    }

    private func snapshotAge() throws -> CallTool.Result {
        let url = store.files.snapshot
        guard let modified = store.files.modificationDate(url) else { throw SnapshotError.missing(url) }
        let replica = try? store.replica()
        let info = SnapshotInfo(
            path: url.path, fileModifiedAt: modified, exportedAt: replica?.snapshot.exportedAt,
            ageMinutes: replica.map { Int(now().timeIntervalSince($0.snapshot.exportedAt) / 60) },
            schemaVersion: replica?.snapshot.schemaVersion)
        return Self.result(try Self.json(info))
    }

    // MARK: - JSON out

    static func result(_ text: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
    }

    static func json(_ value: some Encodable) throws -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    struct Envelope: Encodable { let asOf: Date; let data: AnyEncodable }
    struct SnapshotInfo: Encodable {
        let path: String; let fileModifiedAt: Date; let exportedAt: Date?; let ageMinutes: Int?; let schemaVersion: Int?
    }
    struct AnyEncodable: Encodable {
        let value: any Encodable
        init(_ value: any Encodable) { self.value = value }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    // MARK: - schema helpers

    nonisolated static func tool(_ name: String, _ description: String, _ properties: [String: Value], required: [String] = []) -> Tool {
        Tool(name: name, description: description,
             inputSchema: .object([
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
             ]),
             annotations: .init(readOnlyHint: true, openWorldHint: false))
    }
    nonisolated static func string(_ d: String) -> Value { .object(["type": "string", "description": .string(d)]) }
    nonisolated static func uuid(_ d: String) -> Value { .object(["type": "string", "format": "uuid", "description": .string(d)]) }
    nonisolated static func date(_ d: String) -> Value { .object(["type": "string", "description": .string(d)]) }
    nonisolated static func bool(_ d: String) -> Value { .object(["type": "boolean", "description": .string(d)]) }
    nonisolated static func number(_ d: String) -> Value { .object(["type": "number", "description": .string(d)]) }
    nonisolated static func integer(_ d: String) -> Value { .object(["type": "integer", "description": .string(d)]) }
}

struct ArgumentError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// Tool arguments as Claude sends them. Dates accept YYYY-MM-DD (UTC) or ISO 8601; a bare
// `to` date is stretched to the end of that day so ranges read inclusively.
struct Arguments {
    let raw: [String: Value]

    init(_ raw: [String: Value]) throws {
        var normalized = raw
        if case .string(let to)? = raw["to"], to.count == 10 { normalized["to"] = .string(to + "T23:59:59Z") }
        self.raw = normalized
    }

    func string(_ key: String) -> String? { raw[key]?.stringValue }
    func bool(_ key: String) -> Bool? { raw[key]?.boolValue }
    func int(_ key: String) -> Int? { raw[key]?.intValue ?? raw[key]?.doubleValue.map { Int($0) } }
    func uuid(_ key: String) throws -> UUID? {
        guard let s = string(key) else { return nil }
        guard let id = UUID(uuidString: s) else { throw ArgumentError("\(key) is not a UUID: \(s)") }
        return id
    }
    func date(_ key: String) throws -> Date? {
        guard let s = string(key) else { return nil }
        guard let d = Self.parseDate(s) else { throw ArgumentError("\(key) is not a date: \(s)") }
        return d
    }

    func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        guard let value = raw[key] else { throw ArgumentError("\(key) is required") }
        return try Self.decoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try Self.decoder().decode(T.self, from: JSONEncoder().encode(raw))
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.parseDate(s) else { throw ArgumentError("Not a date: \(s)") }
            return date
        }
        return d
    }

    static func parseDate(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        return try? Date(s + "T00:00:00Z", strategy: .iso8601)
    }
}

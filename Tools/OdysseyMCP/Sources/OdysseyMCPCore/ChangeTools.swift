import Foundation
import MCP
import CryptoKit
import CoreBridge

// The write path: Claude drafts a batch, the server previews it on a fresh replica with the
// app's own CoreLogic, and only a submitted draft reaches the phone, signed with this Mac's key.
extension ToolCatalog {
    nonisolated static let changeTools: [Tool] = [
        Tool(name: "propose_changes", description: """
            Draft a batch of changes and preview it: each op runs through the app's CoreLogic on a \
            private copy of the snapshot, so the preview shows exactly what applying would do (rows \
            touched, before → after, and the effect on net worth, this cycle's income/spending and the \
            uncategorized count). Nothing reaches the phone until submit_changes. Read odyssey://policy \
            first. Ops run in order; a category created earlier in the batch can be used later.
            Ops (field "op"):
            - categorize {txIds, category} (category omitted = uncategorize; sets the category by hand)
            - createCategory {name, kind: expense|income|reimbursement|refund (default expense), parent?}
            - createRule {pattern, category, field: description|counterparty (default description), \
            match: contains|equals|startsWith|endsWith (default contains), priority (default -1000)}
            - updateRule {ruleId, pattern?, category?, field?, match?} · deleteRule {ruleId}
            - applyRules {txIds?} (re-run rules; omitted = every row not categorized by hand)
            - pairTransfer {txIds: [debit, credit]} · unpairTransfer {txId}
            - createSharedGroup {label, primaryTxId, reimbursementTxIds} · deleteSharedGroup {groupId}
            - recordValuation {accountId, asOf, marketValueEur, cashValueEur?, notes?}
            - importStatement {accountId, csvPath (a file on this Mac) or csv} (Revolut or Amex CSV into a manual \
            account: new rows, quick-adds matched, duplicates skipped; unmatched quick-adds are listed)
            - deleteTransactions {txIds} (transfer legs must be unpaired first)
            - adoptFeed {feedAccountId, manualAccountId} (fold a discovered bank account into the manual one)
            - undoPensionSplit {debitTxId} (the internal-transfer leg of an automatic pension split)
            - createRoute {pattern, targetAccountId, sourceAccountId?, field?, match?, direction: debit|credit?, priority?} · \
            updateRoute {routeId, pattern?, targetAccountId?, sourceAccountId?, field?, match?, direction?, enabled?} · \
            deleteRoute {routeId} (editing, disabling or deleting a route deletes its mirrors; the preview lists them)
            - requestBankSync {connectionIds?} (the phone syncs those banks, or all, after the batch) · \
            requestReconnect {connectionId} (opens that bank's screen so the user can renew consent)
            - createTransaction {accountId, amount (signed: debits negative), bookedAt, description?, counterparty?, \
            category?} (manual accounts only; recorded like a quick-add, so a later statement import matches it)
            - mirrorTransfer {sourceTxId, targetAccountId} (a one-off mirror leg on a manual account, no route)
            - createSharedGroupFromCredit {label, creditTxId, expenseTxIds} (a payback that covers several expenses)
            - archiveAccount {accountId, archived (default true)}
            categorize marks rows as set by hand, so rules never refile them later. For a merchant that recurs, \
            prefer createRule plus applyRules; keep categorize for one-off rows.
            Categories are referenced by name, records by id from the read tools.
            Undo: categorize, createCategory, createRule, applyRules, recordValuation, createTransaction, \
            mirrorTransfer, archiveAccount and the two requests can be undone from the phone. Everything else can't, and one such op takes Undo away from its whole batch, so \
            send those in a batch of their own. The preview's "undoable" says which you have.
            """,
             inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "summary": string("One or two sentences the user reads on the phone: what and why."),
                    "ops": .object(["type": "array", "minItems": 1, "items": .object([
                        "type": "object", "required": ["op"],
                        "properties": .object([
                            "op": .object(["type": "string", "enum": [
                                "categorize", "createCategory", "createRule", "updateRule", "deleteRule", "applyRules",
                                "pairTransfer", "unpairTransfer", "createSharedGroup", "deleteSharedGroup", "recordValuation",
                                "importStatement", "deleteTransactions", "adoptFeed", "undoPensionSplit", "createRoute",
                                "updateRoute", "deleteRoute", "requestBankSync", "requestReconnect", "createTransaction",
                                "mirrorTransfer", "createSharedGroupFromCredit", "archiveAccount"]]),
                            "txIds": .object(["type": "array", "items": ["type": "string", "format": "uuid"]]),
                            "txId": uuid("Transaction id."), "category": string("Category name."),
                            "name": string("New category name."), "kind": string("Category kind."),
                            "parent": string("Parent category name."), "pattern": string("Rule pattern."),
                            "field": string("description or counterparty."), "match": string("contains, equals, startsWith or endsWith."),
                            "priority": integer("Rule priority; higher runs first."), "ruleId": uuid("Rule id."),
                            "label": string("Shared group label."), "primaryTxId": uuid("The expense."),
                            "reimbursementTxIds": .object(["type": "array", "items": ["type": "string", "format": "uuid"]]),
                            "groupId": uuid("Shared group id."), "accountId": uuid("Investment account id."),
                            "asOf": date("Valuation date."), "marketValueEur": number("Market value in EUR."),
                            "cashValueEur": number("Cash held in EUR."), "notes": string("Valuation note."),
                            "csvPath": string("Statement CSV on this Mac; the server reads it."),
                            "csv": string("Statement CSV text, when there's no file."),
                            "feedAccountId": uuid("Discovered bank account to fold in."),
                            "manualAccountId": uuid("Manual account that takes over the feed."),
                            "debitTxId": uuid("Pension split leg."), "routeId": uuid("Route id."),
                            "targetAccountId": uuid("Manual account mirrors are booked on."),
                            "sourceAccountId": uuid("Bank account the route watches."),
                            "direction": string("debit or credit."), "enabled": bool("Route on or off."),
                            "connectionIds": .object(["type": "array", "items": ["type": "string", "format": "uuid"]]),
                            "connectionId": uuid("Bank connection id."),
                            "amount": number("Signed amount in the account's currency; debits negative."),
                            "bookedAt": date("Booking date (YYYY-MM-DD or ISO 8601)."),
                            "description": string("Row description."), "counterparty": string("Counterparty."),
                            "sourceTxId": uuid("Bank row to mirror."), "creditTxId": uuid("The payback credit."),
                            "expenseTxIds": .object(["type": "array", "items": ["type": "string", "format": "uuid"]]),
                            "archived": bool("Archive (true) or restore (false)."),
                        ]),
                    ])]),
                ]),
                "required": ["summary", "ops"],
             ]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "submit_changes", description: """
            Send a previewed draft to the phone, signed with this Mac's key. The phone shows it for review \
            with Face ID, unless every op is in a safe set the user switched on for auto-apply and this Mac \
            is paired. Show the user the preview and get their go-ahead before submitting.
            """,
             inputSchema: .object(["type": "object", "properties": .object(["draftId": uuid("From propose_changes.")]),
                                   "required": ["draftId"]]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "change_status", description: """
            With batchId: whether the phone applied, partly applied, rejected or hasn't seen a submitted batch, \
            with each op's outcome. Without: pending batches and the latest decisions.
            """,
             inputSchema: .object(["type": "object", "properties": .object(["batchId": uuid("From submit_changes.")])]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "withdraw_changes", description: "Take back a submitted batch the phone hasn't decided yet.",
             inputSchema: .object(["type": "object", "properties": .object(["batchId": uuid("From submit_changes.")]),
                                   "required": ["batchId"]]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "pairing_info", description: """
            This Mac's signing-key fingerprint and whether the phone has paired it, accepts changes and which \
            auto-apply switches are on. Publishes the public key so the phone can pair: the user opens \
            Settings → Claude → Pair a Mac and checks the fingerprint matches.
            """,
             inputSchema: .object(["type": "object", "properties": .object([:])]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
    ]

    func changeTool(_ name: String, _ arguments: [String: Value]) throws -> CallTool.Result? {
        switch name {
        case "propose_changes": return try propose(Arguments(arguments))
        case "submit_changes": return try submit(Arguments(arguments))
        case "change_status": return try status(Arguments(arguments))
        case "withdraw_changes": return try withdraw(Arguments(arguments))
        case "pairing_info": return try pairing()
        default: return nil
        }
    }

    private func propose(_ args: Arguments) throws -> CallTool.Result {
        guard let summary = args.string("summary")?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            throw ArgumentError("summary is required: what the batch does and why, for the review sheet")
        }
        let ops = try Self.inlineStatements(args).decode([BridgeOp].self, key: "ops")
        guard !ops.isEmpty else { throw ArgumentError("ops is empty") }
        if let op = ops.first(where: \.isUndoOnly) { throw ArgumentError("\(op.name) isn't available to Claude") }

        let base = try store.replica()
        let batch = BridgeBatch(createdAt: now(), summary: summary, basedOn: base.snapshot.exportedAt, ops: ops)
        // The cached replica answers the read tools; a preview mutates its copy, so build a new one.
        let preview = try BridgeReplica(base.snapshot).preview(batch, now: now())
        drafts[batch.id] = Draft(batch: batch, autoApplyKinds: preview.outcome.autoApplyKinds)
        return Self.result(try Self.json(Proposal(
            draftId: batch.id, asOf: base.snapshot.exportedAt, before: preview.before, after: preview.after,
            monthsChanged: preview.months, undoable: preview.outcome.undo != nil, ops: preview.outcome.ops.map(OpView.init), onPhone: try expectation(preview.outcome.autoApplyKinds, base.snapshot))))
    }

    private func submit(_ args: Arguments) throws -> CallTool.Result {
        guard let draftId = try args.uuid("draftId") else { throw ArgumentError("draftId is required") }
        guard let draft = drafts[draftId] else {
            throw ArgumentError("No draft \(draftId). Drafts last until the server restarts; propose the changes again.")
        }
        let batch = draft.batch
        let key = try keys.loadOrCreate()
        try publishKey(key)
        let envelope = try BridgeSigning.seal(batch, with: key)
        try files.write(BridgeCoding.encoder().encode(envelope), to: files.inboxFile(batch.id))
        drafts[draftId] = nil
        let snapshot = try? store.replica().snapshot
        let expected = try snapshot.map { snapshot in
            try expectation(draft.autoApplyKinds, snapshot)
        } ?? "The phone decides when the app next opens."
        return Self.result(try Self.json(Submitted(
            batchId: batch.id, file: files.inboxFile(batch.id).path, onPhone: expected,
            next: "Ask the user to open Odyssey Finance on the iPhone (iCloud can take a few minutes to deliver the batch, and again to bring back the result), then call change_status with this batchId.")))
    }

    private func status(_ args: Arguments) throws -> CallTool.Result {
        if let id = try args.uuid("batchId") {
            if files.exists(files.resultFile(id)) {
                return Self.result(try Self.json(try readResult(files.resultFile(id))))
            }
            let state = files.exists(files.inboxFile(id)) ? "pending: the phone hasn't opened it yet" : "unknown batch"
            return Self.result(try Self.json(["batchId": id.uuidString, "status": state]))
        }
        let pending = files.list(files.inbox).compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .filter { !files.exists(files.resultFile($0)) }
        let recent = files.list(files.results).compactMap { try? readResult($0) }
            .sorted { $0.decidedAt > $1.decidedAt }.prefix(10).map(ResultLine.init)
        return Self.result(try Self.json(StatusList(pending: pending, recent: Array(recent))))
    }

    private func withdraw(_ args: Arguments) throws -> CallTool.Result {
        guard let id = try args.uuid("batchId") else { throw ArgumentError("batchId is required") }
        guard !files.exists(files.resultFile(id)) else { throw ArgumentError("The phone already decided \(id)") }
        guard files.exists(files.inboxFile(id)) else { throw ArgumentError("\(id) isn't pending") }
        try files.remove(files.inboxFile(id))
        return Self.result(try Self.json(["batchId": id.uuidString, "status": "withdrawn"]))
    }

    private func pairing() throws -> CallTool.Result {
        let key = try keys.loadOrCreate()
        try publishKey(key)
        let claude = (try? store.replica().snapshot.appState.claude) ?? nil
        let keyId = BridgeSigning.keyId(key.publicKey)
        return Self.result(try Self.json(Pairing(
            keyId: keyId, fingerprint: BridgeSigning.fingerprint(key.publicKey), label: macLabel,
            pairedOnPhone: claude?.trustedKeyIds.contains(keyId) ?? false,
            phoneAcceptsChanges: claude?.acceptsChanges ?? false,
            autoApply: claude?.autoApply ?? [],
            howToPair: "On the iPhone: Settings → Claude → Pair a Mac. Check the fingerprint shown there matches, then confirm with Face ID.")))
    }

    // MARK: - helpers

    // A statement travels inside the batch; Claude names the file and the server reads it.
    static func inlineStatements(_ args: Arguments) throws -> Arguments {
        guard case .array(let ops)? = args.raw["ops"] else { return args }
        var raw = args.raw
        raw["ops"] = .array(try ops.map { op in
            guard case .object(var fields) = op, case .string(let path)? = fields["csvPath"] else { return op }
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ArgumentError("Can't read the statement at \(path)")
            }
            fields["csv"] = .string(text)
            fields["csvPath"] = nil
            return .object(fields)
        })
        return try Arguments(raw)
    }

    private func publishKey(_ key: P256.Signing.PrivateKey) throws {
        let keyId = BridgeSigning.keyId(key.publicKey)
        guard !files.exists(files.keyFile(keyId)) else { return }
        try files.write(BridgeCoding.encoder().encode(BridgeSigning.publish(key, label: macLabel, now: now())),
                        to: files.keyFile(keyId))
    }

    private func readResult(_ url: URL) throws -> BridgeResult {
        try BridgeCoding.decoder().decode(BridgeResult.self, from: files.read(url))
    }

    // What the phone will do with this batch, given the settings it last reported.
    private func expectation(_ kinds: [AutoApplyKind]?, _ snapshot: BridgeSnapshot) throws -> String {
        guard let claude = snapshot.appState.claude, claude.acceptsChanges else {
            return "The phone doesn't accept changes yet: the user turns on Settings → Claude → Accept changes from Claude."
        }
        let paired = claude.trustedKeyIds.contains(BridgeSigning.keyId(try keys.loadOrCreate().publicKey))
        guard let kinds else { return "Needs review and Face ID on the phone." }
        let missing = kinds.filter { !claude.autoApply.contains($0) }
        if paired && missing.isEmpty { return "Applies automatically the next time the app opens or syncs." }
        var why: [String] = []
        if !paired { why.append("this Mac isn't paired (see pairing_info)") }
        if !missing.isEmpty { why.append("auto-apply is off for \(missing.map(\.rawValue).joined(separator: ", "))") }
        return "Needs review and Face ID on the phone: " + why.joined(separator: "; ") + "."
    }

    private var macLabel: String { Host.current().localizedName ?? "Mac" }

    struct Draft { let batch: BridgeBatch; let autoApplyKinds: [AutoApplyKind]? }
    struct Proposal: Encodable {
        let draftId: UUID; let asOf: Date; let before: BridgeEffect; let after: BridgeEffect
        let monthsChanged: [MonthChange]; let undoable: Bool; let ops: [OpView]; let onPhone: String
    }
    struct OpView: Encodable {
        let index: Int; let op: String; let status: OpOutcome.Status; let message: String
        let changes: [BridgeChange]; let moreChanges: Int?
        init(_ o: OpOutcome) {
            index = o.index; op = o.op; status = o.status; message = o.message
            changes = Array(o.changes.prefix(25))
            moreChanges = o.changes.count > 25 ? o.changes.count - 25 : nil
        }
    }
    struct Submitted: Encodable { let batchId: UUID; let file: String; let onPhone: String; let next: String }
    struct StatusList: Encodable { let pending: [UUID]; let recent: [ResultLine] }
    struct ResultLine: Encodable {
        let batchId: UUID; let summary: String; let status: BridgeResult.Status; let decidedBy: BridgeResult.Decider
        let decidedAt: Date; let applied: Int; let failed: Int; let undone: Bool
        init(_ r: BridgeResult) {
            batchId = r.batchId; summary = r.summary; status = r.status; decidedBy = r.decidedBy; decidedAt = r.decidedAt
            applied = r.outcome?.appliedCount ?? 0; failed = r.outcome?.failedCount ?? 0; undone = r.undoneAt != nil
        }
    }
    struct Pairing: Encodable {
        let keyId: String; let fingerprint: String; let label: String; let pairedOnPhone: Bool
        let phoneAcceptsChanges: Bool; let autoApply: [AutoApplyKind]; let howToPair: String
    }
}

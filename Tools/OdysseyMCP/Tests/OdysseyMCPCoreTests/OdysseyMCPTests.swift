import XCTest
import Foundation
import SwiftData
import MCP
import CryptoKit
@testable import OdysseyMCPCore
@testable import CoreBridge
@testable import CoreLogic
@testable import CoreModel

// Synthetic data only: the repository is public.
@MainActor
final class OdysseyMCPTests: XCTestCase {
    nonisolated static let now = Date(timeIntervalSince1970: 1_773_144_000) // 2026-03-10 12:00 UTC

    private var dir: URL!
    private let key = P256.Signing.PrivateKey()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "odyssey-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeSnapshot(extraRow: Bool = false, claude: BridgeAppState.Claude? = nil) throws {
        let schema = Schema(CoreModelSchema.allTypes)
        let ctx = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
        let space = AccountSpace(name: "Personal", isDefault: true)
        let group = AccountGroup(name: "Cash", kind: .cash)
        ctx.insert(space); ctx.insert(group)
        let account = Account(group: group, space: space, externalId: "a", type: .bank, institution: "Example",
                              name: "Checking", currency: "EUR", manualOpeningBalance: 1000)
        ctx.insert(account)
        let groceries = CoreModel.Category(name: "Groceries")
        ctx.insert(groceries)
        func row(_ amount: Decimal, _ day: Double, _ text: String, _ category: CoreModel.Category? = nil) {
            ctx.insert(Transaction(
                account: account, externalId: UUID().uuidString, bookedAt: Self.now.addingTimeInterval(day * 86_400),
                amount: amount, currency: "EUR", amountEur: amount, direction: amount < 0 ? .debit : .credit,
                description: text, category: category))
        }
        row(-50, -2, "SAMPLE MARKET", groceries)
        row(-20, -1, "UNKNOWN SHOP")
        if extraRow { row(-5, 0, "LATE ROW") }
        try ctx.save()
        let snapshot = try BridgeExport.make(in: ctx, appState: .init(claude: claude), redact: true, now: Self.now)
        try BridgeCoding.encoder().encode(snapshot).write(to: dir.appending(path: "snapshot.json"))
    }

    private func catalog() -> ToolCatalog {
        ToolCatalog(store: SnapshotStore(files: BridgeFiles(root: dir)), keys: EphemeralSigningKeyStore(key: key),
                    now: { OdysseyMCPTests.now })
    }

    private func json(_ result: CallTool.Result) throws -> [String: Any] {
        XCTAssertNotEqual(result.isError, true, "\(result.content)")
        guard case .text(let text, _, _)? = result.content.first else { XCTFail("no text"); return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func errorText(_ result: CallTool.Result) -> String {
        XCTAssertEqual(result.isError, true)
        guard case .text(let text, _, _)? = result.content.first else { return "" }
        return text
    }

    private func uncategorizedId(_ c: ToolCatalog) async throws -> String {
        let out = try json(await c.call("query_transactions", ["uncategorized": true]))
        let rows = try XCTUnwrap((out["data"] as? [String: Any])?["rows"] as? [[String: Any]])
        return try XCTUnwrap(rows.first?["id"] as? String)
    }

    private func proposeShopping(_ c: ToolCatalog) async throws -> [String: Any] {
        let id = try await uncategorizedId(c)
        return try json(await c.call("propose_changes", [
            "summary": "File the unknown shop under Shopping",
            "ops": [["op": "createCategory", "name": "Shopping"], ["op": "categorize", "txIds": [.string(id)], "category": "Shopping"]],
        ]))
    }

    func test_onlyTheChangeToolsWrite_andNamesAreUnique() {
        XCTAssertEqual(Set(ToolCatalog.tools.map(\.name)).count, ToolCatalog.tools.count)
        let writers = Set(ToolCatalog.tools.filter { $0.annotations.readOnlyHint != true }.map(\.name))
        XCTAssertEqual(writers, ["submit_changes", "withdraw_changes", "pairing_info"])
    }

    func test_proposeShowsWhatApplyingWouldDo_andWritesNothing() async throws {
        try writeSnapshot()
        let c = catalog()
        let out = try await proposeShopping(c)
        XCTAssertNotNil(out["draftId"] as? String)
        XCTAssertEqual((out["ops"] as? [[String: Any]])?.compactMap { $0["status"] as? String }, ["applied", "applied"])
        XCTAssertEqual((out["before"] as? [String: Any])?["uncategorized"] as? Int, 1)
        XCTAssertEqual((out["after"] as? [String: Any])?["uncategorized"] as? Int, 0)
        XCTAssertTrue((out["onPhone"] as? String)?.contains("doesn't accept changes") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "inbox").path))
        // The read tools still answer from the untouched snapshot.
        let overview = try json(await c.call("overview", [:]))
        XCTAssertEqual((overview["data"] as? [String: Any])?["uncategorizedCount"] as? Int, 1)
    }

    func test_submitWritesABatchSignedWithThisMacsKey() async throws {
        try writeSnapshot()
        let c = catalog()
        let proposal = try await proposeShopping(c)
        let draftId = try XCTUnwrap(proposal["draftId"] as? String)
        let submitted = try json(await c.call("submit_changes", ["draftId": .string(draftId)]))
        let batchId = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(submitted["batchId"] as? String)))

        let envelope = try BridgeCoding.decoder().decode(
            BridgeEnvelope.self, from: Data(contentsOf: dir.appending(path: "inbox/\(batchId.uuidString).json")))
        let opened = try BridgeSigning.open(envelope, trusted: [BridgeSigning.keyId(key.publicKey): key.publicKey])
        XCTAssertEqual(opened.sender, .verified(keyId: BridgeSigning.keyId(key.publicKey)))
        XCTAssertEqual(opened.batch.ops.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "keys/\(BridgeSigning.keyId(key.publicKey)).json").path))

        let again = await c.call("submit_changes", ["draftId": .string(draftId)])
        XCTAssertTrue(errorText(again).contains("No draft"))
    }

    func test_statusFollowsTheBatch_andOnlyPendingOnesCanBeWithdrawn() async throws {
        try writeSnapshot()
        let c = catalog()
        func submit() async throws -> String {
            let proposal = try await proposeShopping(c)
            let draftId = try XCTUnwrap(proposal["draftId"] as? String)
            let submitted = try json(await c.call("submit_changes", ["draftId": .string(draftId)]))
            return try XCTUnwrap(submitted["batchId"] as? String)
        }
        let first = try await submit()
        let pending = try json(await c.call("change_status", ["batchId": .string(first)]))
        XCTAssertTrue((pending["status"] as? String)?.hasPrefix("pending") ?? false)
        let withdrawn = try json(await c.call("withdraw_changes", ["batchId": .string(first)]))
        XCTAssertEqual(withdrawn["status"] as? String, "withdrawn")
        let gone = try json(await c.call("change_status", ["batchId": .string(first)]))
        XCTAssertEqual(gone["status"] as? String, "unknown batch")

        let second = try await submit()
        let result = BridgeResult(batchId: UUID(uuidString: second)!, summary: "Shopping", status: .applied,
                                  decidedAt: Self.now, decidedBy: .user, verified: true,
                                  outcome: BatchOutcome(ops: [], undo: nil, autoApplyKinds: nil))
        try FileManager.default.createDirectory(at: dir.appending(path: "results"), withIntermediateDirectories: true)
        try BridgeCoding.encoder().encode(result).write(to: dir.appending(path: "results/\(second).json"))
        let decided = try json(await c.call("change_status", ["batchId": .string(second)]))
        XCTAssertEqual(decided["status"] as? String, "applied")
        let list = try json(await c.call("change_status", [:]))
        XCTAssertEqual((list["recent"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((list["pending"] as? [Any])?.count, 0)
        let late = await c.call("withdraw_changes", ["batchId": .string(second)])
        XCTAssertTrue(errorText(late).contains("already decided"))
    }

    func test_undoOpsAreRefused_andAFailingOpShowsInThePreview() async throws {
        try writeSnapshot()
        let c = catalog()
        let refused = await c.call("propose_changes", [
            "summary": "x", "ops": [["op": "deleteCategory", "id": .string(UUID().uuidString)]]])
        XCTAssertTrue(errorText(refused).contains("isn't available"))

        let id = try await uncategorizedId(c)
        let out = try json(await c.call("propose_changes", [
            "summary": "x", "ops": [["op": "categorize", "txIds": [.string(id)], "category": "Nonexistent"]]]))
        XCTAssertEqual((out["ops"] as? [[String: Any]])?.first?["status"] as? String, "failed")
        XCTAssertTrue((out["onPhone"] as? String)?.contains("doesn't accept") ?? false)
    }

    func test_aStatementFileOnTheMac_travelsInsideTheBatch() async throws {
        try writeSnapshot()
        let c = catalog()
        let overview = try json(await c.call("overview", [:]))
        let accountId = try XCTUnwrap(((overview["data"] as? [String: Any])?["accounts"] as? [[String: Any]])?.first?["id"] as? String)
        let csv = dir.appending(path: "statement.csv")
        try """
        Type,Started Date,Completed Date,Description,Amount,Fee,Balance
        CARD_PAYMENT,2026-03-02 12:00:00,2026-03-03 10:00:00,SAMPLE CAFE,-6.50,0.00,-6.50
        CARD_PAYMENT,2026-03-04 18:00:00,2026-03-05 10:00:00,SAMPLE BOOKSHOP,-20.00,0.00,-26.50
        """.write(to: csv, atomically: true, encoding: .utf8)

        let out = try json(await c.call("propose_changes", [
            "summary": "Import the March statement",
            "ops": [["op": "importStatement", "accountId": .string(accountId), "csvPath": .string(csv.path)]]]))
        let op = try XCTUnwrap((out["ops"] as? [[String: Any]])?.first)
        XCTAssertEqual(op["status"] as? String, "applied", "\(op)")
        XCTAssertEqual((op["changes"] as? [[String: Any]])?.filter { $0["after"] as? String == "new row" }.count, 2)

        let missing = await c.call("propose_changes", [
            "summary": "x", "ops": [["op": "importStatement", "accountId": .string(accountId), "csvPath": "/nonexistent.csv"]]])
        XCTAssertTrue(errorText(missing).contains("Can't read the statement"))
    }

    func test_whatThePhoneWillDo_followsItsSettingsAndPairing() async throws {
        let keyId = BridgeSigning.keyId(key.publicKey)
        try writeSnapshot(claude: .init(acceptsChanges: true, trustedKeyIds: [keyId],
                                        autoApply: [.createCategory, .categorizeUncategorized]))
        let paired = try await proposeShopping(catalog())["onPhone"] as? String ?? ""
        XCTAssertTrue(paired.hasPrefix("Applies automatically"), paired)

        try writeSnapshot(claude: .init(acceptsChanges: true, trustedKeyIds: [], autoApply: [.createCategory]))
        let unpaired = try await proposeShopping(catalog())["onPhone"] as? String ?? ""
        XCTAssertTrue(unpaired.contains("isn't paired") && unpaired.contains("categorizeUncategorized"), unpaired)

        let pairing = try json(await catalog().call("pairing_info", [:]))
        XCTAssertEqual(pairing["keyId"] as? String, keyId)
        XCTAssertEqual(pairing["pairedOnPhone"] as? Bool, false)
    }

    func test_overview_answersFromTheSnapshot_withItsTimestamp() async throws {
        try writeSnapshot()
        let out = try json(await catalog().call("overview", [:]))
        XCTAssertNotNil(out["asOf"])
        let data = try XCTUnwrap(out["data"] as? [String: Any])
        XCTAssertEqual(data["netWorth"] as? Double, 930)
        XCTAssertEqual(data["uncategorizedCount"] as? Int, 1)
    }

    func test_queryTransactions_bareToDateCoversTheWholeDay() async throws {
        try writeSnapshot()
        let dayOfLastRow = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-86_400)).prefix(10)
        let out = try json(await catalog().call("query_transactions", ["to": .string(String(dayOfLastRow))]))
        let data = try XCTUnwrap(out["data"] as? [String: Any])
        XCTAssertEqual(data["total"] as? Int, 2)
        let uncategorized = try json(await catalog().call("query_transactions", ["uncategorized": true]))
        XCTAssertEqual((uncategorized["data"] as? [String: Any])?["total"] as? Int, 1)
    }

    func test_newSnapshotOnDisk_isPickedUp() async throws {
        try writeSnapshot()
        let c = catalog()
        let before = try json(await c.call("query_transactions", [:]))
        try await Task.sleep(for: .milliseconds(1100)) // file timestamps have one-second resolution on some volumes
        try writeSnapshot(extraRow: true)
        let after = try json(await c.call("query_transactions", [:]))
        XCTAssertEqual((before["data"] as? [String: Any])?["total"] as? Int, 2)
        XCTAssertEqual((after["data"] as? [String: Any])?["total"] as? Int, 3)
    }

    func test_errorsAreReadable() async throws {
        let missing = await catalog().call("overview", [:])
        XCTAssertEqual(missing.isError, true)
        guard case .text(let text, _, _)? = missing.content.first else { return XCTFail() }
        XCTAssertTrue(text.contains("Open Odyssey Finance on the iPhone"))

        try writeSnapshot()
        let bad = await catalog().call("payback_candidates", ["txId": "not-a-uuid"])
        XCTAssertEqual(bad.isError, true)
    }

    // The real binary over stdio, the way Claude Code talks to it.
    func test_stdioServer_listsToolsAndAnswersACall() async throws {
        try writeSnapshot()
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "OdysseyMCP")
        let process = Process()
        process.executableURL = binary
        process.environment = ["ODYSSEY_BRIDGE_DIR": dir.path, "ODYSSEY_BRIDGE_KEY": "ephemeral"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }

        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"overview","arguments":{}}}"#,
        ]
        for m in messages { input.fileHandleForWriting.write(Data((m + "\n").utf8)) }

        var buffer = Data()
        var responses: [Int: [String: Any]] = [:]
        let deadline = Date().addingTimeInterval(20)
        while responses[3] == nil, Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = obj["id"] as? Int {
                    responses[id] = obj
                }
            }
        }
        let server = (responses[1]?["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        XCTAssertEqual(server?["name"] as? String, "odyssey-finance")
        let tools = ((responses[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(tools?.count, ToolCatalog.tools.count)
        let call = responses[3]?["result"] as? [String: Any]
        XCTAssertNotEqual(call?["isError"] as? Bool, true)
        let text = ((call?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("\"netWorth\":930"), text)
    }
}

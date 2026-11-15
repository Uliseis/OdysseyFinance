import XCTest
import Foundation
import SwiftData
import MCP
@testable import OdysseyMCPCore
@testable import CoreBridge
@testable import CoreLogic
@testable import CoreModel

// Synthetic data only: the repository is public.
@MainActor
final class OdysseyMCPTests: XCTestCase {
    nonisolated static let now = Date(timeIntervalSince1970: 1_773_144_000) // 2026-03-10 12:00 UTC

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "odyssey-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeSnapshot(extraRow: Bool = false) throws {
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
        let snapshot = try BridgeExport.make(in: ctx, appState: .init(), redact: true, now: Self.now)
        try BridgeCoding.encoder().encode(snapshot).write(to: dir.appending(path: "snapshot.json"))
    }

    private func catalog() -> ToolCatalog {
        ToolCatalog(store: SnapshotStore(files: BridgeFiles(root: dir)), now: { OdysseyMCPTests.now })
    }

    private func json(_ result: CallTool.Result) throws -> [String: Any] {
        XCTAssertNotEqual(result.isError, true, "\(result.content)")
        guard case .text(let text, _, _)? = result.content.first else { XCTFail("no text"); return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func test_everyToolIsReadOnly_andNamesAreUnique() {
        XCTAssertEqual(Set(ToolCatalog.tools.map(\.name)).count, ToolCatalog.tools.count)
        XCTAssertTrue(ToolCatalog.tools.allSatisfy { $0.annotations.readOnlyHint == true })
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
        process.environment = ["ODYSSEY_BRIDGE_DIR": dir.path]
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

import Foundation
import MCP

public enum OdysseyServer {
    static let policyURI = "odyssey://policy"

    static let instructions = """
        Odyssey Finance is the user's personal finance app on their iPhone. These tools read a snapshot \
        the phone writes to iCloud Drive whenever the app is opened or syncs its banks, so data can be \
        stale: every answer carries `asOf`, and overview reports snapshotAgeMinutes. If it's old, ask the \
        user to open the app. Amounts are EUR unless a currency says otherwise; debits are negative. \
        Before categorizing or pairing anything, read the odyssey://policy resource and follow it.
        To change data: propose_changes previews a batch on a private copy, you show the user the \
        preview, and submit_changes sends it to the phone, where the user approves it with Face ID \
        (or it auto-applies if they allowed that kind of change). change_status reports the outcome. \
        Never submit without the user's go-ahead in this conversation.
        """

    public static func run(files: BridgeFiles = .fromEnvironment()) async throws {
        // ODYSSEY_BRIDGE_KEY=ephemeral keeps tests out of the login Keychain.
        let keys: SigningKeyStore = ProcessInfo.processInfo.environment["ODYSSEY_BRIDGE_KEY"] == "ephemeral"
            ? EphemeralSigningKeyStore() : KeychainSigningKeyStore()
        let catalog = await ToolCatalog(store: SnapshotStore(files: files), keys: keys)
        let server = Server(
            name: "odyssey-finance", version: "0.1.0", instructions: instructions,
            capabilities: .init(prompts: .init(), resources: .init(), tools: .init()))

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.tools) }
        await server.withMethodHandler(CallTool.self) { params in
            await catalog.call(params.name, params.arguments ?? [:])
        }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [Resource(
                name: "Categorisation policy", uri: policyURI,
                description: "How the user wants transactions categorised and paired.", mimeType: "text/markdown")],
                  nextCursor: nil)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            guard params.uri == policyURI else { throw MCPError.invalidParams("Unknown resource \(params.uri)") }
            return .init(contents: [.text(policy(files), uri: policyURI, mimeType: "text/markdown")])
        }
        await server.withMethodHandler(ListPrompts.self) { _ in
            .init(prompts: [Prompt(name: "odyssey-policy", description: "Load the user's categorisation policy.")],
                  nextCursor: nil)
        }
        await server.withMethodHandler(GetPrompt.self) { params in
            guard params.name == "odyssey-policy" else { throw MCPError.invalidParams("Unknown prompt \(params.name)") }
            return .init(description: "Categorisation policy",
                         messages: [.user(.text(text: "Follow this policy when working on Odyssey Finance data:\n\n" + policy(files)))])
        }

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    static func policy(_ files: BridgeFiles) -> String {
        (try? files.read(files.policy)).map { String(decoding: $0, as: UTF8.self) }
            ?? "No policy yet. Write one to \(files.policy.path) (it stays out of git)."
    }
}

import Foundation
import SwiftData
import CoreModel
import CoreLogic
import CoreBridge

// Files shared with Claude's MCP server on the Mac through the app's iCloud Drive container
// (docs/decisions.md D13). The Mac sees them under
// ~/Library/Mobile Documents/iCloud~com~uliseis~odysseyfinance/bridge/.
enum ClaudeBridge {
    static let containerId = "iCloud.com.uliseis.odysseyfinance"
    @MainActor private static var lastExport = Date.distantPast

    // nil when iCloud Drive is off. The container lookup can block, so it never runs on main.
    static func root() async -> URL? {
        #if DEBUG
        // Simulator runs point this at a local folder instead of iCloud.
        if let dir = ProcessInfo.processInfo.environment["OFBRIDGE_DIR"] {
            return URL(filePath: dir, directoryHint: .isDirectory)
        }
        #endif
        return await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: containerId)?
                .appending(path: "bridge", directoryHint: .isDirectory)
        }.value
    }

    // On foreground and after a sync: apply or queue Claude's batches, then publish the data.
    @MainActor
    static func exchange(_ ctx: ModelContext) async {
        await ClaudeInbox.shared.refresh(ctx)
        await exportSnapshot(ctx)
    }

    // Calls within 30 seconds of the last export are dropped (a foreground usually triggers
    // more than one); force is for right after a batch changed the data.
    @MainActor
    static func exportSnapshot(_ ctx: ModelContext, force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastExport) > 30 else { return }
        lastExport = Date()
        guard let root = await root() else {
            print("[ClaudeBridge] no iCloud Drive container; snapshot skipped")
            return
        }
        do {
            let snapshot = try BridgeExport.make(in: ctx, appState: appState, redact: true)
            let url = root.appending(path: "snapshot.json")
            try await Task.detached(priority: .utility) {
                try write(try BridgeCoding.encoder().encode(snapshot), to: url)
            }.value
            print("[ClaudeBridge] snapshot written to \(url.path)")
        } catch {
            print("[ClaudeBridge] snapshot export failed: \(error)")
        }
    }

    // Coordinated so iCloud never uploads a half-written file.
    nonisolated static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    // MARK: - files

    nonisolated static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    nonisolated static func remove(_ url: URL) throws {
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { removeError = error }
        }
        if let error = coordinationError ?? removeError { throw error }
    }

    // The .json files in a bridge folder by their real names. Files the Mac wrote may not be
    // downloaded yet ("…json.icloud" placeholders); this starts the download, and the
    // coordinated read waits for it.
    nonisolated static func list(_ dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap { name -> String? in
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                try? FileManager.default.startDownloadingUbiquitousItem(at: dir.appending(path: real))
                return real
            }
            return name.hasPrefix(".") ? nil : name
        }).filter { $0.hasSuffix(".json") }.sorted().map { dir.appending(path: $0) }
    }

    nonisolated static func results(_ root: URL) -> [BridgeResult] {
        list(root.appending(path: BridgePaths.results, directoryHint: .isDirectory))
            .compactMap { try? BridgeCoding.decoder().decode(BridgeResult.self, from: read($0)) }
            .sorted { $0.decidedAt > $1.decidedAt }
    }

    nonisolated static func publishedKeys(_ root: URL) -> [BridgePublicKey] {
        list(root.appending(path: BridgePaths.keys, directoryHint: .isDirectory))
            .compactMap { try? BridgeCoding.decoder().decode(BridgePublicKey.self, from: read($0)) }
    }

    @MainActor
    static var appState: BridgeAppState {
        let d = UserDefaults.standard
        let cycle = CycleSettings.current
        let since = d.double(forKey: AutomationSettings.pensionSinceKey)
        return BridgeAppState(
            cycleStartDay: cycle.startDay,
            cycleStartsEarlyOnWeekends: cycle.startsEarlyOnWeekends,
            currentSpaceId: d.string(forKey: SpaceSelection.key).flatMap(UUID.init(uuidString:)),
            automation: .init(
                recurringEnabled: AutomationSettings.recurringEnabled,
                recurringMuted: AutomationSettings.muted.sorted(),
                recurringDeclined: AutomationSettings.declinedRecurring.sorted(),
                recurringPins: AutomationSettings.pins,
                pensionEnabled: d.bool(forKey: AutomationSettings.pensionEnabledKey),
                pensionSourceAccountId: d.string(forKey: AutomationSettings.pensionSourceKey).flatMap(UUID.init(uuidString:)),
                pensionTargetAccountId: d.string(forKey: AutomationSettings.pensionTargetKey).flatMap(UUID.init(uuidString:)),
                pensionAmount: d.string(forKey: AutomationSettings.pensionAmountKey).flatMap(CoreLogic.Transactions.parseAmount),
                pensionSince: since > 0 ? Date(timeIntervalSince1970: since) : nil,
                pensionDeclinedArrivals: AutomationSettings.declinedSplits.sorted()),
            claude: ClaudeSettings.snapshotState)
    }
}

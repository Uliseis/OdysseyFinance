import Foundation
import CoreBridge

// The bridge folder inside the app's iCloud Drive container, as the Mac sees it.
public struct BridgeFiles: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    // ODYSSEY_BRIDGE_DIR points the server at another folder (tests, a copied snapshot).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> BridgeFiles {
        if let dir = env["ODYSSEY_BRIDGE_DIR"], !dir.isEmpty {
            return BridgeFiles(root: URL(filePath: dir, directoryHint: .isDirectory))
        }
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/iCloud~com~uliseis~odysseyfinance/bridge", directoryHint: .isDirectory)
        return BridgeFiles(root: container)
    }

    public var snapshot: URL { root.appending(path: BridgePaths.snapshot) }
    // The user's categorisation policy. It names real people, so it lives here, never in git.
    public var policy: URL { root.appending(path: BridgePaths.policy) }
    public var inbox: URL { root.appending(path: BridgePaths.inbox, directoryHint: .isDirectory) }
    public var results: URL { root.appending(path: BridgePaths.results, directoryHint: .isDirectory) }
    public var keys: URL { root.appending(path: BridgePaths.keys, directoryHint: .isDirectory) }

    public func inboxFile(_ id: UUID) -> URL { inbox.appending(path: BridgePaths.file(for: id)) }
    public func resultFile(_ id: UUID) -> URL { results.appending(path: BridgePaths.file(for: id)) }
    public func keyFile(_ keyId: String) -> URL { keys.appending(path: "\(keyId).json") }

    // A coordinated read makes iCloud download a file that is only a placeholder on this Mac.
    public func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    // Coordinated so iCloud never uploads a half-written file.
    public func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    public func remove(_ url: URL) throws {
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { removeError = error }
        }
        if let error = coordinationError ?? removeError { throw error }
    }

    // A file iCloud hasn't downloaded yet may show up as ".name.icloud"; it still counts.
    public func exists(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
    }

    // The .json files in a folder, by their real names.
    public func list(_ dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap { name -> String? in
            if name.hasPrefix("."), name.hasSuffix(".icloud") { return String(name.dropFirst().dropLast(".icloud".count)) }
            return name.hasPrefix(".") ? nil : name
        }).filter { $0.hasSuffix(".json") }.sorted().map { dir.appending(path: $0) }
    }

    public func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

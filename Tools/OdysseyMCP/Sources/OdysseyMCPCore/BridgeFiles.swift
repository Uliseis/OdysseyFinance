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

    public var snapshot: URL { root.appending(path: "snapshot.json") }
    // The user's categorisation policy. It names real people, so it lives here, never in git.
    public var policy: URL { root.appending(path: "policy.md") }

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

    public func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

import Foundation
import CoreBridge

public enum SnapshotError: Error, CustomStringConvertible {
    case missing(URL)
    case unreadable(URL, Error)
    case newerSchema(Int)

    public var description: String {
        switch self {
        case .missing(let url):
            "No snapshot at \(url.path). Open Odyssey Finance on the iPhone (iCloud Drive on) so it writes one, then try again."
        case .unreadable(let url, let error):
            "Couldn't read \(url.lastPathComponent): \(error)"
        case .newerSchema(let v):
            "The snapshot uses schema \(v), newer than this server understands (\(BridgeSnapshot.currentSchemaVersion)). Rebuild Tools/OdysseyMCP."
        }
    }
}

// Rebuilds the in-memory replica only when the phone has written a new snapshot.
@MainActor
public final class SnapshotStore {
    public let files: BridgeFiles
    private var cached: (modified: Date, replica: BridgeReplica)?

    public init(files: BridgeFiles) { self.files = files }

    public func replica() throws -> BridgeReplica {
        guard let modified = files.modificationDate(files.snapshot) else { throw SnapshotError.missing(files.snapshot) }
        if let cached, cached.modified == modified { return cached.replica }
        let snapshot: BridgeSnapshot
        do {
            snapshot = try BridgeCoding.decoder().decode(BridgeSnapshot.self, from: try files.read(files.snapshot))
        } catch {
            throw SnapshotError.unreadable(files.snapshot, error)
        }
        guard snapshot.schemaVersion <= BridgeSnapshot.currentSchemaVersion else {
            throw SnapshotError.newerSchema(snapshot.schemaVersion)
        }
        let replica = try BridgeReplica(snapshot)
        cached = (modified, replica)
        return replica
    }
}

import Foundation

// What the phone writes to bridge/results/<batchId>.json once a batch is decided.
public struct BridgeResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case applied, partial, failed, rejected }
    public enum Decider: String, Codable, Sendable { case user, auto }

    public var batchId: UUID
    public var summary: String
    public var status: Status
    public var decidedAt: Date
    public var decidedBy: Decider
    public var verified: Bool
    public var reason: String?
    public var outcome: BatchOutcome?
    public var undoneAt: Date?

    public init(batchId: UUID, summary: String, status: Status, decidedAt: Date, decidedBy: Decider,
                verified: Bool, reason: String? = nil, outcome: BatchOutcome? = nil, undoneAt: Date? = nil) {
        self.batchId = batchId
        self.summary = summary
        self.status = status
        self.decidedAt = decidedAt
        self.decidedBy = decidedBy
        self.verified = verified
        self.reason = reason
        self.outcome = outcome
        self.undoneAt = undoneAt
    }

    public static func status(of outcome: BatchOutcome) -> Status {
        switch (outcome.appliedCount, outcome.failedCount) {
        case (_, 0): .applied
        case (0, _): .failed
        default: .partial
        }
    }
}

// The folder layout both sides agree on.
public enum BridgePaths {
    public static let snapshot = "snapshot.json"
    public static let policy = "policy.md"
    public static let inbox = "inbox"
    public static let results = "results"
    public static let keys = "keys"

    public static func file(for id: UUID) -> String { "\(id.uuidString).json" }
}

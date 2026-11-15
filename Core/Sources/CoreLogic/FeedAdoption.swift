import Foundation
import SwiftData
import CoreModel

extension CoreLogic {
    // A manual account whose bank later exposes it (a card added to an Enable Banking
    // consent) arrives as a second, discovered account. Adoption folds that feed into the
    // manual account so history, categories and transfer pairing survive: a feed row
    // re-keys its manual twin (same amount, nearest within the window), replaces a route
    // mirror with the real leg, or moves across; then the manual account takes over the
    // feed's identity and the discovered account is deleted.
    public enum FeedAdoption {
        public static let matchWindow: TimeInterval = 3 * 86_400
        static let feedSinceKey = "feedSince"

        public enum AdoptError: Swift.Error, Equatable {
            case targetNotManual
            case sourceNotConnected
            case currencyMismatch
            case emptyFeed
        }

        public struct Summary: Equatable, Sendable {
            public var rekeyed = 0
            public var mirrorsReplaced = 0
            public var moved = 0
            public var keptManualOnly = 0
        }

        nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

        @MainActor @discardableResult
        public static func adopt(
            feed: Account, into manual: Account, in ctx: ModelContext, now: Date = .now
        ) throws -> Summary {
            guard Accounts.isManual(manual) else { throw AdoptError.targetNotManual }
            guard let connection = feed.connection else { throw AdoptError.sourceNotConnected }
            guard feed.currency == manual.currency else { throw AdoptError.currencyMismatch }

            let feedId = feed.id
            let manualId = manual.id
            let feedRows = try ctx.fetch(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.account?.id == feedId }))
            guard let since = feedRows.map(\.bookedAt).min() else { throw AdoptError.emptyFeed }
            let lower = since.addingTimeInterval(-matchWindow)
            let manualRows = try ctx.fetch(FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.account?.id == manualId && $0.bookedAt >= lower }))

            // Nearest-in-time first, globally, as StatementImport does.
            var pairs: [(distance: TimeInterval, feed: Int, manual: Int)] = []
            for (i, f) in feedRows.enumerated() {
                for (j, m) in manualRows.enumerated() where m.amount == f.amount {
                    let distance = abs(m.bookedAt.timeIntervalSince(f.bookedAt))
                    if distance <= matchWindow { pairs.append((distance, i, j)) }
                }
            }
            pairs.sort { $0.distance < $1.distance }
            var usedFeed = Set<Int>()
            var usedManual = Set<Int>()
            var summary = Summary()
            for pair in pairs where !usedFeed.contains(pair.feed) && !usedManual.contains(pair.manual) {
                usedFeed.insert(pair.feed)
                usedManual.insert(pair.manual)
                let f = feedRows[pair.feed]
                let m = manualRows[pair.manual]
                if let source = m.routedFromTx {
                    // The route invented this leg; the feed has the real one.
                    _ = try TransferRoutes.removeMirror(forSource: source.id, in: ctx)
                    f.account = manual
                    _ = try Transfers.pairManual(source, f, in: ctx)
                    summary.mirrorsReplaced += 1
                } else {
                    m.externalId = f.externalId
                    m.valueAt = f.valueAt
                    m.rawJSON = f.rawJSON
                    m.updatedAt = now
                    ctx.delete(f)
                    summary.rekeyed += 1
                }
            }
            for (i, f) in feedRows.enumerated() where !usedFeed.contains(i) {
                f.account = manual
                f.updatedAt = now
                summary.moved += 1
            }
            summary.keptManualOnly = manualRows.indices
                .filter { !usedManual.contains($0) && manualRows[$0].bookedAt >= since }.count

            // Each sync renames a bank account to the holder's name; the alias keeps the
            // user's name on screen.
            if manual.alias == nil { manual.alias = manual.name }
            manual.connection = connection
            manual.externalId = feed.externalId
            manual.iban = feed.iban
            manual.balance = feed.balance
            manual.balanceUpdatedAt = feed.balanceUpdatedAt
            // An anchor outranks the bank balance; the bank is the authority from here.
            manual.balanceAnchor = nil
            manual.balanceAnchorAt = nil
            var meta = metadata(manual.metadataJSON).merging(metadata(feed.metadataJSON)) { _, new in new }
            meta.removeValue(forKey: "pendingApproval")
            meta[feedSinceKey] = iso.string(from: since)
            manual.metadataJSON = try? JSONSerialization.data(withJSONObject: meta)
            manual.updatedAt = now
            try ctx.saveTouchingChanges()

            ctx.delete(feed)
            try ctx.saveTouchingChanges()
            return summary
        }

        // First day the account's own feed covers; routes stop mirroring into it from here.
        public static func feedSince(of account: Account) -> Date? {
            (metadata(account.metadataJSON)[feedSinceKey] as? String).flatMap { iso.date(from: $0) }
        }

        private static func metadata(_ data: Data?) -> [String: Any] {
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return object
        }
    }
}

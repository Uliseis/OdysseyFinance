#if DEBUG
import Foundation
import SwiftData
import CoreModel
import CoreLogic

// One-shot: OFADOPT="<feed account uuid>=<manual account uuid>" folds a discovered bank-feed
// account into the manual account it duplicates (CoreLogic.FeedAdoption). Idempotent: once
// adopted the feed account is gone and the target is no longer manual, so a rerun refuses.
enum FeedAdoptionRun {
    @MainActor
    static func runIfRequested(_ container: ModelContainer) {
        guard let spec = ProcessInfo.processInfo.environment["OFADOPT"],
              let eq = spec.firstIndex(of: "="),
              let feedId = UUID(uuidString: String(spec[..<eq])),
              let manualId = UUID(uuidString: String(spec[spec.index(after: eq)...])) else { return }
        let ctx = container.mainContext
        guard let feed = try? ctx.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.id == feedId })).first,
              let manual = try? ctx.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.id == manualId })).first
        else { print("[Adopt] account not found (already adopted?)"); return }
        do {
            let s = try CoreLogic.FeedAdoption.adopt(feed: feed, into: manual, in: ctx)
            print("[Adopt] rekeyed=\(s.rekeyed) mirrorsReplaced=\(s.mirrorsReplaced) moved=\(s.moved) keptManualOnly=\(s.keptManualOnly)")
        } catch {
            print("[Adopt] refused: \(error)")
        }
    }
}
#endif

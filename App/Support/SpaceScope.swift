import Foundation
import CoreModel
import CoreLogic

// Ports lib/spaces.ts: the default space catches accounts with no space assignment.
// Resolved from the persisted `currentSpaceId` (empty/unknown ⇒ default space).
struct SpaceScope {
    let current: AccountSpace?
    let defaultId: UUID?

    var currentId: UUID? { current?.id ?? defaultId }

    static func resolve(rawCurrentId: String, spaces: [AccountSpace]) -> SpaceScope {
        let def = spaces.first { $0.isDefault } ?? spaces.first
        let selected = UUID(uuidString: rawCurrentId)
            .flatMap { id in spaces.first { $0.id == id } } ?? def
        return SpaceScope(current: selected, defaultId: def?.id)
    }

    // Matches accountInSpaceClause: the default space also includes space-less accounts.
    func includes(_ account: Account?) -> Bool {
        guard let account, let currentId, let defaultId else { return false }
        return CoreLogic.Spaces.contains(account, spaceId: currentId, defaultSpaceId: defaultId)
    }
}

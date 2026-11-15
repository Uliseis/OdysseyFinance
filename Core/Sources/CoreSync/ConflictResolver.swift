import Foundation
import CoreModel

public enum Resolution<S: SyncSnapshot>: Equatable, Sendable {
    case keepLocal
    case applyRemote
    case merge(S)
}

public enum ConflictResolver {

    public static func resolve<S: SyncSnapshot>(local: S, remote: S) -> Resolution<S> {
        local.clock > remote.clock ? .keepLocal : .applyRemote
    }

    public static func resolveTransaction(
        local: TransactionSnapshot,
        remote: TransactionSnapshot
    ) -> Resolution<TransactionSnapshot> {
        let localManual = local.categorySource == .manual
        let remoteManual = remote.categorySource == .manual
        let remoteIsNewerOrTied = local.clock <= remote.clock

        if localManual && !remoteManual {
            if remoteIsNewerOrTied {
                return .merge(
                    remote.withCategory(id: local.categoryId, source: local.categorySource)
                )
            }
            return .keepLocal
        }

        if remoteManual && !localManual {
            if remoteIsNewerOrTied {
                return .applyRemote
            }
            return .merge(
                local.withCategory(id: remote.categoryId, source: remote.categorySource)
            )
        }

        return remoteIsNewerOrTied ? .applyRemote : .keepLocal
    }
}

extension ConflictResolver {
    // A push the server refused because its copy changed: keep this device's values when its
    // clock is newer. During the one-time repair re-push a tie goes to the device too: a tie
    // is exactly a record whose cleared fields never reached CloudKit before the changedKeys fix.
    public static func localWinsPush(localClock: Date, remoteClock: Date, preferLocalOnTie: Bool) -> Bool {
        localClock > remoteClock || (preferLocalOnTie && localClock == remoteClock)
    }
}


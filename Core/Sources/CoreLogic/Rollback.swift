import Foundation
import SwiftData

public extension ModelContext {
    // On iOS and macOS 27 a rollback that undoes an insert leaves the saved models the insert
    // pointed at reading nil for their other relationships (an account's group, say) until each
    // is fetched again. Use this instead of rollback().
    func rollbackRefetching() {
        let touched = changedModelsArray.map { $0 } + deletedModelsArray.map { $0 }
        rollback()
        for model in touched { refetch(model) }
    }

    private func refetch<T: PersistentModel>(_ model: T) {
        let id = model.persistentModelID
        _ = try? fetch(FetchDescriptor<T>(predicate: #Predicate { $0.persistentModelID == id }))
    }
}

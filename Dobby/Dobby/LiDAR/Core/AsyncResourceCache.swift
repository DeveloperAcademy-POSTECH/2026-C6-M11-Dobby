import Foundation

/// One reusable resource per owner, including while its first load is pending.
/// The cache owns its detached load; cancelling one screen does not cancel a
/// resource another screen is awaiting. A cancelled caller never receives it.
actor AsyncResourceCache<Resource: Sendable> {
    private struct Loading {
        let id: UUID
        let task: Task<Resource, Error>
    }

    private let loader: @Sendable () async throws -> Resource
    private var resource: Resource?
    private var loading: Loading?

    init(loader: @escaping @Sendable () async throws -> Resource) {
        self.loader = loader
    }

    func value() async throws -> Resource {
        try Task.checkCancellation()
        if let resource { return resource }

        let pending: Loading
        if let loading {
            pending = loading
        } else {
            let loader = self.loader
            // In particular, synchronous construction at the beginning of an
            // async loader must not inherit a calling view's main actor.
            pending = Loading(id: UUID(), task: Task.detached(priority: .userInitiated) {
                try await loader()
            })
            loading = pending
        }

        do {
            let loaded = try await pending.task.value
            if loading?.id == pending.id {
                resource = .some(loaded)
                loading = nil
            }
            try Task.checkCancellation()
            return loaded
        } catch {
            // Other waiters may still be returning from an older failed task
            // after a new caller has already started a retry. Leave it intact.
            if loading?.id == pending.id { loading = nil }
            throw error
        }
    }
}

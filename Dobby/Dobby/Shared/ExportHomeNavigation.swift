import SwiftUI

/// Stable root identity keeps a newly allocated action closure from invalidating
/// every presented camera/export view when unrelated root state changes.
nonisolated struct ExportHomeNavigationAction: Equatable, Sendable {
    private let id: UUID
    private let action: @MainActor @Sendable () -> Void

    init(id: UUID, action: @escaping @MainActor @Sendable () -> Void) {
        self.id = id
        self.action = action
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    @MainActor func callAsFunction() { action() }
}

extension EnvironmentValues {
    /// The root owns tabs and presentation state. Nested export presenters
    /// invoke this only after their own sheet/cover has finished dismissing.
    @Entry var returnHomeFromExport: ExportHomeNavigationAction? = nil
}

import SwiftUI

enum ExportReturnDestination: Equatable, Sendable {
    case home
    case library
}

/// Stable root identity keeps a newly allocated action closure from invalidating
/// every presented camera/export view when unrelated root state changes.
nonisolated struct ExportReturnNavigationAction: Equatable, Sendable {
    private let id: UUID
    private let action: @MainActor @Sendable (ExportReturnDestination) -> Void

    init(id: UUID, action: @escaping @MainActor @Sendable (ExportReturnDestination) -> Void) {
        self.id = id
        self.action = action
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    @MainActor func callAsFunction(to destination: ExportReturnDestination) {
        action(destination)
    }
}

extension EnvironmentValues {
    /// The root owns tabs and presentation state. Nested export presenters
    /// invoke this only after their own sheet/cover has finished dismissing.
    @Entry var returnFromExport: ExportReturnNavigationAction? = nil
}

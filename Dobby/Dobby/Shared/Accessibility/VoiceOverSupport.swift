import SwiftUI
import UIKit

/// Short, user-triggered results only. Live camera frames must not interrupt speech.
@MainActor
enum VoiceOverAnnouncement {
    static func post(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

private struct AccessibilityModalHeading: ViewModifier {
    @AccessibilityFocusState(for: .voiceOver) private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($isFocused)
            .task {
                // Let a newly mounted dialog enter the accessibility tree first.
                await Task.yield()
                guard !Task.isCancelled else { return }
                isFocused = true
            }
    }
}

extension View {
    /// Apply to a custom dialog's title, leaving its controls separately reachable.
    func accessibilityModalHeading() -> some View {
        modifier(AccessibilityModalHeading())
    }
}

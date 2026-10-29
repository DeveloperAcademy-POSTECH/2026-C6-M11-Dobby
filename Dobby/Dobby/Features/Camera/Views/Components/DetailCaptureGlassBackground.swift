// Created by mason on 10/27/26.
import SwiftUI

/// Compatibility name for former glass fixtures. Camera surroundings are now
/// always opaque black, independent of accessibility transparency settings.
struct DetailCaptureGlassBackground: View {
    var body: some View {
        Color.black
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

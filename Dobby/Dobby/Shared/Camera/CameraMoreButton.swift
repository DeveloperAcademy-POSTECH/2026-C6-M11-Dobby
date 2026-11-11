import SwiftUI

/// Shared 48pt menu button using the Figma symbol and brand surface color.
struct CameraMoreButton: View {
    var isEnabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color("BrandNeutral900"), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("촬영 옵션")
    }
}

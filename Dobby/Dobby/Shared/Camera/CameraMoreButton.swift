import SwiftUI

/// One 48pt asset/touch surface for the detail and measurement camera menus.
/// The original asset already contains its disc and dots; never template-tint it.
struct CameraMoreButton: View {
    var isEnabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image("DetailCaptureMore").renderingMode(.original)
                .frame(width: 48, height: 48)
                .background(Color(white: 0.094), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("촬영 옵션")
    }
}

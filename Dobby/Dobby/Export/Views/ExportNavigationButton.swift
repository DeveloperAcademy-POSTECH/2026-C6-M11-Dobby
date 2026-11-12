import SwiftUI

struct ExportNavigationButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(Color(.exportCloseIcon))
        }
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

import SwiftUI

struct ExportBottomAction: View {
    let title: String
    var isWorking = false
    var isComplete = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        ChakPrimaryButton(
            title: title,
            isLoading: isWorking,
            showsCompletion: isComplete
        ) {
            action()
        }
        .disabled(!isEnabled || isWorking)
    }
}

struct ExportBottomActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, ExportScreenStyle.horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
    }
}

import SwiftUI

struct ExportBottomAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        ChakPrimaryButton(title: title) {
            action()
        }
    }
}

struct ExportBottomActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, ExportScreenStyle.horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Color(.brandNeutralWhite))
    }
}

#Preview("하단 액션", traits: .sizeThatFitsLayout) {
    ExportBottomAction(title: "업로드하기", action: {})
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutralWhite))
}

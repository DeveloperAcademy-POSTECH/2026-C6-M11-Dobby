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

#Preview("하단 액션 · 상태", traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        ExportBottomAction(title: "업로드하기", action: {})
        ExportBottomAction(title: "업로드하기", isWorking: true, action: {})
        ExportBottomAction(title: "업로드 완료", isComplete: true, action: {})
        ExportBottomAction(title: "업로드하기", isEnabled: false, action: {})
    }
    .frame(width: 363)
    .padding()
    .background(Color(.brandNeutralWhite))
}

#Preview("하단 액션 바", traits: .sizeThatFitsLayout) {
    ExportBottomActionBar {
        ExportBottomAction(title: "업로드하기", action: {})
    }
    .frame(width: 402)
}

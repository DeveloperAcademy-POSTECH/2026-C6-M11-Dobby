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

#Preview("내비게이션 버튼", traits: .sizeThatFitsLayout) {
    HStack(spacing: 24) {
        ExportNavigationButton(
            systemImage: "chevron.left",
            accessibilityLabel: "뒤로 가기",
            action: {}
        )
        ExportNavigationButton(
            systemImage: "xmark",
            accessibilityLabel: "닫기",
            isDisabled: true,
            action: {}
        )
    }
    .padding()
    .background(Color(.brandNeutralWhite))
}

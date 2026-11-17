import SwiftUI

struct InstagramUploadFailureOverlay: View {
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            InstagramUploadFailureContent(
                onCancel: onCancel,
                onRetry: onRetry
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onCancel)
    }
}

private struct InstagramUploadFailureContent: View {
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            InstagramUploadFailureMessage()
            InstagramUploadFailureActions(
                onCancel: onCancel,
                onRetry: onRetry
            )
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 17)
        .frame(width: 360)
        .background(Color(.brandNeutralWhite), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct InstagramUploadFailureMessage: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("자동 업로드 실패")
                .font(.custom("Pretendard-Bold", fixedSize: 20))
                .accessibilityModalHeading()
                .foregroundStyle(Color(.accentsRed))
            Text("인스타그램 자동 업로드에 실패했어요\n다시 업로드할까요?")
                .font(.custom("Pretendard-Regular", fixedSize: 16))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(.brandNeutralBlack))
        }
        .padding(.vertical, 12)
    }
}

private struct InstagramUploadFailureActions: View {
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ChakHorizontalActionButtons(
            secondary: .init(title: "취소하기", action: onCancel),
            primary: .init(title: "다시 업로드하기", action: onRetry)
        )
    }
}

#Preview("인스타그램 자동 업로드 실패") {
    InstagramUploadFailureOverlay(
        onCancel: {},
        onRetry: {}
    )
}

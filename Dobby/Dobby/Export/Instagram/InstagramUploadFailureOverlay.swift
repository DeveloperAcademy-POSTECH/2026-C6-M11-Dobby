import SwiftUI

struct InstagramUploadFailureOverlay: View {
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            InstagramUploadFailureContent(
                onCancel: onCancel,
                onRetry: onRetry
            )
        }
        .accessibilityElement(children: .contain)
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
            Text("인스타그램 자동 업로드에 실패했어요\n다시 업로드할까요?")
                .font(.custom("Pretendard-Regular", fixedSize: 16))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(.brandNeutral900))
        .padding(.vertical, 12)
    }
}

private struct InstagramUploadFailureActions: View {
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            InstagramUploadFailureButton(
                title: "취소하기",
                foregroundColor: Color(.brandNeutral900),
                backgroundColor: Color(.brandNeutral100),
                action: onCancel
            )
            InstagramUploadFailureButton(
                title: "다시 업로드하기",
                foregroundColor: Color(.brandNeutralWhite),
                backgroundColor: Color(.brandMain),
                action: onRetry
            )
        }
    }
}

private struct InstagramUploadFailureButton: View {
    let title: String
    let foregroundColor: Color
    let backgroundColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Pretendard-Medium", fixedSize: 16))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .background(backgroundColor, in: Capsule())
    }
}

#Preview("인스타그램 자동 업로드 실패") {
    InstagramUploadFailureOverlay(
        onCancel: {},
        onRetry: {}
    )
}

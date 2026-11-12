import SwiftUI

struct InstagramUploadCompletionView: View {
    let onOpenLibrary: () -> Void
    let onOpenInstagram: () -> Void

    var body: some View {
        InstagramCompletionContent(
            icon: .uploadCompletionIcon,
            title: "업로드 완료",
            message: "연결된 계정에 자동으로 업로드했어요!",
            secondary: .init(
                title: "보관함으로 가기",
                accessibilityIdentifier: "export.instagram.library",
                action: onOpenLibrary
            ),
            primary: .init(
                title: "인스타그램 열기",
                accessibilityIdentifier: "export.instagram.open",
                action: onOpenInstagram
            )
        )
    }
}

struct InstagramConnectionCompletionView: View {
    let onOpenLibrary: () -> Void
    let onContinueToUpload: () -> Void

    var body: some View {
        InstagramCompletionContent(
            icon: .instagramConnectionCompletionIcon,
            title: "인스타그램 연결 완료!",
            message: "인스타그램 프로페셔널 계정과\n성공적으로 연결을 완료했어요",
            secondary: .init(
                title: "보관함으로 가기",
                accessibilityIdentifier: "export.instagram.library",
                action: onOpenLibrary
            ),
            primary: .init(
                title: "업로드하러 가기",
                accessibilityIdentifier: "export.instagram.continueToUpload",
                action: onContinueToUpload
            ),
            primaryFontSize: 17
        )
    }
}

private struct InstagramCompletionContent: View {
    private enum Layout {
        static let contentTopSpacing: CGFloat = 176
        static let contentBottomSpacing: CGFloat = 215
        static let buttonBarHorizontalPadding: CGFloat = 34
        static let buttonBarTopPadding: CGFloat = 16
        static let buttonBarBottomPadding: CGFloat = 82
        static let buttonBarMaximumWidth: CGFloat = 402
    }

    let icon: ImageResource
    let title: String
    let message: String
    let secondary: ChakButtonAction
    let primary: ChakButtonAction
    var primaryFontSize: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
                .frame(maxHeight: Layout.contentTopSpacing)

            InstagramCompletionSummary(icon: icon, title: title, message: message)

            Spacer(minLength: 0)
                .frame(maxHeight: Layout.contentBottomSpacing)

            ChakVerticalActionButtons(
                secondary: secondary,
                primary: primary,
                primaryFontSize: primaryFontSize
            )
            .padding(.horizontal, Layout.buttonBarHorizontalPadding)
            .padding(.top, Layout.buttonBarTopPadding)
            .padding(.bottom, Layout.buttonBarBottomPadding)
            .frame(maxWidth: Layout.buttonBarMaximumWidth)
            .background(Color(.brandNeutral50))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.brandNeutralWhite).ignoresSafeArea())
    }
}

private struct InstagramCompletionSummary: View {
    let icon: ImageResource
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 45) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            InstagramCompletionText(title: title, message: message)
        }
    }
}

private struct InstagramCompletionText: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.custom("Pretendard-Bold", fixedSize: 30))
                .kerning(0.37)
                .foregroundStyle(Color(.brandNeutralBlack))
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .font(.custom("Pretendard-SemiBold", fixedSize: 17))
                .foregroundStyle(Color(.brandNeutral600))
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 362, alignment: .top)
    }
}

#Preview("인스타그램 업로드 완료") {
    InstagramUploadCompletionView(onOpenLibrary: {}, onOpenInstagram: {})
}

#Preview("인스타그램 연결 완료") {
    InstagramConnectionCompletionView(onOpenLibrary: {}, onContinueToUpload: {})
}

#Preview("연결 완료 · 전체 콘텐츠") {
    InstagramCompletionContent(
        icon: .instagramConnectionCompletionIcon,
        title: "인스타그램 연결 완료!",
        message: "인스타그램 프로페셔널 계정과\n성공적으로 연결을 완료했어요",
        secondary: .init(title: "보관함으로 가기", action: {}),
        primary: .init(title: "업로드하러 가기", action: {}),
        primaryFontSize: 17
    )
}

#Preview("연결 완료 · 요약", traits: .sizeThatFitsLayout) {
    InstagramCompletionSummary(
        icon: .instagramConnectionCompletionIcon,
        title: "인스타그램 연결 완료!",
        message: "인스타그램 프로페셔널 계정과\n성공적으로 연결을 완료했어요"
    )
    .padding()
    .background(Color(.brandNeutral50))
}

#Preview("연결 완료 · 문구", traits: .sizeThatFitsLayout) {
    InstagramCompletionText(
        title: "인스타그램 연결 완료!",
        message: "인스타그램 프로페셔널 계정과\n성공적으로 연결을 완료했어요"
    )
    .frame(width: 362)
    .padding()
    .background(Color(.brandNeutral50))
}

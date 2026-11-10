import SwiftUI

struct InstagramUploadCompletionView: View {
    private enum Layout {
        static let contentTopSpacing: CGFloat = 176
        static let iconSize: CGFloat = 80
        static let iconTextSpacing: CGFloat = 45
        static let textSpacing: CGFloat = 16
        static let contentBottomSpacing: CGFloat = 215
        static let contentMaximumWidth: CGFloat = 362
        static let titleLetterSpacing: CGFloat = 0.37
        static let buttonBarHorizontalPadding: CGFloat = 34
        static let buttonBarTopPadding: CGFloat = 16
        static let buttonBarBottomPadding: CGFloat = 82
        static let buttonBarMaximumWidth: CGFloat = 402
    }

    let onOpenLibrary: () -> Void
    let onOpenInstagram: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
                .frame(maxHeight: Layout.contentTopSpacing)

            VStack(spacing: Layout.iconTextSpacing) {
                Image(.uploadCompletionIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Layout.iconSize, height: Layout.iconSize)
                    .accessibilityHidden(true)

                VStack(spacing: Layout.textSpacing) {
                    Text("업로드 완료")
                        .font(.custom("Pretendard-Bold", fixedSize: 30))
                        .kerning(Layout.titleLetterSpacing)
                        .foregroundStyle(Color(.brandNeutralBlack))
                        .accessibilityAddTraits(.isHeader)

                    Text("연결된 계정에 자동으로 업로드했어요!")
                        .font(.custom("Pretendard-SemiBold", fixedSize: 17))
                        .foregroundStyle(Color(.brandNeutral600))
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: Layout.contentMaximumWidth, alignment: .top)
            }

            Spacer(minLength: 0)
                .frame(maxHeight: Layout.contentBottomSpacing)

            ChakVerticalActionButtons(
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
            .padding(.horizontal, Layout.buttonBarHorizontalPadding)
            .padding(.top, Layout.buttonBarTopPadding)
            .padding(.bottom, Layout.buttonBarBottomPadding)
            .frame(maxWidth: Layout.buttonBarMaximumWidth)
            .background(Color(.brandNeutral50))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.brandNeutral50).ignoresSafeArea())
    }
}

#Preview("인스타그램 업로드 완료") {
    InstagramUploadCompletionView(onOpenLibrary: {}, onOpenInstagram: {})
}

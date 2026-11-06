import SwiftUI

struct InstagramUploadCompletionView: View {
    private enum Layout {
        static let contentSpacing: CGFloat = 20
        static let sectionSpacing: CGFloat = 144
        static let buttonBarHorizontalPadding: CGFloat = 34
        static let buttonBarTopPadding: CGFloat = 16
        static let buttonBarBottomPadding: CGFloat = 34
    }

    var body: some View {
        VStack(spacing: Layout.sectionSpacing) {
            VStack(spacing: Layout.contentSpacing) {
                Image(systemName: "square.and.arrow.up.badge.checkmark")
                    .font(.system(size: 61.96363, weight: .medium))
                    .foregroundStyle(Color(.brandMain500))
                    .accessibilityHidden(true)

                Text("업로드 완료")
                    .font(.custom("Pretendard-Bold", fixedSize: 30))
                    .accessibilityAddTraits(.isHeader)

                Text("연결된 계정에 자동으로 업로드했어요!")
                    .font(.custom("Pretendard-Medium", fixedSize: 18))
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(.brandNeutralBlack))

            PairedActionButtons(
                secondary: .init(
                    title: "보관함으로 가기",
                    accessibilityIdentifier: "export.instagram.library",
                    handler: {}
                ),
                primary: .init(
                    title: "인스타그램 열기",
                    accessibilityIdentifier: "export.instagram.open",
                    handler: {}
                ),
                minimumHeight: 62
            )
            .padding(.horizontal, Layout.buttonBarHorizontalPadding)
            .padding(.top, Layout.buttonBarTopPadding)
            .padding(.bottom, Layout.buttonBarBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.brandNeutral50).ignoresSafeArea())
    }
}

#Preview("인스타그램 업로드 완료") {
    InstagramUploadCompletionView()
}

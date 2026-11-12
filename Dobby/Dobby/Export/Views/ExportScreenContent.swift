import SwiftUI

struct ExportScreenContent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExportScreenStyle.sectionSpacing) {
                content
            }
            .padding(.horizontal, ExportScreenStyle.horizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, 116)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ExportScreenStyle.background.ignoresSafeArea())
    }
}

#Preview("내보내기 화면 본문") {
    ExportScreenContent {
        ExportSectionCard(title: "상품 정보", subtitle: "업로드 전에 내용을 확인해 주세요.") {}
    }
}

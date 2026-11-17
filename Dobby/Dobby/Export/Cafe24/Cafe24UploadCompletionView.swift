import SwiftUI

struct Cafe24UploadCompletionView: View {
    let onOpenLibrary: () -> Void
    let onOpenCafe24: () -> Void

    var body: some View {
        ExportCompletionContent(
            icon: .uploadCompletionIcon,
            title: "업로드 완료",
            message: "연결된 계정에 자동으로 업로드했어요!",
            secondary: .init(
                title: "보관함으로 가기",
                accessibilityIdentifier: "export.cafe24.library",
                action: onOpenLibrary
            ),
            primary: .init(
                title: "카페24 열기",
                accessibilityIdentifier: "export.cafe24.open",
                action: onOpenCafe24
            )
        )
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

#Preview("카페24 업로드 완료") {
    Cafe24UploadCompletionView(onOpenLibrary: {}, onOpenCafe24: {})
}

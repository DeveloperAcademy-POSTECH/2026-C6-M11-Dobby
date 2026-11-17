import SwiftUI

struct ExportLoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.08).ignoresSafeArea()
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                ProgressView()
                    .tint(ExportScreenStyle.accent)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityModalHeading()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

#Preview("내보내기 로딩") {
    Color(.brandNeutralWhite)
        .ignoresSafeArea()
        .overlay {
            ExportLoadingOverlay(message: "게시물을 업로드하고 있어요")
        }
}

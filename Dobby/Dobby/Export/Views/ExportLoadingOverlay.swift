import SwiftUI

struct ExportLoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.08).ignoresSafeArea()
            HStack(spacing: 12) {
                ProgressView()
                    .tint(ExportScreenStyle.accent)
                Text(message)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
    }
}

#Preview("내보내기 로딩") {
    Color(.brandNeutralWhite)
        .ignoresSafeArea()
        .overlay {
            ExportLoadingOverlay(message: "게시물을 업로드하고 있어요")
        }
}

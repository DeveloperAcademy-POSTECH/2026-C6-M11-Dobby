// Created by mason on 11/11/26.
import SwiftUI

#if DEBUG
private struct DetailPhotoDeleteConfirmationPreview: View {
    var width: CGFloat = 402
    var height: CGFloat = 760
    var isDeleting = false
    @State private var isPresented = true

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.gray, .blue, .white],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack {
                Divider()
                Button("확인창 다시 열기") { isPresented = true }
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .frame(height: 86, alignment: .top)
            .background(.white)
            if isPresented {
                DetailPhotoDeleteConfirmation(isDeleting: isDeleting, bottomInset: 86,
                    onCancel: { isPresented = false }, onDelete: {})
            }
        }
        .frame(width: width, height: height)
        .preferredColorScheme(.light)
    }
}

#Preview("삭제 확인 · 기본", traits: .sizeThatFitsLayout) {
    DetailPhotoDeleteConfirmationPreview()
}
#Preview("삭제 확인 · 좁고 낮은 화면", traits: .sizeThatFitsLayout) {
    DetailPhotoDeleteConfirmationPreview(width: 320, height: 420)
}
#Preview("삭제 확인 · 큰 글자", traits: .sizeThatFitsLayout) {
    DetailPhotoDeleteConfirmationPreview(width: 320, height: 420)
        .environment(\.dynamicTypeSize, .accessibility5)
}
#Preview("삭제 확인 · 처리 중", traits: .sizeThatFitsLayout) {
    DetailPhotoDeleteConfirmationPreview(isDeleting: true)
}
#endif

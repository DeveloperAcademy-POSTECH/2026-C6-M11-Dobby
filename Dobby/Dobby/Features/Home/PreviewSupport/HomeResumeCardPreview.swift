//
//  HomeResumeCardPreview.swift
//  Dobby
//
//  Created by mason on 10/27/26.
//

import SwiftUI

#if DEBUG
#Preview("이어하기 카드 · 사진 · 탭 확인", traits: .sizeThatFitsLayout) {
    HomeResumeCardPreview()
}

#Preview("이어하기 카드 · 사진 없음 · 긴 단계", traits: .sizeThatFitsLayout) {
    HomeResumeCardPreview(hasPhoto: false, step: .photoSelection)
}

#Preview("이어하기 카드 · 작은 화면 · 큰 글씨", traits: .sizeThatFitsLayout) {
    HomeResumeCardPreview(width: 335, step: .information)
        .environment(\.dynamicTypeSize, .accessibility3)
}

private struct HomeResumeCardPreview: View {
    var width: CGFloat = 361
    var hasPhoto = true
    var step: ProductDraftStep = .details
    @State private var showConfirmation = false
    private let date = Date(timeIntervalSince1970: 1_793_000_000)

    var body: some View {
        HomeResumeCard(step: step, savedAt: date.addingTimeInterval(-3 * 24 * 60 * 60),
                       referenceDate: date, onResume: { showConfirmation = true }) {
            // 기존 보관함 Preview 사진만 재사용하며 상품이나 초안을 저장하지 않습니다.
            if hasPhoto,
               let url = Bundle.main.url(forResource: "library-preview-polo-jacket", withExtension: "png"),
               let photo = UIImage(contentsOfFile: url.path) {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                Color(white: 217 / 255)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .frame(width: width)
        .padding(20)
        .background(Color("HomeBackground"))
        .preferredColorScheme(.light)
        .alert("이어하기 버튼 확인", isPresented: $showConfirmation) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("미리보기입니다. 실제 저장된 작업 복원은 후속 연결 단계에서 적용합니다.")
        }
    }
}
#endif

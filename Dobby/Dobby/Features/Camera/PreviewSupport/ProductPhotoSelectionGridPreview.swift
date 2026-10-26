//
//  ProductPhotoSelectionGridPreview.swift
//  Dobby
//
//  Created by mason on 10/25/26.
//

import SwiftUI

#Preview("제품 사진 선택 · 3열 그리드") {
    ProductPhotoSelectionGridPreview()
}

private struct ProductPhotoSelectionGridPreview: View {
    @State private var model: ProductPhotoModel?
    @State private var message = "사진 본문과 우상단 선택 버튼을 각각 탭해 보세요."

    var body: some View {
        VStack {
            Text(message).font(.caption).padding()
            if let model {
                ProductPhotoSelectionGrid(photos: model.photos, selectedPhotoIDs: model.selectedPhotoIDs,
                    onPreview: { _ in message = "확대 요청 전달됨 · 확대 화면은 4단계에서 연결" },
                    onToggleSelection: { model.toggleSelection($0) })
            }
        }
        .background(.white)
        .preferredColorScheme(.light)
        .task {
            guard model == nil else { return }
            do {
                let preview = try CameraPreviewPhotos.makeModel()
                for _ in 0..<11 { try await preview.captureDetail() }
                for index in [0, 7, 4] { preview.toggleSelection(preview.photos[index].id) }
                model = preview
            } catch { message = "미리보기 사진을 불러오지 못했어요." }
        }
    }
}

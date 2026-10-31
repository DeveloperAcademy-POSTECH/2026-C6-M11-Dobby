//
//  ProductPhotoSelectionGrid.swift
//  Dobby
//
//  Created by mason on 10/25/26.
//

import SwiftUI

/// 사진 배치는 전달받은 촬영 순서를 유지하고 선택 순서는 번호로만 표시한다.
struct ProductPhotoSelectionGrid: View {
    let photos: [CapturedAsset]
    let selectedPhotoIDs: [UUID]
    var onPreview: ((CapturedAsset) -> Void)? = nil
    let onToggleSelection: (UUID) -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    ProductPhotoSelectionCell(
                        photo: photo,
                        order: selectedPhotoIDs.firstIndex(of: photo.id).map { $0 + 1 },
                        captureIndex: index,
                        detailNumber: photos.prefix(index).filter { $0.purpose == .detail }.count + 1,
                        onPreview: onPreview.map { preview in { preview(photo) } },
                        onToggleSelection: { onToggleSelection(photo.id) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("camera.selectionGrid")
    }
}

//
//  ProductPhotoSelectionView.swift
//  Dobby
//
//  Created by mason on 9/30/26.
//

import SwiftUI

/// 목 사진의 선택·완료 전달을 검토하는 골격. 실제 이미지와 Hi-Fi 배치는 후속 작업.
struct ProductPhotoSelectionView: View {
    let model: ProductPhotoModel
    let onComplete: (ProductPhotoOutput) -> Void

    var body: some View {
        List {
            Section {
                Text("목 데이터에는 이미지 파일이 없습니다.")
                Text("임시 규칙: 선택한 순서대로 전달하며 첫 번째 사진을 대표로 사용합니다.")
                    .foregroundStyle(.secondary)
            }
            Section("사용할 사진") {
                ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in
                    let order = model.selectedPhotoIDs.firstIndex(of: photo.id).map { $0 + 1 }
                    Button {
                        model.toggleSelection(photo.id)
                    } label: {
                        HStack {
                            Text(photo.purpose == .measurement ? "실측샷" : "상세 사진 \(index)")
                            Spacer()
                            if let order {
                                Text(order == 1 ? "1 · 대표" : "\(order)")
                            } else {
                                Text("미선택").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("camera.photo.\(index)")
                    .accessibilityValue(order.map { "\($0)번째 선택" } ?? "선택 안 됨")
                    .accessibilityHint("선택하거나 선택을 해제합니다. 원본은 삭제되지 않습니다.")
                }
            }
        }
        .navigationTitle("제품 사진 선택")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("완료") {
                    if let output = model.output { onComplete(output) }
                }
                .disabled(model.output == nil)
                .accessibilityIdentifier("camera.completePhotos")
            }
        }
    }
}

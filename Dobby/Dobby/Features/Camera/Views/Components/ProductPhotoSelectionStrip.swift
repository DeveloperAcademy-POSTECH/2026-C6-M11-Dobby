//
//  ProductPhotoSelectionStrip.swift
//  Dobby
//
//  Created by mason on 10/4/26.
//

import SwiftUI

/// 선택 순서 + 미선택 촬영 순서. 탐색 위치와 대표 사진은 각각 별도로 관리한다.
struct ProductPhotoSelectionStrip: View {
    let model: ProductPhotoModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.selectionOrderedPhotos) { photo in
                    ProductPhotoSelectionThumbnail(photo: photo,
                        order: model.selectedPhotoIDs.firstIndex(of: photo.id).map { $0 + 1 },
                        captureIndex: model.photos.firstIndex(where: { $0.id == photo.id }) ?? 0,
                        toggle: { model.toggleSelection(photo.id) })
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.selectedPhotoIDs)
        }
        .background(Color(.tertiaryLabel), in: RoundedRectangle(cornerRadius: 16))
        .disabled(model.isCapturing)
        .accessibilityIdentifier("camera.selectionStrip")
    }
}

private struct ProductPhotoSelectionThumbnail: View {
    let photo: CapturedAsset
    let order: Int?
    let captureIndex: Int
    let toggle: () -> Void
    @State private var imageAvailable: Bool?
    @ScaledMetric(relativeTo: .caption2) private var badgeSize = 10.0
    private let orange = Color(red: 247 / 255, green: 96 / 255, blue: 21 / 255)

    var body: some View {
        Button(action: toggle) {
            CameraPhotoView(source: photo.source, maximumPixelSize: 320,
                            onLoad: { imageAvailable = $0 })
                .frame(width: 60.5, height: 84.7)
                .overlay(alignment: .topLeading) {
                    if photo.purpose == .measurement {
                        Text("실측샷").foregroundStyle(orange)
                            .padding(.horizontal, 6).padding(.vertical, 4).background(.white)
                            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 6)).padding(2)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let order {
                        Text("\(order)").foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 4).background(.black)
                            .clipShape(UnevenRoundedRectangle(topTrailingRadius: 6)).padding(2)
                    }
                }
                .overlay { Rectangle().strokeBorder(order == nil ? .clear : orange, lineWidth: 2) }
                .font(.system(size: badgeSize, weight: .semibold))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 손상된 새 사진은 선택하지 않되 이미 선택한 사진은 해제할 수 있다.
        .disabled(imageAvailable != true && order == nil)
        .accessibilityLabel(photo.purpose == .measurement ? "실측 사진" : "상세 사진 \(captureIndex)")
        .accessibilityValue(order.map { "\($0)번째 선택" } ?? "선택 안 됨")
        .accessibilityHint(imageAvailable == false ? "사진을 불러올 수 없어요" : "탭하여 선택 또는 해제. 첫 번째 선택이 대표 사진입니다.")
        .accessibilityAddTraits(order == nil ? [] : .isSelected)
        .accessibilityIdentifier("camera.thumbnail.\(captureIndex)")
    }
}

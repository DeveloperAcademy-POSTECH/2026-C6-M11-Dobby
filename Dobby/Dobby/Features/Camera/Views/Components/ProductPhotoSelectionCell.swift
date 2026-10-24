//
//  ProductPhotoSelectionCell.swift
//  Dobby
//
//  Created by mason on 10/25/26.
//

import SwiftUI

struct ProductPhotoSelectionCell: View {
    let photo: CapturedAsset
    let order: Int?
    let captureIndex: Int
    let onPreview: () -> Void
    let onToggleSelection: () -> Void
    @State private var imageAvailable: Bool?
    private let shape = RoundedRectangle(cornerRadius: 12)

    private var photoLabel: String {
        photo.purpose == .measurement ? "실측 사진" : "상세 사진 \(captureIndex)"
    }

    var body: some View {
        Color.clear
            .aspectRatio(116.0 / 148.0, contentMode: .fit)
            .overlay {
                Button(action: onPreview) {
                    CameraPhotoView(source: photo.source, maximumPixelSize: 640,
                                    onLoad: { imageAvailable = $0 })
                        .overlay { Color.black.opacity(order == nil ? 0 : 0.5) }
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(order == nil ? .clear : .black, lineWidth: 4) }
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .disabled(imageAvailable != true)
                .accessibilityLabel("\(photoLabel) 확대 보기")
                .accessibilityHint(imageAvailable == false ? "사진을 불러올 수 없어요" : "사진을 크게 확인합니다")
                .accessibilityIdentifier("camera.grid.preview.\(captureIndex)")
            }
            .overlay(alignment: .topTrailing) {
                // 사진 버튼과 중첩하지 않아 선택 탭이 확대 동작으로 전달되지 않는다.
                Button(action: onToggleSelection) {
                    Text(order.map(String.init) ?? "")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(red: 41 / 255, green: 36 / 255, blue: 36 / 255))
                        .frame(width: 24, height: 24)
                        .background(order == nil ? Color.white.opacity(0.7) : Color(white: 205 / 255), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 읽기 실패한 사진도 이미 선택되어 있다면 해제할 수 있다.
                .disabled(imageAvailable != true && order == nil)
                .accessibilityLabel("\(photoLabel) \(order == nil ? "선택" : "선택 해제")")
                .accessibilityValue(order.map { "\($0)번째 선택" } ?? "선택 안 됨")
                .accessibilityAddTraits(order == nil ? [] : .isSelected)
                .accessibilityIdentifier("camera.grid.select.\(captureIndex)")
            }
            .accessibilityElement(children: .contain)
    }
}

// Created by mason on 10/25/26.
import SwiftUI

/// 선택 초안을 공유하며 사진만 크게 확인한다. 원본 파일과 촬영 순서는 변경하지 않는다.
struct ProductPhotoSelectionPreviewView: View {
    let photo: CapturedAsset
    let model: ProductPhotoModel
    @Environment(\.dismiss) private var dismiss
    @State private var imageAvailable: Bool?
    @State private var selectionLimitNoticeID: UUID?
    private let background = Color(red: 26 / 255, green: 25 / 255, blue: 25 / 255)
    private var order: Int? { model.selectedPhotoIDs.firstIndex(of: photo.id).map { $0 + 1 } }
    private var photoAspectRatio: CGFloat {
        guard case let .localFile(_, metadata) = photo.source,
              metadata.pixelWidth > 0, metadata.pixelHeight > 0 else { return 3 / 4 }
        let swapsAxes = (5...8).contains(metadata.orientation.rawValue)
        return swapsAxes ? CGFloat(metadata.pixelHeight) / CGFloat(metadata.pixelWidth)
            : CGFloat(metadata.pixelWidth) / CGFloat(metadata.pixelHeight)
    }

    var body: some View {
        GeometryReader { geometry in
            // Figma 402×874: 사진 y146, 402×536. 내비게이션/안전 영역은 중복 가산하지 않는다.
            let photoHeight = min(geometry.size.width * 4 / 3, geometry.size.height)
            let topSpacing = min(max(0, 146 * geometry.size.width / 402 - geometry.frame(in: .global).minY),
                                 max(0, geometry.size.height - photoHeight))
            VStack(spacing: 0) {
                Spacer().frame(height: topSpacing)
                CameraPhotoView(source: photo.source, contentMode: .fit, onLoad: { imageAvailable = $0 })
                    .aspectRatio(photoAspectRatio, contentMode: .fit)
                    .accessibilityLabel("확대 사진")
                    .accessibilityIdentifier("camera.selectionPreviewImage")
                    .overlay {
                        if imageAvailable == false { Text("사진을 불러올 수 없어요.").foregroundStyle(.white) }
                    }
                    .overlay(alignment: .topTrailing) { selectionButton.padding(8) }
                    .frame(width: geometry.size.width, height: photoHeight)
                Spacer(minLength: 0)
            }
        }
        .background(background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(.black)
                }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .tint(.white.opacity(0.5))
                    .accessibilityLabel("사진 선택으로 돌아가기")
                    .accessibilityIdentifier("camera.closeSelectionPreview")
            }
        }
        .overlay { ProductPhotoSelectionNotice(requestID: $selectionLimitNoticeID) }
        .onDisappear { selectionLimitNoticeID = nil }
    }

    private var selectionButton: some View {
        Button {
            switch model.toggleSelection(photo.id) {
            case .limitReached: selectionLimitNoticeID = UUID()
            case .updated: selectionLimitNoticeID = nil
            case .ignored: break
            }
        } label: {
            Text(order.map(String.init) ?? "")
                .font(.title3.weight(.medium)).foregroundStyle(Color(white: 0.15))
                .frame(width: 45, height: 45)
                .background(order == nil ? .white.opacity(0.32) : Color(white: 205 / 255), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(order == nil ? 0.57 : 0), lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.isCapturing || model.isDeleting || (imageAvailable != true && order == nil))
        .accessibilityLabel(order == nil ? "사진 선택" : "사진 선택 해제")
        .accessibilityValue(order.map { "\($0)번째 선택" } ?? "선택 안 됨")
        .accessibilityAddTraits(order == nil ? [] : .isSelected)
        .accessibilityIdentifier("camera.selectionPreviewToggle")
    }
}

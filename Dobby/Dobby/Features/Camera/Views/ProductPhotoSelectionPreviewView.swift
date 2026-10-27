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

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                CameraPhotoView(source: photo.source, contentMode: .fit, onLoad: { imageAvailable = $0 })
                    .frame(height: min(geometry.size.width * 4 / 3, max(0, geometry.size.height - 12)))
                    .accessibilityLabel("확대 사진")
                    .accessibilityIdentifier("camera.selectionPreviewImage")
                    .overlay {
                        if imageAvailable == false { Text("사진을 불러올 수 없어요.").foregroundStyle(.white) }
                    }
                    .overlay(alignment: .topTrailing) { selectionButton.padding(8) }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .background(background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(.black)
                }
                    .buttonStyle(.borderedProminent).tint(.white.opacity(0.5))
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

// Created by mason on 10/20/26.
import SwiftUI

private struct GalleryDeleteBarBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 촬영 순서대로 열람한다. 탐색은 판매용 사진 선택·대표 사진을 변경하지 않는다.
struct DetailPhotoGalleryView: View {
    let model: ProductPhotoModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusedID: String
    @State private var deletionTarget: UUID?
    @State private var isDeletingPhoto = false
    @State private var isChangingPhoto = false
    @State private var deletionError: String?

    init(model: ProductPhotoModel) {
        self.model = model
        _focusedID = State(initialValue: (model.photos.last ?? model.selectablePhotos.last)?.id.uuidString ?? "")
    }

    private struct Item: Identifiable {
        let photo: CapturedAsset
        var annotated = false
        var id: String { photo.id.uuidString }
        var label: String { annotated ? "실측값 표시 사진" : photo.purpose == .measurement ? "실측 원본 사진" : "상세 사진" }
    }

    private var items: [Item] {
        model.selectablePhotos.map { Item(photo: $0, annotated: $0.purpose == .measurementVisualization) }
    }

    @ViewBuilder private func photoView(_ item: Item, thumbnail: Bool = false) -> some View {
        if item.annotated, let record = model.measurementRecord {
            MeasurementGalleryPhotoView(record: record, isThumbnail: thumbnail)
        } else {
            CameraPhotoView(source: item.photo.source, maximumPixelSize: thumbnail ? 192 : 1600,
                            contentMode: thumbnail ? .fill : .fit)
        }
    }

    var body: some View {
        // Keep the popover outside the hidden content subtree. SwiftUI's
        // preference overlay must not inherit the gallery controls' AX state.
        ZStack {
            galleryContent.accessibilityHidden(deletionTarget != nil)
        }
        .overlayPreferenceValue(GalleryDeleteBarBounds.self) { bounds in
            if let bounds {
                GeometryReader { geometry in
                    // 확인창 하단을 구분선에 맞추고 취소 영역은 하단 버튼까지 덮는다.
                    DetailPhotoDeleteConfirmation(isPresented: deletionTarget != nil, isDeleting: isDeletingPhoto,
                        bottomInset: max(0, geometry.size.height - geometry[bounds].minY),
                        onCancel: { deletionTarget = nil }, onDelete: deletePhoto)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .preferredColorScheme(.light)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("촬영으로 돌아가기", systemImage: "chevron.left") {
                    closeGallery()
                }
                .labelStyle(.iconOnly)
                .accessibilityHidden(deletionTarget != nil)
                .accessibilityIdentifier("camera.galleryClose")
            }
        }
        .tint(.primary)
        .interactiveDismissDisabled(deletionTarget != nil || isDeletingPhoto || isChangingPhoto)
        .alert("사진을 삭제하지 못했어요", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("확인", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "다시 시도해 주세요.")
        }
    }

    private var galleryContent: some View {
        GeometryReader { geometry in
            // Figma 402×874: 사진 y169/높이536, 썸네일 중심 y764, 하단 구분선 y788.
            // 좁거나 낮은 화면에서는 사진 영역부터 줄여 하단 조작 영역을 유지한다.
            let stripHeight: CGFloat = 44
            let stripGap: CGFloat = 37
            let height = min(geometry.size.width * 4 / 3,
                max(0, geometry.size.height - stripHeight - stripGap))
            VStack(spacing: 0) {
                Spacer().frame(height: min(max(0, geometry.size.height - height - stripHeight - stripGap),
                    max(0, 169 * geometry.size.width / 402 - geometry.frame(in: .global).minY)))
                DetailPhotoGalleryPager(items: items, focusedID: $focusedID, reduceMotion: reduceMotion,
                    onTransitionChanged: { isChangingPhoto = $0 }) { item in
                    photoView(item)
                        .accessibilityLabel(item.label)
                        .accessibilityHint("위아래로 쓸어 사진을 바꾸거나 동작 메뉴에서 이전 사진, 다음 사진, 삭제를 선택합니다.")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: movePhoto(by: 1)
                            case .decrement: movePhoto(by: -1)
                            @unknown default: break
                            }
                        }
                        .accessibilityAction(named: Text("이전 사진")) { movePhoto(by: -1) }
                        .accessibilityAction(named: Text("다음 사진")) { movePhoto(by: 1) }
                        .accessibilityAction(named: Text("현재 사진 삭제"), requestPhotoDeletion)
                        .accessibilityAction(.escape, closeGallery)
                }
                .frame(height: height)
                .allowsHitTesting(deletionTarget == nil && !isDeletingPhoto)
                .accessibilityIdentifier("camera.galleryPager")
                .accessibilityValue("\((items.firstIndex { $0.id == focusedID } ?? 0) + 1) / \(items.count)")
                thumbnailStrip(width: geometry.size.width)
                    .allowsHitTesting(deletionTarget == nil && !isDeletingPhoto && !isChangingPhoto)
                    .padding(.top, stripGap)
                Spacer(minLength: 0)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 사진 탐색 영역과 하단 동작 영역을 분리한다.
            Color.clear.frame(height: 52)
                .anchorPreference(key: GalleryDeleteBarBounds.self, value: .bounds) { $0 }
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(.separator)).frame(height: 1 / displayScale)
                }
                .overlay(alignment: .trailing) {
                    Button(action: requestPhotoDeletion) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeletingPhoto || isChangingPhoto || model.isDeleting || model.isCapturing || items.isEmpty)
                    .accessibilityLabel("현재 사진 삭제")
                    .accessibilityIdentifier("camera.galleryDelete")
                    .padding(.trailing, 28).offset(y: 8)
                }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func thumbnailStrip(width: CGFloat) -> some View {
        DetailPhotoFilmstrip(ids: items.map(\.id), focusedID: $focusedID, width: width) { index in
            if items.indices.contains(index) { thumbnail(items[index], index: index) }
        }
    }

    private func movePhoto(by offset: Int) {
        guard deletionTarget == nil, !isDeletingPhoto, !isChangingPhoto,
              let index = items.firstIndex(where: { $0.id == focusedID }),
              items.indices.contains(index + offset) else { return }
        let destination = items[index + offset]
        focusedID = destination.id
        VoiceOverAnnouncement.post("\(items.count)장 중 \(index + offset + 1)번째, \(destination.label)")
    }

    private func requestPhotoDeletion() {
        guard deletionTarget == nil, !isDeletingPhoto, !isChangingPhoto,
              !model.isDeleting, !model.isCapturing, !items.isEmpty else { return }
        deletionTarget = UUID(uuidString: focusedID)
    }

    private func closeGallery() {
        guard deletionTarget == nil, !isDeletingPhoto, !isChangingPhoto else { return }
        dismiss()
    }

    private func deletePhoto() {
        guard let target = deletionTarget, !isDeletingPhoto,
              let index = items.firstIndex(where: { $0.photo.id == target }) else { return }
        isDeletingPhoto = true
        Task { @MainActor in
            defer { isDeletingPhoto = false; deletionTarget = nil }
            do {
                try await model.deletePhoto(target)
                let remaining = items
                if remaining.isEmpty {
                    dismiss()
                } else {
                    focusedID = remaining[min(index, remaining.count - 1)].id
                }
                VoiceOverAnnouncement.post("사진을 삭제했습니다. 남은 사진 \(remaining.count)장")
            } catch {
                deletionError = error.localizedDescription
            }
        }
    }

    private func thumbnail(_ item: Item, index: Int) -> some View {
        let photo = item.photo
        let detailNumber = (model.detailPhotos.firstIndex { $0.id == photo.id } ?? 0) + 1
        let focused = focusedID == item.id
        return Button { focusedID = item.id } label: {
            photoView(item, thumbnail: true).accessibilityHidden(true)
                .frame(width: focused ? 30 : 20, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label + (photo.purpose == .detail ? " \(detailNumber)" : ""))
        .accessibilityValue(focused ? "현재 보는 사진" : "")
        .accessibilityHint("전체 \(items.count)장 중 \(index + 1)번째 사진을 표시합니다.")
        .accessibilityAddTraits(focused ? .isSelected : [])
        .accessibilityIdentifier("camera.galleryThumbnail.\(index)")
    }
}

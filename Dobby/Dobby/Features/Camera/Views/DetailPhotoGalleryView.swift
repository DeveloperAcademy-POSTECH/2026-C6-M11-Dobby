// Created by mason on 10/20/26.
import SwiftUI

/// 촬영 순서대로 열람한다. 탐색은 판매용 사진 선택·대표 사진을 변경하지 않는다.
struct DetailPhotoGalleryView: View {
    let model: ProductPhotoModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var focusedID: String

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
                TabView(selection: $focusedID) {
                    ForEach(items) { item in
                        photoView(item)
                            .tag(item.id)
                            .accessibilityLabel(item.label)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: height)
                .accessibilityIdentifier("camera.galleryPager")
                .accessibilityValue("\((items.firstIndex { $0.id == focusedID } ?? 0) + 1) / \(items.count)")
                thumbnailStrip(width: geometry.size.width).padding(.top, stripGap)
                Spacer(minLength: 0)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 사진 탐색 영역과 하단 동작 영역을 분리한다.
            Color.clear.frame(height: 52)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(.separator)).frame(height: 1 / displayScale)
                }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .preferredColorScheme(.light)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("촬영으로 돌아가기", systemImage: "chevron.left") { dismiss() }.labelStyle(.iconOnly)
            }
        }
        .tint(.primary)
    }

    private func thumbnailStrip(width: CGFloat) -> some View {
        DetailPhotoFilmstrip(ids: items.map(\.id), focusedID: $focusedID, width: width) { index in
            thumbnail(items[index], index: index)
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
        .accessibilityAddTraits(focused ? .isSelected : [])
        .accessibilityIdentifier("camera.galleryThumbnail.\(index)")
    }
}

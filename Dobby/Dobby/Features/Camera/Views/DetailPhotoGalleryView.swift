// Created by mason on 10/20/26.
import SwiftUI

/// 삭제 없이 촬영 순서대로 열람한다. 탐색은 판매용 사진 선택·대표 사진을 변경하지 않는다.
struct DetailPhotoGalleryView: View {
    let model: ProductPhotoModel
    @Environment(\.dismiss) private var dismiss
    @State private var focusedID: String

    init(model: ProductPhotoModel) {
        self.model = model
        _focusedID = State(initialValue: (model.photos.last ?? model.input.measurement).id.uuidString)
    }

    private struct Item: Identifiable {
        let photo: CapturedAsset
        var annotated = false
        var id: String { photo.id.uuidString + (annotated ? "-measurement" : "") }
        var label: String { annotated ? "실측값 표시 사진" : photo.purpose == .measurement ? "실측 원본 사진" : "상세 사진" }
    }

    private var items: [Item] {
        [Item(photo: model.input.measurement)]
        + (model.measurementRecord == nil ? [] : [Item(photo: model.input.measurement, annotated: true)])
        + model.detailPhotos.map { Item(photo: $0) }
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
            // Figma 402×874: 사진 y171, 402×536, 하단 썸네일 y764.
            let height = min(geometry.size.width * 4 / 3, max(0, geometry.size.height - 132))
            VStack(spacing: 0) {
                Spacer().frame(height: min(max(0, geometry.size.height - height - 112),
                    max(0, 171 * geometry.size.width / 402 - geometry.frame(in: .global).minY)))
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
                thumbnailStrip(width: geometry.size.width).padding(.top, 35)
                Spacer(minLength: 0)
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
        let detailNumber = index - (model.measurementRecord == nil ? 0 : 1)
        let focused = focusedID == item.id
        return Button { focusedID = item.id } label: {
            photoView(item, thumbnail: true).accessibilityHidden(true)
                .frame(width: focused ? 40 : 22, height: focused ? 40 : 36)
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

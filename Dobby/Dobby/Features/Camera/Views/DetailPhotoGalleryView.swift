// Created by mason on 10/20/26.
import SwiftUI

/// 촬영 순서대로 열람한다. 탐색은 판매용 사진 선택·대표 사진을 변경하지 않는다.
struct DetailPhotoGalleryView: View {
    let model: ProductPhotoModel
    @Environment(\.dismiss) private var dismiss
    @State private var focusedID: String
    @State private var pendingDeletion: CapturedAsset?
    @State private var deletionID: UUID?
    @State private var failureMessage: String?

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
        .disabled(deletionID != nil || model.isDeleting)
        .overlay { if deletionID != nil { ProgressView("사진 삭제 중").padding().background(.regularMaterial) } }
        .alert("상세 사진을 삭제할까요?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("삭제", role: .destructive) { deletionID = pendingDeletion?.id; pendingDeletion = nil }
            Button("취소", role: .cancel) { pendingDeletion = nil }
        } message: { Text("삭제한 상세 사진은 복구할 수 없어요. 실측 사진은 유지됩니다.") }
        .alert("사진을 삭제하지 못했어요", isPresented: Binding(
            get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }
        )) {
            Button("확인", role: .cancel) { failureMessage = nil }
        } message: { Text(failureMessage ?? "다시 시도해 주세요.") }
        .task(id: deletionID) {
            guard let id = deletionID else { return }
            defer { deletionID = nil }
            let index = items.firstIndex { $0.id == id.uuidString } ?? 0
            do {
                try await model.deleteDetail(id)
                if focusedID == id.uuidString { focusedID = items[min(index, items.count - 1)].id }
            } catch {
                if !(error is CancellationError) { failureMessage = "사진은 그대로 유지돼요. 삭제 버튼을 눌러 다시 시도해 주세요." }
            }
        }
    }

    private func thumbnailStrip(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        thumbnail(item, index: index)
                    }
                }
                .padding(.horizontal, max(0, width / 2 - 28))
            }
            .onChange(of: focusedID, initial: true) { _, id in proxy.scrollTo("photo-\(id)", anchor: .center) }
        }
        .frame(height: 77)
        .accessibilityIdentifier("camera.galleryStrip")
    }

    private func thumbnail(_ item: Item, index: Int) -> some View {
        let photo = item.photo
        let detailNumber = index - (model.measurementRecord == nil ? 0 : 1)
        let width: CGFloat = focusedID == item.id ? 56 : 36
        return ZStack(alignment: .topLeading) {
            Button { focusedID = item.id } label: {
                photoView(item, thumbnail: true).accessibilityHidden(true)
                    .frame(width: width, height: 55).clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(minWidth: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).offset(y: 22)
            .id("photo-\(item.id)")
            .accessibilityLabel(item.label + (photo.purpose == .measurement ? ", 삭제 불가" : " \(detailNumber)"))
            .accessibilityValue(focusedID == item.id ? "현재 보는 사진" : "")
            .accessibilityIdentifier("camera.galleryThumbnail.\(index)")
            if photo.purpose == .detail {
                Button { pendingDeletion = photo } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 20, height: 20)
                        .background(Color(white: 0.12), in: Circle())
                        .overlay { Circle().strokeBorder(.white, lineWidth: 1.2) }
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).offset(x: width - 22)
                .accessibilityLabel("상세 사진 \(detailNumber) 삭제")
                .accessibilityIdentifier("camera.galleryDelete.\(index)")
            }
        }
        // 우상단 꼭지점의 삭제 버튼 터치 영역을 확보해 인접 사진과 겹치지 않는다.
        .frame(width: width + 22, height: 77, alignment: .topLeading)
    }
}

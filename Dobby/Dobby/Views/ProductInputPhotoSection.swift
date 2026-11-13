import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct ProductInputPhotoSection: View {
    let garment: Garment
    var allowsEditing = false
    // Entry and archive editing both allow removal. The edit-mode flag only
    // controls the existing spacing; it must not rename entry as editing.
    var allowsRemoval = true
    var onImportingChange: ((Bool) -> Void)? = nil
    @Environment(\.modelContext) private var context
    @State private var expandedPhoto: GarmentPhoto?
    @State private var showsDeletionError = false
    @State private var showsPhotoPicker = false
    @State private var showsCamera = false
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: allowsEditing ? 8 : (allowsRemoval ? 4 : 8)) {
            HStack {
                ProductFieldTitle(title: "제품 사진", isRequired: true)
                Spacer()
                HStack(spacing: 0) {
                    Text("\(garment.productPhotos.count)")
                        .foregroundStyle(garment.productPhotos.count > ProductPhotoLimit.maximumCount
                            ? ProductInformationStyle.error : Color(allowsEditing ? "BrandNeutral500" : "BrandNeutral800"))
                    Text("/\(ProductPhotoLimit.maximumCount)").foregroundStyle(Color("BrandNeutral500"))
                }
                .font(.custom(allowsEditing ? "Pretendard-Medium" : "Pretendard-Regular", size: allowsEditing ? 16 : 14, relativeTo: .subheadline))
                .tracking(allowsEditing ? -0.16 : 0)
                .accessibilityLabel("제품 사진 \(garment.productPhotos.count)장, 최대 \(ProductPhotoLimit.maximumCount)장")
                .accessibilityIdentifier("product-info.photo-count")
            }
            .frame(minHeight: allowsEditing ? 22 : nil)
            photoRow.padding(.horizontal, -20)
        }
        .fullScreenCover(item: $expandedPhoto) { photo in
            ProductPhotoGalleryView(photos: garment.productPhotos, initialPhotoID: photo.id,
                                    style: allowsEditing ? .editing : .standard,
                                    onDelete: deletionAction, onRotate: { id in
                                        guard let photo = garment.productPhotos.first(where: { $0.id == id }) else { return false }
                                        try await GarmentStore.rotateProductPhoto(photo, in: garment, clockwise: false)
                                        return true
                                    })
                .presentationBackground(.clear)
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: photoPickerSelection,
                      maxSelectionCount: max(1, remainingCapacity), matching: .images)
        .fullScreenCover(isPresented: $showsCamera) {
            ProductInputCameraPicker { data in
                showsCamera = false
                guard let data else { return }
                setImporting(true)
                importTask = Task { await importPhotos([data]) }
            }
            .ignoresSafeArea()
        }
        .onDisappear {
            importTask?.cancel()
            onImportingChange?(false)
        }
        .task(id: pickedItems) {
            guard !pickedItems.isEmpty else { return }
            let items = pickedItems
            setImporting(true)
            defer { setImporting(false); pickedItems = [] }
            do {
                for item in items {
                    try Task.checkCancellation()
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw GarmentStore.StoreError.encodingFailed
                    }
                    try await appendPhoto(data)
                }
            } catch is CancellationError { } catch { importError = error.localizedDescription }
        }
        .alert("사진을 추가하지 못했어요", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("확인", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "입력한 정보와 기존 사진은 그대로 남아 있어요.") }
        .alert("사진을 삭제하지 못했어요", isPresented: $showsDeletionError) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("사진은 그대로 남아 있어요. 다시 시도해 주세요.")
        }
    }

    private var photoPickerSelection: Binding<[PhotosPickerItem]> {
        Binding(get: { pickedItems }, set: { items in
            // Lock the parent before PhotosPicker dismisses, not in a later
            // view update that could let Done race the asynchronous import.
            if !items.isEmpty { setImporting(true) }
            pickedItems = items
        })
    }

    private func setImporting(_ busy: Bool) {
        onImportingChange?(busy)
        isImporting = busy
    }

    private var remainingCapacity: Int {
        max(0, ProductPhotoModel.maximumSelectionCount - garment.productPhotos.count)
    }

    private var photoRow: some View {
        ProductPhotoReorderStrip(photos: garment.productPhotos, spacing: 16,
            topInset: allowsRemoval ? 4 : 0,
            onReorder: { GarmentStore.reorderProductPhotos(ids: $0, in: garment) },
            leadingContent: AnyView(addPhotoButton)) { photo in
                photoCell(photo)
                    .accessibilityHint("길게 누른 뒤 좌우로 드래그해 순서를 바꿀 수 있어요")
                    .accessibilityAction(named: "앞으로 이동") { movePhoto(photo.id, offset: -1) }
                    .accessibilityAction(named: "뒤로 이동") { movePhoto(photo.id, offset: 1) }
            }
            .frame(height: 108 + (allowsRemoval ? 4 : 0))
            .accessibilityIdentifier("product-info.photo-strip")
    }

    private var addPhotoButton: some View {
        Menu {
            Button("사진 촬영하기", systemImage: "camera.fill") { showsCamera = true }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("앨범에서 선택하기", systemImage: "photo") { showsPhotoPicker = true }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 18))
                Text("사진 추가").font(.custom(allowsEditing ? "Pretendard-Medium" : "Pretendard-Regular", size: 12, relativeTo: .caption))
                    .tracking(allowsEditing ? -0.12 : 0)
            }
            .foregroundStyle(Color(allowsEditing ? "BrandNeutral400" : "BrandNeutral500"))
            .frame(width: 77, height: 108)
            .background(Color("BrandNeutral50"), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color("BrandNeutral200"), lineWidth: allowsEditing ? 1 : 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .disabled(remainingCapacity == 0 || isImporting)
        .accessibilityLabel("제품 사진 추가")
        .accessibilityIdentifier("product-info.add-photo")
    }

    private func importPhotos(_ data: [Data]) async {
        defer { setImporting(false) }
        do { for bytes in data { try await appendPhoto(bytes) } }
        catch is CancellationError { } catch { importError = error.localizedDescription }
    }

    private func appendPhoto(_ data: Data) async throws {
        try await ProductPhotoImportStore.append(data, to: garment, in: context)
    }

    @ViewBuilder private func photoCell(_ photo: GarmentPhoto) -> some View {
        if allowsRemoval {
            ProductInputEditablePhoto(photo: photo, onExpand: { expand(photo) },
                                      onDelete: { deletePhoto(photo.id) })
        } else {
            Button { expand(photo) } label: {
                ProductInputPhotoImage(photo: photo)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("제품 사진 확대")
            .accessibilityIdentifier("product-info.photo.\(photo.id)")
        }
    }

    private func movePhoto(_ id: UUID, offset: Int) {
        var ids = garment.productPhotos.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        let moved = ids.remove(at: index)
        ids.insert(moved, at: index + offset)
        if GarmentStore.reorderProductPhotos(ids: ids, in: garment) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func expand(_ photo: GarmentPhoto) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { expandedPhoto = photo }
    }

    private func removePhoto(_ id: UUID) throws -> Bool {
        try GarmentStore.removeProductPhoto(id: id, from: garment, in: context, persist: { _ in })
    }

    private var deletionAction: ((UUID) throws -> Bool)? {
        guard allowsRemoval else { return nil }
        return { id in try removePhoto(id) }
    }

    private func deletePhoto(_ id: UUID) {
        do { _ = try removePhoto(id) } catch { showsDeletionError = true }
    }
}

private struct ProductInputEditablePhoto: View {
    let photo: GarmentPhoto
    let onExpand: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onExpand) {
            ProductInputPhotoImage(photo: photo)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("제품 사진 확대")
        .accessibilityIdentifier("product-info.photo.\(photo.id)")
        .overlay(alignment: .topTrailing) {
            Button(action: onDelete) {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                    Image(systemName: "minus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Color("BrandNeutral700"), in: Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("제품 사진 삭제")
            .accessibilityIdentifier("product-info.delete-photo.\(photo.id)")
            // The visible badge overhangs by four points, while the hit area
            // stays out of the next thumbnail (including the eight-point gap).
            .offset(x: 4, y: -3)
        }
    }
}

private struct ProductInputPhotoImage: View {
    let photo: GarmentPhoto
    private let presentation = ProductDetailPhotoPresentation.compact

    var body: some View {
        StoredProductPhotoView(photo: photo, maximumPixelSize: 320, contentMode: .fill)
            .frame(width: presentation.size.width, height: presentation.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

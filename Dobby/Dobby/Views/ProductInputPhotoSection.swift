import SwiftData
import SwiftUI

struct ProductInputPhotoSection: View {
    let garment: Garment
    var allowsEditing = false
    // Entry and archive editing both allow removal. The edit-mode flag only
    // controls the existing spacing; it must not rename entry as editing.
    var allowsRemoval = true
    @Environment(\.modelContext) private var context
    @State private var expandedPhoto: GarmentPhoto?
    @State private var showsDeletionError = false

    var body: some View {
        VStack(alignment: .leading, spacing: allowsRemoval ? 4 : 8) {
            ProductFieldTitle(title: "제품 사진")
            ScrollView(.horizontal, showsIndicators: false) {
                photoRow.padding(.horizontal, 20)
                    .padding(.top, allowsRemoval ? 4 : 0)
            }
            .padding(.horizontal, -20)
        }
        .fullScreenCover(item: $expandedPhoto) { photo in
            ProductPhotoGalleryView(photos: garment.productPhotos, initialPhotoID: photo.id,
                                    onDelete: deletionAction)
                .presentationBackground(.clear)
        }
        .alert("사진을 삭제하지 못했어요", isPresented: $showsDeletionError) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("사진은 그대로 남아 있어요. 다시 시도해 주세요.")
        }
    }

    @ViewBuilder private var photoRow: some View {
        if garment.productPhotos.isEmpty {
            Text("제품 사진이 없어요")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(height: ProductDetailPhotoPresentation.compact.size.height)
                .accessibilityIdentifier("product-info.photos.empty")
        } else {
            HStack(spacing: allowsEditing ? 16 : 8) {
                ForEach(garment.productPhotos) { photo in
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
            }
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
            .clipShape(RoundedRectangle(cornerRadius: presentation.cornerRadius))
    }
}

import SwiftData
import SwiftUI

struct ProductInputPhotoSection: View {
    let garment: Garment
    var allowsEditing = false
    @Environment(\.modelContext) private var context
    @State private var expandedPhoto: GarmentPhoto?
    @State private var showsDeletionError = false

    var body: some View {
        VStack(alignment: .leading, spacing: allowsEditing ? 4 : 8) {
            ProductFieldTitle(title: "제품 사진")
            ScrollView(.horizontal, showsIndicators: false) {
                photoRow.padding(.horizontal, 20)
                    .padding(.top, allowsEditing ? 4 : 0)
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
                    if allowsEditing {
                        ProductInputEditablePhoto(photo: photo, onExpand: { expand(photo) },
                                                  onDelete: { deletePhoto(photo.id) })
                    } else {
                        ProductInputPhotoImage(photo: photo)
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
        try GarmentStore.removeProductPhoto(id: id, from: garment, in: context)
    }

    private var deletionAction: ((UUID) throws -> Bool)? {
        guard allowsEditing else { return nil }
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
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color("BrandNeutral700"), in: Circle())
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("제품 사진 삭제")
            .accessibilityIdentifier("product-info.delete-photo.\(photo.id)")
            .offset(x: 17.5, y: -16)
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

import Foundation

struct InstagramDraftPhoto: Identifiable {
    let id: UUID
    let data: Data

    init(id: UUID = UUID(), data: Data) {
        self.id = id
        self.data = data
    }
}

struct InstagramExportDraft {
    private let originalPhotos: [InstagramDraftPhoto]
    private let originalCaption: String
    var photos: [InstagramDraftPhoto]
    var caption: String

    init(product: ExportProduct) {
        let photos = product.displayPhotos.map { InstagramDraftPhoto(data: $0) }
        let payload = product.instagram
        let caption = [payload.productName, payload.description, payload.brand,
                       payload.measurements, payload.price.isEmpty ? "" : "가격: \(payload.price)원"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        originalPhotos = photos
        originalCaption = caption
        self.photos = photos
        self.caption = caption
    }

    mutating func removePhoto(id: UUID) { photos.removeAll { $0.id == id } }
    mutating func resetPhotos() { photos = originalPhotos }
    mutating func resetCaption() { caption = originalCaption }
}

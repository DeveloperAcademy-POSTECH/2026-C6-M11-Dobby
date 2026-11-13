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
    static let maximumCaptionLength = 2200

    private let originalCaption: String
    let photos: [InstagramDraftPhoto]
    var caption: String

    var validationMessage: String? {
        if photos.isEmpty { return "업로드할 사진을 1장 이상 선택해 주세요." }
        if photos.count > InstagramIntegrationClient.maximumImageCount {
            return "인스타그램에는 사진을 최대 \(InstagramIntegrationClient.maximumImageCount)장까지 올릴 수 있어요."
        }
        if caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "캡션을 입력해 주세요."
        }
        if caption.utf16.count > Self.maximumCaptionLength {
            return "캡션은 \(Self.maximumCaptionLength)자까지 입력할 수 있어요."
        }
        return nil
    }

    var canPublish: Bool { validationMessage == nil }

    init(product: ExportProduct) {
        let photos = product.exportPhotos.map { InstagramDraftPhoto(data: $0) }
        let payload = product.instagramPayload
        let formattedPrice = Int(payload.price)?.formatted(
            .number.locale(Locale(identifier: "ko_KR")).grouping(.automatic)
        ) ?? payload.price
        let caption = [payload.productName, payload.description, payload.brand,
                       payload.measurements, formattedPrice.isEmpty ? "" : "가격: \(formattedPrice)원"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        originalCaption = caption
        self.photos = photos
        self.caption = caption
    }

    mutating func resetCaption() {
        caption = originalCaption
    }
}

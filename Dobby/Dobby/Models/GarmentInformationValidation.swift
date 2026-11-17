import Foundation

@MainActor
enum GarmentInformationValidation {
    static func hasAnyInformation(_ garment: Garment) -> Bool {
        [garment.name, garment.detail, garment.brand].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } || garment.price != nil
    }

    // Partial information still enables a tap to reveal required-field errors.
    // Overflow must be repaired before that completion attempt is available.
    static func canAttemptCompletion(_ garment: Garment) -> Bool {
        hasAnyInformation(garment) && garment.productPhotos.count <= ProductPhotoLimit.maximumCount
    }

    static func isNameValid(_ garment: Garment) -> Bool {
        !garment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && garment.name.count <= ProductTextLimit.name
    }

    static func isDetailValid(_ garment: Garment) -> Bool {
        !garment.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && garment.detail.count <= ProductTextLimit.detail
    }

    static func nameErrorMessage(for garment: Garment) -> String {
        garment.name.count > ProductTextLimit.name
            ? "제품명은 \(ProductTextLimit.name)자 이내로 입력해주세요"
            : "제품명을 입력해주세요"
    }

    static func detailErrorMessage(for garment: Garment) -> String {
        garment.detail.count > ProductTextLimit.detail
            ? "설명은 \(ProductTextLimit.detail)자 이내로 입력해주세요"
            : "설명을 입력해주세요"
    }

    static func isPriceValid(_ garment: Garment) -> Bool {
        garment.price.map { $0 > 0 } ?? false
    }

    static func isValid(_ garment: Garment) -> Bool {
        isNameValid(garment) && isDetailValid(garment) && isPriceValid(garment)
            && ProductPhotoLimit.canRegister(count: garment.productPhotos.count)
    }

    static func validate(_ garment: Garment) throws {
        guard !garment.productPhotos.isEmpty else {
            throw GarmentInputCompletion.ValidationError.missingInformation("제품 사진")
        }
        guard garment.productPhotos.count <= ProductPhotoLimit.maximumCount else {
            throw ProductPhotoLimit.ValidationError.tooManyPhotos
        }
        for (label, text, maximumLength) in [
            ("제품명", garment.name, ProductTextLimit.name),
            ("설명", garment.detail, ProductTextLimit.detail)
        ] {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw GarmentInputCompletion.ValidationError.missingInformation(label)
            }
            if text.count > maximumLength {
                throw GarmentInputCompletion.ValidationError.missingInformation("\(label) \(maximumLength)자 이내")
            }
        }
        guard let price = garment.price, price > 0 else {
            throw GarmentInputCompletion.ValidationError.missingInformation("가격")
        }
    }
}

import Foundation

@MainActor
enum GarmentInformationValidation {
    static func hasAnyInformation(_ garment: Garment) -> Bool {
        [garment.name, garment.detail, garment.brand].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } || garment.price != nil
    }

    static func isNameValid(_ garment: Garment) -> Bool {
        !garment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isDetailValid(_ garment: Garment) -> Bool {
        !garment.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isPriceValid(_ garment: Garment) -> Bool {
        garment.price.map { $0 > 0 } ?? false
    }

    static func isValid(_ garment: Garment) -> Bool {
        isNameValid(garment) && isDetailValid(garment) && isPriceValid(garment)
    }

    static func validate(_ garment: Garment) throws {
        for (label, text) in [("제품명", garment.name), ("설명", garment.detail)] {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw GarmentInputCompletion.ValidationError.missingInformation(label)
            }
        }
        guard let price = garment.price, price > 0 else {
            throw GarmentInputCompletion.ValidationError.missingInformation("가격")
        }
    }
}

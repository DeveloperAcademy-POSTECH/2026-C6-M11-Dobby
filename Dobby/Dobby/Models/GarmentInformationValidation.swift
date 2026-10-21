import Foundation

@MainActor
enum GarmentInformationValidation {
    static func isValid(_ garment: Garment) -> Bool {
        (try? validate(garment)) != nil
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

import Foundation

/// 제품 정보 편집을 시작할 때 저장 상태를 보관하고, 완료하지 않은 변경만 되돌립니다.
struct ProductInformationEditSnapshot: Equatable {
    private struct PhotoState: Equatable {
        let id: UUID
        let isSelectedForProduct: Bool?
        let roleRaw: String
        let order: Int
    }

    private struct MeasurementState: Equatable {
        let id: UUID
        let valueBitPattern: UInt64
        let isEdited: Bool
    }

    private let name: String
    private let brand: String
    private let detail: String
    private let price: Int?
    private let updatedAt: Date
    private let lengthCm: Double?
    private let shoulderCm: Double?
    private let chestCm: Double?
    private let sleeveCm: Double?
    private let waistCm: Double?
    private let photos: [PhotoState]
    private let measurements: [MeasurementState]
    private let measurementInput: GarmentMeasurementInputState

    init(garment: Garment, measurementInput: GarmentMeasurementInputState) {
        name = garment.name
        brand = garment.brand
        detail = garment.detail
        price = garment.price
        updatedAt = garment.updatedAt
        lengthCm = garment.lengthCm
        shoulderCm = garment.shoulderCm
        chestCm = garment.chestCm
        sleeveCm = garment.sleeveCm
        waistCm = garment.waistCm
        photos = garment.photos.map {
            PhotoState(id: $0.id, isSelectedForProduct: $0.isSelectedForProduct, roleRaw: $0.roleRaw, order: $0.order)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        measurements = garment.measurements.map {
            MeasurementState(id: $0.id, valueBitPattern: $0.valueCm.bitPattern, isEdited: $0.isEdited)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        self.measurementInput = measurementInput
    }

    func hasChanges(in garment: Garment, measurementInput: GarmentMeasurementInputState) -> Bool {
        self != ProductInformationEditSnapshot(garment: garment, measurementInput: measurementInput)
    }

    func restore(_ garment: Garment, measurementInput: inout GarmentMeasurementInputState) {
        garment.name = name
        garment.brand = brand
        garment.detail = detail
        garment.price = price
        garment.lengthCm = lengthCm
        garment.shoulderCm = shoulderCm
        garment.chestCm = chestCm
        garment.sleeveCm = sleeveCm
        garment.waistCm = waistCm

        let photoStates = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        for photo in garment.photos {
            guard let state = photoStates[photo.id] else { continue }
            photo.isSelectedForProduct = state.isSelectedForProduct
            photo.roleRaw = state.roleRaw
            photo.order = state.order
        }

        let measurementStates = Dictionary(uniqueKeysWithValues: measurements.map { ($0.id, $0) })
        for measurement in garment.measurements {
            guard let state = measurementStates[measurement.id] else { continue }
            measurement.valueCm = Double(bitPattern: state.valueBitPattern)
            measurement.isEdited = state.isEdited
        }

        garment.updatedAt = updatedAt
        measurementInput = self.measurementInput
    }
}

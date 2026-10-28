import Foundation
import Testing
@testable import Dobby

@MainActor
struct ProductInformationEditSnapshotTests {
    @Test func detectsAndRestoresTextMeasurementAndPhotoChanges() {
        let garment = makeGarment()
        let photo = garment.photos[0]
        let measurement = garment.measurements[0]
        var input = GarmentMeasurementInputState()
        let snapshot = ProductInformationEditSnapshot(garment: garment, measurementInput: input)

        garment.name = "B"
        photo.isSelectedForProduct = false
        photo.role = .detail
        input.setText("61.2", for: measurement)
        measurement.update(to: 61.2)

        #expect(snapshot.hasChanges(in: garment, measurementInput: input))
        snapshot.restore(garment, measurementInput: &input)

        #expect(garment.name == "A")
        #expect(photo.isSelectedForProduct == true)
        #expect(photo.role == .thumbnail)
        #expect(measurement.valueCm == 55.4)
        #expect(!measurement.isEdited)
        #expect(!snapshot.hasChanges(in: garment, measurementInput: input))
    }

    @Test func revertingAValueDoesNotRemainDirty() {
        let garment = makeGarment()
        let snapshot = ProductInformationEditSnapshot(
            garment: garment,
            measurementInput: GarmentMeasurementInputState()
        )

        garment.name = "B"
        garment.name = "A"

        #expect(!snapshot.hasChanges(in: garment, measurementInput: GarmentMeasurementInputState()))
    }

    @Test func unchangedNonFiniteMeasurementDoesNotAppearDirty() {
        let garment = makeGarment()
        garment.measurements[0].valueCm = .nan
        let input = GarmentMeasurementInputState()
        let snapshot = ProductInformationEditSnapshot(garment: garment, measurementInput: input)

        #expect(!snapshot.hasChanges(in: garment, measurementInput: input))
    }

    private func makeGarment() -> Garment {
        let garment = Garment(category: "Jacket", group: .top, name: "A",
                              brand: "Nike", detail: "설명", price: 40_000)
        let photo = GarmentPhoto(fileName: "edit-snapshot.jpg", role: .thumbnail,
                                 order: 0, isMeasurementSource: true)
        photo.isSelectedForProduct = true
        photo.garment = garment
        garment.photos = [photo]
        let measurement = MeasuredValue(key: "chestWidth", label: "가슴", displayOrder: 0,
                                        valueCm: 55.4, autoValueCm: 55.4)
        measurement.garment = garment
        garment.measurements = [measurement]
        return garment
    }
}

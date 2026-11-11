import Foundation
import SwiftData
import XCTest
@testable import Dobby

@MainActor
final class StoredMeasurementValueTests: XCTestCase {
    func testProductMeasurementsRoundToWholeCentimeters() {
        XCTAssertEqual(StoredMeasurementValue.centimeters(52.49), 52)
        XCTAssertEqual(StoredMeasurementValue.centimeters(52.5), 53)
        XCTAssertEqual(StoredMeasurementValue.centimeters(52.78), 53)
    }

    func testStoredValueRoundsWhileAutomaticValueKeepsItsPrecision() {
        let automaticValue = 52.78
        let measurement = MeasuredValue(
            key: "chestWidth",
            label: "가슴 단면",
            displayOrder: 0,
            valueCm: StoredMeasurementValue.centimeters(automaticValue),
            autoValueCm: automaticValue
        )

        XCTAssertEqual(measurement.valueCm, 53)
        XCTAssertEqual(measurement.autoValueCm, 52.78)
    }

    func testExistingMeasurementsNormalizeWithoutChangingAutomaticValueOrUpdatedDate() throws {
        let schema = ProductAppStorage.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top)
        let measurement = MeasuredValue(
            key: "chestWidth",
            label: "가슴 단면",
            displayOrder: 0,
            valueCm: 53,
            autoValueCm: 52.78
        )
        measurement.valueCm = 52.7
        measurement.garment = garment
        garment.measurements = [measurement]
        garment.chestCm = 52.7
        let previousUpdatedAt = Date(timeIntervalSince1970: 1_000)
        garment.updatedAt = previousUpdatedAt
        context.insert(garment)
        try context.save()

        try ProductAppStorage.normalizeStoredMeasurements(in: container)

        let savedGarment = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Garment>()).first)
        let savedMeasurement = try XCTUnwrap(savedGarment.measurement("chestWidth"))
        XCTAssertEqual(savedMeasurement.valueCm, 53)
        XCTAssertEqual(savedMeasurement.autoValueCm, 52.78)
        XCTAssertEqual(savedGarment.chestCm, 53)
        XCTAssertEqual(savedGarment.updatedAt, previousUpdatedAt)
    }
}

import SwiftData
import XCTest
@testable import Dobby

/// Same-frame synthetic depth verifies persistence and recovery, not physical accuracy.
@MainActor
final class TopTotalLengthHandoffTests: XCTestCase {
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    func testRestoredTotalLengthReachesProductWhileOriginalFailureIsArchived() throws {
        var automatic = GarmentCapturePreview.measurement(missingTopLength: true, kind: .top)
        let original = automatic.result
        XCTAssertEqual(original.values.filter { $0.status == .unavailable }.map(\.id), ["top.totalLength"])
        var correction = try XCTUnwrap(automatic.manualMeasurement(for: "top.totalLength"))
        XCTAssertTrue(correction.placePoint(displayPoint: .init(x: 0.5, y: 0.24), index: 0))
        XCTAssertTrue(correction.placePoint(displayPoint: .init(x: 0.5, y: 0.84), index: 1))
        XCTAssertTrue(automatic.applyTotalLengthCorrection(from: correction))
        let revised = LiDARMeasurementEngine(options: automatic.options).measure(frame: automatic.snapshot.frame,
            landmarks: automatic.calculationLandmarks, definitions: automatic.definitions)
        XCTAssertTrue(automatic.apply(revised, for: automatic.calculationRevision))
        let value = try XCTUnwrap(automatic.result.values.first { $0.id == "top.totalLength" })
        XCTAssertEqual(try XCTUnwrap(value.meters), 600.0 / 850.0, accuracy: 1e-6)
        XCTAssertNotEqual(value.status, .unavailable)

        let record = try automatic.makeRecord()
        XCTAssertEqual(try encoded(XCTUnwrap(record.originalAutomaticResult)), try encoded(original))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(for: Garment.self, GarmentPhoto.self, LandmarkPoint.self,
            MeasuredValue.self, ExportRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let garment = try GarmentStore.importMeasurement(record, in: ModelContext(container),
            photosDirectory: directory, allowsSynthetic: true)
        let stored = try XCTUnwrap(garment.measurement("totalLength"))
        XCTAssertEqual(stored.valueCm, value.meters! * 100, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(garment.lengthCm), stored.valueCm, accuracy: 1e-6)
        XCTAssertNil(stored.autoValueCm, "A missing automatic value must not be invented during correction")
        XCTAssertEqual(garment.visibleMeasurements.map(\.key), ["totalLength", "shoulderWidth", "chestWidth", "sleeveLengthLeft"])
        let restored = try XCTUnwrap(garment.measurementPhoto?.landmark("neck_center"))
        XCTAssertEqual(restored.hasAutomaticObservation, false)
        XCTAssertNil(restored.autoOriginRaw)
        XCTAssertEqual(restored.autoIsVisible, false)
        XCTAssertEqual(restored.originRaw, LandmarkOrigin.manual.rawValue)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SavedMeasurement.self, from: data)
        XCTAssertEqual(try encoded(XCTUnwrap(decoded.originalAutomaticResult)), try encoded(original))
        XCTAssertEqual(try encoded(decoded.result), try encoded(record.result))
    }
}

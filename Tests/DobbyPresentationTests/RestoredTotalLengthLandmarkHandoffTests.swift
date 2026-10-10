import Foundation
import SwiftData
import XCTest
@testable import Dobby

/// Synthetic frozen captures verify import provenance, not model or sensor accuracy.
@MainActor
final class RestoredTotalLengthLandmarkHandoffTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([Garment.self, GarmentPhoto.self, LandmarkPoint.self,
                             MeasuredValue.self, ExportRecord.self])
        return try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func correctedRecord(missingIDs: Set<String>) throws -> SavedMeasurement {
        var original = try GarmentCapturePreview.measurement(kind: .top).makeRecord()
        original.landmarks.points.removeAll { missingIDs.contains($0.id) }
        original.result = LiDARMeasurementEngine(options: original.options).measure(frame: original.snapshot.frame,
            landmarks: original.landmarks, definitions: original.definitions)
        var automatic = AutomaticMeasurement(record: original)
        var manual = try XCTUnwrap(automatic.manualMeasurement(for: "top.totalLength"))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.24), index: 0))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.84), index: 1))
        XCTAssertTrue(automatic.applyTotalLengthCorrection(from: manual))
        let result = LiDARMeasurementEngine(options: automatic.options).measure(frame: automatic.snapshot.frame,
            landmarks: automatic.calculationLandmarks, definitions: automatic.definitions)
        XCTAssertTrue(automatic.apply(result, for: automatic.calculationRevision))
        return try automatic.makeRecord()
    }

    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    func testRestoredEndpointsPersistWithoutInventingAutomaticObservations() throws {
        for missing: Set<String> in [["neck_center"], ["hem_center"], ["neck_center", "hem_center"]] {
            let record = try correctedRecord(missingIDs: missing)
            let original = try XCTUnwrap(record.originalAutomaticLandmarks)
            let originalBytes = try bytes(original)
            let resultBytes = try bytes(try XCTUnwrap(record.originalAutomaticResult))
            let container = try container()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let garment = try GarmentStore.importMeasurement(record, in: ModelContext(container),
                photosDirectory: directory, allowsSynthetic: true)
            XCTAssertGreaterThan(try XCTUnwrap(garment.measurement("totalLength")).valueCm, 0)
            let photo = try XCTUnwrap(garment.measurementPhoto)
            for id in missing {
                let point = try XCTUnwrap(photo.landmark(id))
                XCTAssertEqual(point.hasAutomaticObservation, false)
                XCTAssertEqual(point.originRaw, "manual")
                XCTAssertNil(point.autoOriginRaw)
                XCTAssertNil(point.autoConfidence)
                XCTAssertEqual(point.autoIsVisible, false)
                XCTAssertNil(point.autoDerivedFrom)
                XCTAssertTrue(point.isMoved)
                XCTAssertEqual(point.movedDistance, 0)
                let current = try XCTUnwrap(record.landmarks.points.first { $0.id == id })
                XCTAssertEqual(point.x, current.point.x)
                XCTAssertEqual(point.y, current.point.y)
            }
            for observation in original.points {
                let point = try XCTUnwrap(photo.landmark(observation.id))
                XCTAssertEqual(point.hasAutomaticObservation, true)
                XCTAssertEqual(point.autoX, observation.point.x)
                XCTAssertEqual(point.autoY, observation.point.y)
                XCTAssertEqual(point.autoConfidence, observation.confidence)
            }
            let reader = ModelContext(container)
            let reopened = try XCTUnwrap(reader.fetch(FetchDescriptor<Garment>()).first)
            for id in missing {
                XCTAssertEqual(reopened.measurementPhoto?.landmark(id)?.hasAutomaticObservation, false)
            }
            XCTAssertEqual(try bytes(try XCTUnwrap(record.originalAutomaticLandmarks)), originalBytes)
            XCTAssertEqual(try bytes(try XCTUnwrap(record.originalAutomaticResult)), resultBytes)
        }
    }

    func testAddedPointsRequireBothConfirmedTotalLengthEndpointsAndPreserveEveryOriginalID() throws {
        let valid = try correctedRecord(missingIDs: ["neck_center"])
        let centerIndex = try XCTUnwrap(valid.landmarks.points.firstIndex { $0.id == "neck_center" })
        let hemIndex = try XCTUnwrap(valid.landmarks.points.firstIndex { $0.id == "hem_center" })
        var records: [SavedMeasurement] = []
        var bad = valid
        bad.landmarks.points[centerIndex].origin = .model; records.append(bad)
        bad = valid
        bad.landmarks.points[centerIndex].confidence = 0.9; records.append(bad)
        bad = valid
        bad.landmarks.points[centerIndex].isVisible = false; records.append(bad)
        bad = valid
        bad.landmarks.points[centerIndex].derivedFrom = ["neck_left", "neck_right"]; records.append(bad)
        bad = valid
        bad.landmarks.points[hemIndex].origin = .model; records.append(bad)
        bad = valid
        bad.landmarks.points.removeAll { $0.id == "armpit_left" }; records.append(bad)
        bad = valid
        // A known schema point outside total length must not use this exception.
        bad.originalAutomaticLandmarks?.points.removeAll { $0.id == "armpit_right" }; records.append(bad)
        bad = valid
        bad.landmarks.points.append(.init(id: "invented", point: .init(x: 0.4, y: 0.4),
                                         confidence: nil, isVisible: true, origin: .manual))
        records.append(bad)
        bad = valid
        bad.originalAutomaticResult = nil; records.append(bad)
        let container = try container()
        let context = ModelContext(container)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for record in records {
            XCTAssertThrowsError(try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: directory, allowsSynthetic: true)) { error in
                guard let failure = error as? GarmentStore.MeasurementImportError else {
                    XCTFail("Unexpected import error: \(error)")
                    return
                }
                if case .invalidRecord = failure { } else { XCTFail("Expected invalid record") }
            }
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Garment>()), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "Malformed restoration must fail before writing a photo")
    }

    func testMissingObservationDoesNotReportModelMovementOrResetToPlaceholder() {
        let legacy = LandmarkPoint(name: "shoulder_left", index: 0, x: 0.2, y: 0.3)
        legacy.move(toX: 0.3, y: 0.3)
        XCTAssertNil(legacy.hasAutomaticObservation)
        XCTAssertEqual(legacy.movedDistance, 0.1, accuracy: 1e-12)
        legacy.resetToAuto()
        XCTAssertEqual(legacy.x, 0.2)

        let restored = LandmarkPoint(name: "neck_center", index: 0, x: 0.5, y: 0.24)
        restored.hasAutomaticObservation = false
        restored.move(toX: 0.55, y: 0.26)
        XCTAssertEqual(restored.movedDistance, 0)
        restored.resetToAuto()
        XCTAssertEqual(restored.x, 0.55)
        XCTAssertEqual(restored.y, 0.26)
        XCTAssertEqual(restored.originRaw, "manual")
        XCTAssertTrue(restored.isMoved)
    }
}

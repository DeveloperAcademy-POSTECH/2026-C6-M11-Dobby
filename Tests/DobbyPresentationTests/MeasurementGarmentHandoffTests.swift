import Foundation
import ImageIO
import SwiftData
import UIKit
import XCTest
@testable import Dobby

/// Synthetic record fixtures verify the product handoff only. They are not
/// model observations, sensor accuracy evidence, or data from the user's vault.
@MainActor
final class MeasurementGarmentHandoffTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Garment.self, GarmentPhoto.self, LandmarkPoint.self,
                             MeasuredValue.self, ExportRecord.self])
        return try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dobby-measurement-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixture(_ kind: AutomaticGarmentKind = .top,
                         orientation: ImageOrientation = .up, corrected: Bool = false, legacy: Bool = false,
                         legacyBottom8: Bool = false) throws -> SavedMeasurement {
        var frame = SyntheticFixtures.scene().frame
        frame.orientation = orientation
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: format)
            .jpegData(withCompressionQuality: 0.91) { renderer in
                UIColor.systemBlue.setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
                UIColor.systemOrange.setFill()
                renderer.fill(CGRect(x: 120, y: 70, width: 220, height: 320))
            }
        let schemaURL = try XCTUnwrap(Bundle.main.url(forResource: legacy && kind == .bottoms ? "schema_bottom7" : kind.schemaResourceName, withExtension: "json"))
        let schema = try BottomLandmarkSchema(jsonData: Data(contentsOf: schemaURL))
        let definitions = kind == .top
            ? (legacy ? TopLandmarkSchema.legacyMeasurementDefinitions : TopLandmarkSchema.canonicalMeasurementDefinitions)
            : (legacy || legacyBottom8 ? schema.measurementDefinitions : schema.currentMeasurementDefinitions)
        var points = schema.keypoints.enumerated().map { index, name in
            GarmentLandmark(id: name, point: .init(x: 0.15 + Double(index % 4) * 0.15,
                                                  y: 0.1 + Double(index / 4) * 0.2),
                            confidence: 0.94)
        }
        for name in schema.derivedOrder {
            let sources = try XCTUnwrap(schema.derived[name])
            let parents = points.filter { sources.contains($0.id) }
            let coordinate = ImagePoint(x: parents.map(\.point.x).reduce(0, +) / Double(parents.count),
                                        y: parents.map(\.point.y).reduce(0, +) / Double(parents.count))
            points.append(GarmentLandmark(id: name, point: coordinate, confidence: 0.94, derivedFrom: sources))
        }
        if kind == .top && !legacy { points = TopLandmarkSchema.calculationPoints(points) }
        if kind == .bottoms && !legacy && !legacyBottom8 { points = schema.calculationPoints(points) }
        let modelVersion = legacy ? kind.legacyModelVersion
            : legacyBottom8 ? AutomaticGarmentKind.legacyBottom8ModelVersion : kind.modelVersion
        let original = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .model, modelVersion: modelVersion, points: points,
            mask: nil, garmentKind: kind)
        let meters = kind == .top ? [0.48, 0.60, 0.50, 0.62, 0.61, 0.6725]
                                 : [0.43, 0.28, 1.0225, 0.22, 0.76, 1.0125, 0.215, 0.75, 0.32125]
        let values = definitions.enumerated().map { index, definition in
            MeasurementValue(id: definition.id, title: definition.title, meters: meters[index],
                             status: .valid, failure: nil, points: [])
        }
        let result = GarmentMeasurementResult(sessionID: frame.sessionID, frameID: frame.frameID,
            algorithmVersion: "handoff-test-only", source: .synthetic, values: values)
        var record = SavedMeasurement(id: UUID(), savedAt: Date(timeIntervalSince1970: 1_790_200_000),
            snapshot: CaptureSnapshot(frame: frame, imageJPEG: jpeg), landmarks: original,
            definitions: definitions, result: result, referenceCentimeters: nil, options: .init())
        if corrected {
            let index = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "armpit_left" })
            record.originalAutomaticLandmarks = original
            record.originalAutomaticResult = result
            record.landmarks.points[index].point.x = 0.19
            record.landmarks.points[index].origin = .manual
            record.landmarks.points[index].confidence = nil
            record.result.values[1].meters = 0.6125
        }
        return record
    }

    private func sideNeckFixture() throws -> SavedMeasurement {
        var record = try remoteOuterwearFixture(seamVisible: false)
        record.landmarks.modelVersion = GarmentLandmarkModelContract.lunaGapLengthVersion
        record.landmarks.recognitionDiagnostics?.remoteSchemaVersion = "outerwear-landmarks-v4"
        let neck = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "neck_left" })
        record.landmarks.points[neck].point = .init(x: 0.35, y: 0.25)
        let hem = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "hem_center" })
        record.landmarks.points[hem].isVisible = false
        record.landmarks.recognitionDiagnostics?.rawPoints = record.landmarks.points
        record.landmarks = TopSideNeckLength.applying(to: record.landmarks)
        record.definitions = TopLandmarkSchema.sideNeckMeasurementDefinitions
        record.result = GarmentPlaneMeasurementEngine(options: record.options).measure(
            frame: record.snapshot.frame, landmarks: record.landmarks, definitions: record.definitions)
        return record
    }

    func testSideNeckLengthArchiveAndProductImportPreserveConventionAndContour() async throws {
        let record = try sideNeckFixture()
        XCTAssertNotNil(record.result.values.last?.meters)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = MeasurementArchive(folder: directory.appendingPathComponent("archive"))
        _ = try await archive.save(record)
        let restored = try await archive.load(record.id)
        let stored = try GarmentStore.importMeasurement(restored, in: ModelContext(makeContainer()),
            photosDirectory: directory.appendingPathComponent("photos"), allowsSynthetic: true)
        XCTAssertGreaterThan(stored.measurement("totalLength")?.valueCm ?? 0, 0)
        XCTAssertEqual(restored.landmarks.recognitionDiagnostics?.totalLengthConvention,
                       GarmentLandmarkModelContract.sideNeckConvention)
        let resolved = try XCTUnwrap(restored.result.values.last?.points.last)
        let endpoint = try XCTUnwrap(stored.measurementPhoto?.landmark(TopSideNeckLength.hemID))
        XCTAssertEqual(endpoint.x, resolved.imagePoint.x)
        XCTAssertEqual(endpoint.y, resolved.imagePoint.y)
        XCTAssertEqual(endpoint.hasAutomaticObservation, true)
        XCTAssertFalse(try XCTUnwrap(restored.landmarks.points.first { $0.id == "hem_center" }).isVisible)
        var wrongConvention = restored
        wrongConvention.landmarks.recognitionDiagnostics?.totalLengthConvention = GarmentLandmarkModelContract.frontGapConvention
        XCTAssertThrowsError(try GarmentStore.importMeasurement(wrongConvention, in: ModelContext(makeContainer()),
            photosDirectory: directory.appendingPathComponent("invalid"), allowsSynthetic: true))
    }

    func testSideNeckManualCorrectionCanBeImportedAndResetToOriginalContour() throws {
        let record = try sideNeckFixture()
        var model = AutomaticMeasurement(record: record)
        XCTAssertTrue(model.canCorrectTotalLength)
        var manual = try XCTUnwrap(model.manualMeasurement(for: "top.totalLength"))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.4, y: 0.25), index: 0))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.4, y: 0.85), index: 1))
        XCTAssertTrue(model.applyTotalLengthCorrection(from: manual))
        let result = GarmentPlaneMeasurementEngine(options: model.options).measure(
            frame: model.snapshot.frame, landmarks: model.calculationLandmarks, definitions: model.definitions)
        XCTAssertTrue(model.apply(result, for: model.calculationRevision))
        let corrected = try model.makeRecord()
        XCTAssertNil(corrected.landmarks.points.first { $0.id == TopSideNeckLength.hemID }?.contourRule)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(corrected, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertEqual(stored.measurementPhoto?.landmark("neck_left")?.originRaw, "manual")
        var reopened = AutomaticMeasurement(record: corrected)
        reopened.resetPointAdjustments()
        XCTAssertEqual(reopened.calculationLandmarks.points.first { $0.id == TopSideNeckLength.hemID }?.contourRule,
                       .leftNeckVerticalHemMaskV1)
    }

    /// The remote seam is an independently observed physical point. Unknown
    /// remote confidence and a missing seam must survive product persistence.
    private func remoteOuterwearFixture(seamVisible: Bool = true) throws -> SavedMeasurement {
        var record = try fixture(.top)
        record.landmarks.modelVersion = GarmentLandmarkModelContract.lunaOuterwearVersion
        record.landmarks.points.removeAll { $0.id == "neck_center" }
        for index in record.landmarks.points.indices { record.landmarks.points[index].confidence = nil }
        let start = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "top_length_start" })
        record.landmarks.points[start] = .init(id: "top_length_start",
            point: seamVisible ? .init(x: 0.5, y: 0.2) : .init(x: 0.5, y: 0.5),
            confidence: nil, isVisible: seamVisible)
        let hem = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "hem_center" })
        record.landmarks.points[hem].point = .init(x: 0.5, y: 0.8)
        // A whole-frame mask is invalid garment evidence (coverage must be
        // 10–85%, and lateral edges must remain clear). Keep this plane fixture
        // bounded while covering every visible endpoint, including manual edits.
        let maskSize = record.snapshot.frame.depth.size
        var maskValues = [UInt8](repeating: 0, count: maskSize.width * maskSize.height)
        for y in (maskSize.height / 20)..<(maskSize.height * 9 / 10) {
            for x in (maskSize.width / 10)..<(maskSize.width * 4 / 5) {
                maskValues[y * maskSize.width + x] = 1
            }
        }
        let mask = GarmentMask(size: maskSize, values: maskValues)
        _ = try GarmentPlaneGeometry.fit(frame: record.snapshot.frame, mask: mask, uprightOrientation: .up)
        record.landmarks.mask = mask
        let assessments = record.landmarks.points.map {
            LandmarkMaskAssessment(landmarkID: $0.id, status: $0.isVisible ? .associated : .notVisible)
        }
        var diagnostics = GarmentRecognitionDiagnostics(requestedOrientation: .up,
            selectedPoseOrientation: .up, associationPolicy: .subject,
            rawPoints: record.landmarks.points, pointAssessments: assessments, poseAttempts: [])
        diagnostics.classifiedCategory = "Jacket"
        diagnostics.remoteModel = OuterwearLandmarkResponse.expectedModel
        diagnostics.remoteSchemaVersion = OuterwearLandmarkResponse.expectedSchemaVersion
        diagnostics.remoteView = "front"
        diagnostics.remoteNeckStyle = "hood"
        diagnostics.totalLengthConvention = GarmentLandmarkModelContract.backNeckSeamConvention
        record.landmarks.recognitionDiagnostics = diagnostics
        record.options.calculationMode = .garmentPlane
        for index in record.result.values.indices { record.result.values[index].status = .uncertain }
        if !seamVisible {
            let length = try XCTUnwrap(record.result.values.firstIndex { $0.id == "top.totalLength" })
            record.result.values[length].meters = nil
            record.result.values[length].status = .unavailable
            record.result.values[length].failure = .occludedLandmark
        }
        return record
    }

    private func remoteFrontOuterwearFixture(seamVisible: Bool = true) throws -> SavedMeasurement {
        var record = try remoteOuterwearFixture(seamVisible: false)
        record.landmarks.modelVersion = GarmentLandmarkModelContract.lunaViewLengthVersion
        record.landmarks.points.append(.init(id: "front_length_start",
            point: seamVisible ? .init(x: 0.5, y: 0.22) : .init(x: 0.5, y: 0.5),
            confidence: nil, isVisible: seamVisible))
        record.definitions = TopLandmarkSchema.frontLengthMeasurementDefinitions
        for index in record.result.values.indices {
            record.result.values[index].id = record.definitions[index].id
            record.result.values[index].title = record.definitions[index].title
        }
        let length = try XCTUnwrap(record.result.values.firstIndex { $0.id == "top.frontLength" })
        record.result.values[length].meters = seamVisible ? 0.6725 : nil
        record.result.values[length].status = seamVisible ? .uncertain : .unavailable
        record.result.values[length].failure = seamVisible ? nil : .occludedLandmark
        var diagnostics = try XCTUnwrap(record.landmarks.recognitionDiagnostics)
        diagnostics.remoteSchemaVersion = OuterwearLandmarkResponse.expectedViewLengthSchemaVersion
        diagnostics.remoteView = "front"
        diagnostics.totalLengthConvention = GarmentLandmarkModelContract.frontNeckSeamConvention
        diagnostics.rawPoints = record.landmarks.points
        diagnostics.pointAssessments = record.landmarks.points.map {
            .init(landmarkID: $0.id, status: $0.isVisible ? .associated : .notVisible)
        }
        record.landmarks.recognitionDiagnostics = diagnostics
        return record
    }

    private func frontTotalOuterwearFixture(seamVisible: Bool = true) throws -> SavedMeasurement {
        var record = try remoteOuterwearFixture(seamVisible: seamVisible)
        record.landmarks.modelVersion = GarmentLandmarkModelContract.lunaFrontLengthVersion
        record.landmarks.recognitionDiagnostics?.remoteSchemaVersion = OuterwearLandmarkResponse.expectedFrontLengthSchemaVersion
        record.landmarks.recognitionDiagnostics?.remoteView = "front"
        record.landmarks.recognitionDiagnostics?.totalLengthConvention = GarmentLandmarkModelContract.frontNeckSeamConvention
        return record
    }

    func testUnavailableTotalPointGetsDisplayHintWithoutChangingCalculationOrSavedEvidence() throws {
        let record = try frontTotalOuterwearFixture(seamVisible: false)
        let model = AutomaticMeasurement(record: record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(model.calculationLandmarks)
        let shown = model.photoEditingPresentation
        let point = try XCTUnwrap(shown.landmarks.points.first { $0.id == "top_length_start" })
        XCTAssertTrue(point.isVisible)
        XCTAssertTrue(point.point.isValid)
        XCTAssertTrue(shown.pendingIDs.contains(point.id))
        XCTAssertNotEqual(point.point, ImagePoint(x: 0.5, y: 0.5), "A null slot must start near the neck, not the photo center")
        XCTAssertEqual(try encoder.encode(model.calculationLandmarks), before)
        XCTAssertFalse(model.hasPointAdjustments)
        XCTAssertEqual(model.result.values.first { $0.id == "top.totalLength" }?.status, .unavailable)
        XCTAssertFalse(try XCTUnwrap(model.makeRecord().landmarks.points.first { $0.id == point.id }).isVisible)
    }

    func testRejectedAICoordinateIsShownAndOnlyExplicitMoveConfirmsIt() throws {
        var record = try frontTotalOuterwearFixture(seamVisible: false)
        record.snapshot.presentationCrop = .full
        let candidate = ImagePoint(x: 0.91, y: 0.12)
        let index = try XCTUnwrap(record.landmarks.recognitionDiagnostics?.rawPoints.firstIndex { $0.id == "top_length_start" })
        record.landmarks.recognitionDiagnostics?.rawPoints[index].point = candidate
        record.landmarks.recognitionDiagnostics?.rawPoints[index].isVisible = true
        var model = AutomaticMeasurement(record: record)
        XCTAssertEqual(model.photoEditingPresentation.landmarks.points.first { $0.id == "top_length_start" }?.point, candidate)
        XCTAssertTrue(model.photoEditingPresentation.pendingIDs.contains("top_length_start"))
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.5, y: 0.23), id: "top_length_start"))
        XCTAssertFalse(model.photoEditingPresentation.pendingIDs.contains("top_length_start"))
        XCTAssertEqual(model.calculationLandmarks.points.first { $0.id == "top_length_start" }?.origin, .manual)
        model.resetPointAdjustments()
        XCTAssertTrue(model.photoEditingPresentation.pendingIDs.contains("top_length_start"))
        XCTAssertFalse(model.calculationLandmarks.points.first { $0.id == "top_length_start" }!.isVisible)
    }

    func testMissingTotalSlotCanBeDisplayedAndExplicitlyRestoredByDragging() throws {
        var record = try frontTotalOuterwearFixture(seamVisible: false)
        record.landmarks.points.removeAll { $0.id == "top_length_start" }
        var model = AutomaticMeasurement(record: record)
        XCTAssertTrue(model.photoEditingPresentation.landmarks.points.contains { $0.id == "top_length_start" && $0.isVisible })
        XCTAssertFalse(model.calculationLandmarks.points.contains { $0.id == "top_length_start" })
        XCTAssertFalse(model.placePoint(originalPoint: .init(x: 0.5, y: 0.2), id: "unregistered_point"))
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.5, y: 0.2), id: "top_length_start"))
        XCTAssertEqual(model.calculationLandmarks.points.first { $0.id == "top_length_start" }?.origin, .manual)
        let recalculated = GarmentPlaneMeasurementEngine(options: model.options).measure(
            frame: model.snapshot.frame, landmarks: model.calculationLandmarks, definitions: model.definitions)
        XCTAssertTrue(model.apply(recalculated, for: model.calculationRevision))
        let corrected = try model.makeRecord()
        XCTAssertNotEqual(corrected.landmarks.points.first { $0.id == "hem_center" }?.origin, .manual)
        XCTAssertFalse(corrected.originalAutomaticLandmarks!.points.contains { $0.id == "top_length_start" })
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(corrected, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertGreaterThan(stored.measurement("totalLength")?.valueCm ?? 0, 0)
        XCTAssertNil(stored.measurement("totalLength")?.autoValueCm)
        XCTAssertEqual(try XCTUnwrap(stored.measurementPhoto?.landmark("top_length_start")).hasAutomaticObservation, false)
        var invented = corrected
        let start = try XCTUnwrap(invented.landmarks.points.firstIndex { $0.id == "top_length_start" })
        invented.landmarks.points[start].origin = .model
        XCTAssertThrowsError(try GarmentStore.importMeasurement(invented, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true), "A display hint cannot become a new model observation")
    }

    func testV3FrontTotalLengthStoresAndReopensAsTheDefaultTotalLength() async throws {
        let record = try frontTotalOuterwearFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = MeasurementArchive(folder: directory.appendingPathComponent("archive", isDirectory: true))
        _ = try await archive.save(record)
        let restored = try await archive.load(record.id)
        XCTAssertEqual(restored.definitions.last?.id, "top.totalLength")
        XCTAssertEqual(restored.definitions.last?.landmarkIDs, ["top_length_start", "hem_center"])
        XCTAssertEqual(restored.landmarks.recognitionDiagnostics?.totalLengthConvention,
            GarmentLandmarkModelContract.frontNeckSeamConvention)
        let database = directory.appendingPathComponent("front-total.store")
        let photos = directory.appendingPathComponent("photos", isDirectory: true)
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: database, cloudKitDatabase: .none)])
            let stored = try GarmentStore.importMeasurement(restored, in: ModelContext(container),
                photosDirectory: photos, allowsSynthetic: true)
            XCTAssertGreaterThan(stored.measurement("totalLength")?.valueCm ?? 0, 0)
            XCTAssertEqual(stored.measurement("totalLength")?.label, "총장")
            XCTAssertNil(stored.measurement("frontLength"))
            XCTAssertEqual(stored.measurementPhoto?.landmarks.count, 12)
        }
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: database, cloudKitDatabase: .none)])
            let stored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Garment>()).first)
            XCTAssertEqual(stored.measurementPhoto?.measurementModelVersion, GarmentLandmarkModelContract.lunaFrontLengthVersion)
            XCTAssertGreaterThan(stored.measurement("totalLength")?.valueCm ?? 0, 0)
            XCTAssertTrue(try XCTUnwrap(stored.measurementPhoto?.landmark("top_length_start")?.hasAutomaticObservation))
            XCTAssertNil(stored.measurementPhoto?.landmark("front_length_start"))
        }
        var wrongConvention = record
        wrongConvention.landmarks.recognitionDiagnostics?.totalLengthConvention = GarmentLandmarkModelContract.backNeckSeamConvention
        XCTAssertThrowsError(try GarmentStore.importMeasurement(wrongConvention, in: ModelContext(makeContainer()),
            photosDirectory: photos, allowsSynthetic: true))
    }

    func testV4EstimatedCentersSurviveArchiveAndProductImport() async throws {
        var record = try frontTotalOuterwearFixture()
        record.landmarks.modelVersion = GarmentLandmarkModelContract.lunaGapLengthVersion
        record.landmarks.recognitionDiagnostics?.remoteSchemaVersion = OuterwearLandmarkResponse.expectedGapSchemaVersion
        record.landmarks.recognitionDiagnostics?.totalLengthConvention = GarmentLandmarkModelContract.frontGapConvention
        record.landmarks.recognitionDiagnostics?.centerEstimates = [.init(landmarkID: "top_length_start",
            point: .init(x: 0.5, y: 0.22), leftSupport: .init(x: 0.48, y: 0.22), rightSupport: .init(x: 0.52, y: 0.22))]
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = MeasurementArchive(folder: directory.appendingPathComponent("archive"))
        _ = try await archive.save(record)
        let restored = try await archive.load(record.id)
        XCTAssertEqual(restored.landmarks.recognitionDiagnostics?.centerEstimates?.count, 1)
        let stored = try GarmentStore.importMeasurement(restored, in: ModelContext(makeContainer()),
            photosDirectory: directory.appendingPathComponent("photos"), allowsSynthetic: true)
        XCTAssertGreaterThan(stored.measurement("totalLength")?.valueCm ?? 0, 0)
        XCTAssertEqual(stored.measurementPhoto?.measurementModelVersion, GarmentLandmarkModelContract.lunaGapLengthVersion)
        var wrong = record
        wrong.landmarks.recognitionDiagnostics?.totalLengthConvention = GarmentLandmarkModelContract.frontNeckSeamConvention
        XCTAssertThrowsError(try GarmentStore.importMeasurement(wrong, in: ModelContext(makeContainer()),
            photosDirectory: directory.appendingPathComponent("wrong"), allowsSynthetic: true))
    }

    func testV3MissingFrontTotalStartCanBeCorrectedWithoutChangingItsConvention() throws {
        let record = try frontTotalOuterwearFixture(seamVisible: false)
        var model = AutomaticMeasurement(record: record)
        XCTAssertEqual(model.lengthDefinition?.id, "top.totalLength")
        XCTAssertTrue(try XCTUnwrap(model.visibleEditableLandmarks.points.first { $0.id == "hem_center" }).isVisible,
            "An unavailable total length must still display its independently supported hem")
        XCTAssertFalse(try XCTUnwrap(model.visibleEditableLandmarks.points.first { $0.id == "top_length_start" }).isVisible)
        var manual = try XCTUnwrap(model.manualMeasurement(for: "top.totalLength"))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.22), index: 0))
        XCTAssertFalse(model.applyTotalLengthCorrection(from: manual))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.8), index: 1))
        XCTAssertTrue(model.applyTotalLengthCorrection(from: manual))
        let recalculated = GarmentPlaneMeasurementEngine(options: model.options).measure(
            frame: model.snapshot.frame, landmarks: model.calculationLandmarks, definitions: model.definitions)
        XCTAssertTrue(model.apply(recalculated, for: model.calculationRevision))
        let corrected = try model.makeRecord()
        XCTAssertEqual(corrected.landmarks.recognitionDiagnostics?.totalLengthConvention,
            GarmentLandmarkModelContract.frontNeckSeamConvention)
        XCTAssertFalse(try XCTUnwrap(corrected.originalAutomaticLandmarks?.points.first { $0.id == "top_length_start" }).isVisible)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(corrected, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertGreaterThan(stored.measurement("totalLength")?.valueCm ?? 0, 0)
        XCTAssertNil(stored.measurement("totalLength")?.autoValueCm)
        XCTAssertNil(stored.measurement("frontLength"))
    }

    func testFrontOuterwearLengthKeepsItsOwnLabelFieldAndSourceAfterArchiveAndProductReopen() async throws {
        let record = try remoteFrontOuterwearFixture()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = MeasurementArchive(folder: directory.appendingPathComponent("archive", isDirectory: true))
        _ = try await archive.save(record)
        let restored = try await archive.load(record.id)
        XCTAssertEqual(restored.landmarks.modelVersion, GarmentLandmarkModelContract.lunaViewLengthVersion)
        XCTAssertEqual(restored.landmarks.recognitionDiagnostics?.totalLengthConvention,
                       GarmentLandmarkModelContract.frontNeckSeamConvention)
        XCTAssertEqual(restored.definitions.last?.id, "top.frontLength")
        XCTAssertEqual(restored.definitions.last?.title, "앞판 총장")
        XCTAssertEqual(restored.landmarks.points.count, 13)
        XCTAssertFalse(try XCTUnwrap(restored.landmarks.points.first { $0.id == "top_length_start" }).isVisible)
        XCTAssertTrue(try XCTUnwrap(restored.landmarks.points.first { $0.id == "front_length_start" }).isVisible)

        let database = directory.appendingPathComponent("front-outerwear-products.store")
        let photos = directory.appendingPathComponent("photos", isDirectory: true)
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: database, cloudKitDatabase: .none)
            ])
            let stored = try GarmentStore.importMeasurement(restored, in: ModelContext(container),
                photosDirectory: photos, allowsSynthetic: true)
            XCTAssertEqual(stored.orderedMeasurements.count, 6)
        }
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: database, cloudKitDatabase: .none)
            ])
            let stored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Garment>()).first)
            let front = try XCTUnwrap(stored.measurement("frontLength"))
            XCTAssertEqual(front.label, "앞판 총장")
            XCTAssertEqual(front.valueCm, 67.2, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(front.autoValueCm), 67.25, accuracy: 0.001)
            XCTAssertNil(stored.measurement("totalLength"))
            XCTAssertNil(stored.lengthCm, "A front measurement must not populate the back-total-length field")
            XCTAssertTrue(stored.visibleMeasurements.contains { $0.key == "frontLength" })
            let photo = try XCTUnwrap(stored.measurementPhoto)
            XCTAssertEqual(photo.measurementModelVersion, GarmentLandmarkModelContract.lunaViewLengthVersion)
            let frontPoint = try XCTUnwrap(photo.landmark("front_length_start"))
            XCTAssertTrue(try XCTUnwrap(frontPoint.isVisible))
            XCTAssertTrue(try XCTUnwrap(frontPoint.hasAutomaticObservation))
            XCTAssertFalse(frontPoint.isMoved)
            XCTAssertFalse(try XCTUnwrap(photo.landmark("top_length_start")?.hasAutomaticObservation))
        }
        XCTAssertEqual(try recordBytes(restored), try recordBytes(record))
    }

    func testFrontOuterwearVersionViewAndLengthDefinitionsCannotBeInterchanged() throws {
        let front = try remoteFrontOuterwearFixture()
        var invalid: [SavedMeasurement] = []
        var record = front
        record.landmarks.modelVersion = GarmentLandmarkModelContract.lunaOuterwearVersion
        invalid.append(record)
        record = try remoteOuterwearFixture()
        record.landmarks.modelVersion = GarmentLandmarkModelContract.lunaViewLengthVersion
        invalid.append(record)
        record = front
        record.landmarks.recognitionDiagnostics?.remoteView = "back"
        invalid.append(record)
        record = front
        record.landmarks.recognitionDiagnostics?.remoteView = "back"
        record.landmarks.recognitionDiagnostics?.totalLengthConvention = GarmentLandmarkModelContract.backNeckSeamConvention
        invalid.append(record)
        record = front
        record.definitions = TopLandmarkSchema.canonicalMeasurementDefinitions
        for index in record.result.values.indices {
            record.result.values[index].id = record.definitions[index].id
            record.result.values[index].title = record.definitions[index].title
        }
        invalid.append(record)
        record = front
        let length = try XCTUnwrap(record.definitions.firstIndex { $0.id == "top.frontLength" })
        record.definitions[length].landmarkIDs = ["top_length_start", "hem_center"]
        invalid.append(record)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for record in invalid {
            XCTAssertThrowsError(try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
                photosDirectory: directory, allowsSynthetic: true))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMissingFrontSeamRequiresBothManualEndpointsAndKeepsItsAutomaticBaselineUnavailable() throws {
        let record = try remoteFrontOuterwearFixture(seamVisible: false)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertGreaterThan(partial.measurement("chestWidth")?.valueCm ?? 0, 0)
        XCTAssertEqual(partial.measurement("frontLength")?.valueCm, 0)
        XCTAssertNil(partial.measurement("frontLength")?.autoValueCm)
        XCTAssertNil(partial.measurement("totalLength"))
        let unavailable = try XCTUnwrap(partial.measurementPhoto?.landmark("front_length_start"))
        XCTAssertFalse(try XCTUnwrap(unavailable.isVisible))
        XCTAssertFalse(try XCTUnwrap(unavailable.hasAutomaticObservation))

        var model = AutomaticMeasurement(record: record)
        XCTAssertTrue(model.canCorrectTotalLength)
        XCTAssertEqual(model.lengthDefinition?.id, "top.frontLength")
        var manual = try XCTUnwrap(model.manualMeasurement(for: "top.frontLength"))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.22), index: 0))
        XCTAssertFalse(model.applyTotalLengthCorrection(from: manual))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.8), index: 1))
        XCTAssertTrue(model.applyTotalLengthCorrection(from: manual))
        let recalculated = GarmentPlaneMeasurementEngine(options: model.options).measure(
            frame: model.snapshot.frame, landmarks: model.calculationLandmarks, definitions: model.definitions)
        XCTAssertTrue(model.apply(recalculated, for: model.calculationRevision))
        XCTAssertGreaterThan(try XCTUnwrap(model.result.values.first { $0.id == "top.frontLength" }?.meters), 0)
        let corrected = try model.makeRecord()
        XCTAssertEqual(corrected.landmarks.modelVersion, GarmentLandmarkModelContract.lunaViewLengthVersion)
        XCTAssertFalse(try XCTUnwrap(corrected.originalAutomaticLandmarks?.points.first { $0.id == "front_length_start" }).isVisible)
        XCTAssertEqual(corrected.landmarks.points.first { $0.id == "front_length_start" }?.origin, .manual)
        XCTAssertFalse(try XCTUnwrap(corrected.landmarks.points.first { $0.id == "top_length_start" }).isVisible)
        let decoded = try JSONDecoder().decode(SavedMeasurement.self, from: recordBytes(corrected))
        let stored = try GarmentStore.importMeasurement(decoded, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let point = try XCTUnwrap(stored.measurementPhoto?.landmark("front_length_start"))
        XCTAssertTrue(try XCTUnwrap(point.isVisible))
        XCTAssertTrue(point.isMoved)
        XCTAssertFalse(try XCTUnwrap(point.hasAutomaticObservation))
        XCTAssertEqual(point.originRaw, "manual")
        XCTAssertNil(stored.measurement("frontLength")?.autoValueCm)
        XCTAssertGreaterThan(stored.measurement("frontLength")?.valueCm ?? 0, 0)
        XCTAssertEqual(stored.measurement("frontLength")?.label, "앞판 총장")
        XCTAssertNil(stored.measurement("totalLength"))
    }

    func testRemoteOuterwearDirectSeamAndSourceSurviveArchiveAndProductReopen() async throws {
        let record = try remoteOuterwearFixture()
        XCTAssertEqual(OuterwearLandmarkResponse.expectedModelVersion, GarmentLandmarkModelContract.lunaOuterwearVersion)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = MeasurementArchive(folder: directory.appendingPathComponent("archive", isDirectory: true))
        _ = try await archive.save(record)
        let restored = try await archive.load(record.id)
        XCTAssertEqual(restored.landmarks.modelVersion, GarmentLandmarkModelContract.lunaOuterwearVersion)
        XCTAssertEqual(restored.options.effectiveCalculationMode, .garmentPlane)
        XCTAssertEqual(restored.landmarks.recognitionDiagnostics?.remoteModel, "gpt-6-luna")
        XCTAssertEqual(restored.landmarks.recognitionDiagnostics?.remoteSchemaVersion, "outerwear-landmarks-v1")
        XCTAssertEqual(restored.landmarks.recognitionDiagnostics?.totalLengthConvention,
                       GarmentLandmarkModelContract.backNeckSeamConvention)
        let seam = try XCTUnwrap(restored.landmarks.points.first { $0.id == "top_length_start" })
        XCTAssertTrue(seam.isVisible)
        XCTAssertNil(seam.contourRule)
        XCTAssertNil(seam.derivedFrom)
        XCTAssertNil(seam.confidence)

        let database = directory.appendingPathComponent("remote-products.store")
        let photos = directory.appendingPathComponent("photos", isDirectory: true)
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: database, cloudKitDatabase: .none)
            ])
            let stored = try GarmentStore.importMeasurement(restored, in: ModelContext(container),
                photosDirectory: photos, allowsSynthetic: true)
            XCTAssertEqual(stored.orderedMeasurements.count, 6)
        }
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: database, cloudKitDatabase: .none)
            ])
            let stored = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Garment>()).first)
            let photo = try XCTUnwrap(stored.measurementPhoto)
            XCTAssertEqual(photo.measurementModelVersion, GarmentLandmarkModelContract.lunaOuterwearVersion)
            XCTAssertEqual(photo.measurementFrameID, record.snapshot.frame.frameID)
            XCTAssertEqual(photo.landmarks.count, 12)
            let point = try XCTUnwrap(photo.landmark("top_length_start"))
            XCTAssertEqual(point.x, seam.point.x)
            XCTAssertEqual(point.y, seam.point.y)
            XCTAssertEqual(point.autoX, seam.point.x)
            XCTAssertEqual(point.autoY, seam.point.y)
            XCTAssertTrue(try XCTUnwrap(point.isVisible))
            XCTAssertTrue(try XCTUnwrap(point.hasAutomaticObservation))
            XCTAssertFalse(point.isMoved)
            XCTAssertNil(point.confidence)
            XCTAssertNil(point.autoConfidence)
            XCTAssertNil(point.derivedFrom)
            XCTAssertEqual(point.originRaw, "model")
            XCTAssertEqual(stored.measurement("totalLength")?.sourceStatusRaw, "uncertain")
        }
        XCTAssertEqual(try recordBytes(restored), try recordBytes(record))
    }

    func testRemoteAndCoreMLLengthStartContractsCannotBeInterchanged() throws {
        let remote = try remoteOuterwearFixture()
        let start = try XCTUnwrap(remote.landmarks.points.firstIndex { $0.id == "top_length_start" })
        var invalid: [SavedMeasurement] = []
        var record = remote
        record.landmarks.modelVersion = "luna-outerwear11-backseam-v999"
        invalid.append(record)
        record = remote
        record.landmarks.points[start].contourRule = .neckPerpendicularMaskV1
        invalid.append(record)
        record = remote
        record.landmarks.points[start].derivedFrom = ["neck_left", "neck_right"]
        invalid.append(record)
        record = remote
        record.landmarks.modelVersion = AutomaticGarmentKind.top.modelVersion
        invalid.append(record)
        record = try fixture(.top)
        record.landmarks.modelVersion = GarmentLandmarkModelContract.lunaOuterwearVersion
        invalid.append(record)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for record in invalid {
            XCTAssertThrowsError(try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
                photosDirectory: directory, allowsSynthetic: true))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRemoteMissingSeamKeepsOtherDimensionsAndManualCorrectionWithoutFalseBaseline() throws {
        let record = try remoteOuterwearFixture(seamVisible: false)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertGreaterThan(partial.measurement("shoulderWidth")?.valueCm ?? 0, 0)
        XCTAssertGreaterThan(partial.measurement("chestWidth")?.valueCm ?? 0, 0)
        XCTAssertEqual(partial.measurement("totalLength")?.valueCm, 0)
        XCTAssertNil(partial.measurement("totalLength")?.autoValueCm)
        let unavailable = try XCTUnwrap(partial.measurementPhoto?.landmark("top_length_start"))
        XCTAssertFalse(try XCTUnwrap(unavailable.isVisible))
        XCTAssertFalse(try XCTUnwrap(unavailable.hasAutomaticObservation),
            "The hidden null-seam hint is not an observed automatic reset coordinate")

        var model = AutomaticMeasurement(record: record)
        XCTAssertTrue(model.canCorrectTotalLength)
        var manual = try XCTUnwrap(model.manualMeasurement(for: "top.totalLength"))
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.22), index: 0))
        XCTAssertFalse(model.applyTotalLengthCorrection(from: manual), "Both physical endpoints require confirmation")
        XCTAssertTrue(manual.placePoint(displayPoint: .init(x: 0.5, y: 0.8), index: 1))
        XCTAssertTrue(model.applyTotalLengthCorrection(from: manual))
        let recalculated = GarmentPlaneMeasurementEngine(options: model.options).measure(
            frame: model.snapshot.frame, landmarks: model.calculationLandmarks, definitions: model.definitions)
        XCTAssertTrue(model.apply(recalculated, for: model.calculationRevision))
        XCTAssertGreaterThan(try XCTUnwrap(model.result.values.first { $0.id == "top.totalLength" }?.meters), 0)
        let corrected = try model.makeRecord()
        XCTAssertEqual(corrected.landmarks.modelVersion, GarmentLandmarkModelContract.lunaOuterwearVersion)
        XCTAssertFalse(try XCTUnwrap(corrected.originalAutomaticLandmarks?.points.first { $0.id == "top_length_start" }).isVisible)
        XCTAssertNil(corrected.landmarks.points.first { $0.id == "top_length_start" }?.contourRule)
        XCTAssertEqual(corrected.landmarks.points.first { $0.id == "top_length_start" }?.origin, .manual)
        let decoded = try JSONDecoder().decode(SavedMeasurement.self, from: recordBytes(corrected))
        let stored = try GarmentStore.importMeasurement(decoded, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let point = try XCTUnwrap(stored.measurementPhoto?.landmark("top_length_start"))
        XCTAssertTrue(try XCTUnwrap(point.isVisible))
        XCTAssertTrue(point.isMoved)
        XCTAssertFalse(try XCTUnwrap(point.hasAutomaticObservation))
        XCTAssertEqual(point.originRaw, "manual")
        XCTAssertNil(point.confidence)
        XCTAssertNil(stored.measurement("totalLength")?.autoValueCm)
        XCTAssertGreaterThan(stored.measurement("totalLength")?.valueCm ?? 0, 0)
    }

    func testTopCurrentAndAutomaticValuesCoordinatesAndProvenancePersistSeparately() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try fixture(corrected: true)
        let garment = try GarmentStore.importMeasurement(record, in: context,
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertEqual(garment.id, record.id)
        XCTAssertEqual(garment.sourceMeasurementID, record.id)
        XCTAssertEqual(garment.group, .top)
        XCTAssertEqual(garment.orderedMeasurements.map(\.key), ["shoulderWidth", "chestWidth", "hemWidth",
            "sleeveLengthLeft", "sleeveLengthRight", "totalLength"])
        let chest = try XCTUnwrap(garment.measurement("chestWidth"))
        XCTAssertEqual(chest.valueCm, 61.2, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(chest.autoValueCm), 60, accuracy: 1e-10)
        XCTAssertFalse(chest.isEdited, "Moving a physical point is not a typed numeric edit")
        XCTAssertEqual(chest.sourceStatusRaw, "valid")
        XCTAssertEqual(garment.lengthCm, garment.measurement("totalLength")?.valueCm)
        let photo = try XCTUnwrap(garment.measurementPhoto)
        XCTAssertEqual(photo.measurementRecordID, record.id)
        XCTAssertEqual(photo.measurementFrameID, record.snapshot.frame.frameID)
        XCTAssertEqual(photo.measurementSessionID, record.snapshot.frame.sessionID)
        XCTAssertEqual(photo.measurementModelVersion, AutomaticGarmentKind.top.modelVersion)
        XCTAssertEqual(photo.imageWidth, 800)
        XCTAssertEqual(photo.imageHeight, 600)
        XCTAssertNil(photo.pixelsPerCm)
        XCTAssertNil(photo.garmentScore)
        let moved = try XCTUnwrap(photo.landmark("armpit_left"))
        let original = try XCTUnwrap(record.originalAutomaticLandmarks?.points.first { $0.id == "armpit_left" })
        XCTAssertEqual(moved.x, 0.19)
        XCTAssertEqual(moved.autoX, original.point.x)
        XCTAssertEqual(moved.originRaw, "manual")
        XCTAssertEqual(moved.autoOriginRaw, "model")
        XCTAssertNil(moved.confidence)
        XCTAssertEqual(moved.autoConfidence, 0.94)
        XCTAssertTrue(moved.isMoved)
        XCTAssertTrue(garment.wasCorrectedByHand)
        let centre = try XCTUnwrap(photo.landmark("neck_center"))
        XCTAssertEqual(centre.derivedFrom, ["neck_left", "neck_right"])
        XCTAssertFalse(centre.isMoved)

        // Refetch the saved graph independently; all inverse relationships and
        // original automatic evidence must survive a context boundary.
        let reader = ModelContext(container)
        let fetched = try XCTUnwrap(reader.fetch(FetchDescriptor<Garment>()).first)
        XCTAssertEqual(fetched.orderedMeasurements.count, 6)
        XCTAssertEqual(fetched.measurementPhoto?.landmarks.count, 13)
        XCTAssertEqual(fetched.measurement("chestWidth")?.garment?.id, record.id)
        XCTAssertEqual(fetched.measurementPhoto?.landmark("armpit_left")?.photo?.garment?.id, record.id)
        XCTAssertEqual(fetched.measurementPhoto?.landmark("armpit_left")?.autoX, original.point.x)
    }

    func testCurrentBottomNineMeasurementsUseActualCatalogOrderAndKeys() throws {
        let container = try makeContainer()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try fixture(.bottoms)
        let garment = try GarmentStore.importMeasurement(record, in: ModelContext(container),
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertEqual(garment.group, .pants)
        XCTAssertEqual(garment.orderedMeasurements.map(\.key), ["waistWidth", "frontRise", "totalLengthLeft",
            "hemWidthLeft", "inseamLeft", "totalLengthRight", "hemWidthRight", "inseamRight", "thighWidthRight"])
        for (index, value) in garment.orderedMeasurements.enumerated() {
            let expected = try XCTUnwrap(record.result.values[index].meters) * 100
            XCTAssertEqual(value.valueCm, StoredMeasurementValue.centimeters(expected))
            XCTAssertEqual(value.autoValueCm, expected)
            XCTAssertEqual(value.label, record.result.values[index].title)
        }
        XCTAssertEqual(garment.waistCm, 43)
        XCTAssertEqual(try XCTUnwrap(garment.lengthCm), 102.2, accuracy: 1e-10)
        XCTAssertNil(garment.shoulderCm)
        XCTAssertEqual(garment.measurementPhoto?.landmark("waist_center")?.derivedFrom,
                       ["waist_left", "waist_right"])
        XCTAssertEqual(try XCTUnwrap(garment.measurement("thighWidthRight")?.valueCm), 32.1, accuracy: 1e-10)
        XCTAssertNil(garment.measurement("thighWidthLeft"))
        XCTAssertEqual(garment.visibleMeasurements.map(\.key),
                       ["totalLengthLeft", "waistWidth", "frontRise", "thighWidthRight", "hemWidthLeft"])
    }

    func testLegacyVersionsKeepTheirOriginalPointAndMeasurementContracts() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for kind in AutomaticGarmentKind.allCases {
            var record = try fixture(kind, legacy: true)
            if kind == .top {
                record.definitions = TopLandmarkSchema.legacyProjectedMeasurementDefinitions
            }
            let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
                photosDirectory: directory, allowsSynthetic: true)
            XCTAssertEqual(stored.measurementPhoto?.measurementModelVersion, kind.legacyModelVersion)
            XCTAssertEqual(stored.measurementPhoto?.landmarks.count, kind == .top ? 12 : 8)
            XCTAssertNil(stored.measurementPhoto?.landmark("top_length_start"))
            XCTAssertNil(stored.measurementPhoto?.landmark("waist_front_center"))
            XCTAssertNotNil(stored.measurement(kind == .top ? "totalLength" : "frontRise"))
        }
    }

    func testNewRiseMissingEighthPointKeepsEditableBlankWithoutSubstitutingMidpoint() throws {
        var record = try fixture(.bottoms)
        record.landmarks.points.removeAll { $0.id == "waist_front_center" }
        record.result.values[1].meters = nil
        record.result.values[1].status = .unavailable
        record.result.values[1].failure = .missingLandmark
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let rise = try XCTUnwrap(stored.measurement("frontRise"))
        XCTAssertEqual(rise.valueCm, 0)
        XCTAssertNil(rise.autoValueCm)
        XCTAssertEqual(rise.sourceStatusRaw, "unavailable")
        XCTAssertEqual(stored.visibleMeasurements.map(\.key), ["totalLengthLeft", "waistWidth", "frontRise", "thighWidthRight", "hemWidthLeft"])
        XCTAssertNotNil(stored.measurementPhoto?.landmark("waist_center"))
        XCTAssertNil(stored.measurementPhoto?.landmark("waist_front_center"))
    }

    func testPreviousBottom8KeepsEightMeasurementsAndNeverAcquiresThigh() throws {
        let record = try fixture(.bottoms, legacyBottom8: true)
        let decoded = try JSONDecoder().decode(SavedMeasurement.self, from: recordBytes(record))
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(decoded, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertEqual(stored.measurementPhoto?.measurementModelVersion, AutomaticGarmentKind.legacyBottom8ModelVersion)
        XCTAssertEqual(stored.orderedMeasurements.count, 8)
        XCTAssertNotNil(stored.measurementPhoto?.landmark("waist_front_center"))
        XCTAssertNil(stored.measurementPhoto?.landmark("thigh_right"))
        XCTAssertNil(stored.measurement("thighWidthRight"))
        XCTAssertEqual(stored.visibleMeasurements.map(\.key), ["totalLengthLeft", "waistWidth", "frontRise", "hemWidthLeft"])
        XCTAssertEqual(decoded.definitions.map(\.id), record.definitions.map(\.id))
        XCTAssertTrue(ExportProduct(garment: stored, loadPhoto: { _ in nil }).marketplacePayload.thigh.isEmpty)
    }

    private func putResolvedThigh(_ coordinate: ImagePoint, in result: inout GarmentMeasurementResult,
                                  method: DepthSamplingMethod = .contourIntersection) throws {
        let index = try XCTUnwrap(result.values.firstIndex { $0.id == "bottom.thighWidthRight" })
        let quality = PointQuality(validSamples: 70, candidateSamples: 80, confidenceAvailable: true,
            depthSpreadMeters: 0, planeResidualMeters: nil, method: method)
        result.values[index].points = [
            .init(id: "crotch", imagePoint: .init(x: 0.5, y: coordinate.y),
                  position: .init(x: 0.5, y: coordinate.y, z: 1), quality: quality),
            .init(id: "thigh_right", imagePoint: coordinate,
                  position: .init(x: coordinate.x, y: coordinate.y, z: 1), quality: quality,
                  sourceLandmarkIDs: method == .contourIntersection ? ["waist_left", "waist_right", "crotch"] : nil)
        ]
    }

    func testThighManualOverrideKeepsResolvedAutomaticBaselineAcrossArchiveAndProductReopen() throws {
        var record = try fixture(.bottoms)
        let automatic = ImagePoint(x: 0.76, y: 0.45)
        let manual = ImagePoint(x: 0.72, y: 0.46)
        try putResolvedThigh(automatic, in: &record.result)
        record.originalAutomaticLandmarks = record.landmarks
        record.originalAutomaticResult = record.result
        let index = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "thigh_right" })
        record.landmarks.points[index] = .init(id: "thigh_right", point: manual,
            confidence: nil, isVisible: true, origin: .manual)
        let valueIndex = try XCTUnwrap(record.result.values.firstIndex { $0.id == "bottom.thighWidthRight" })
        record.result.values[valueIndex].meters = 0.34125
        try putResolvedThigh(manual, in: &record.result, method: .garmentPlane)
        let encoded = try recordBytes(record)
        let decoded = try JSONDecoder().decode(SavedMeasurement.self, from: encoded)
        XCTAssertNil(decoded.landmarks.points[index].contourRule)
        XCTAssertEqual(decoded.originalAutomaticLandmarks?.points[index].contourRule, .waistParallelRightThighMaskV1)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("thigh-products.store")
        let photos = directory.appendingPathComponent("photos", isDirectory: true)
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: database, cloudKitDatabase: .none)
            ])
            let stored = try GarmentStore.importMeasurement(decoded, in: ModelContext(container),
                photosDirectory: photos, allowsSynthetic: true)
            XCTAssertEqual(stored.visibleMeasurements.count, 5)
        }
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: database, cloudKitDatabase: .none)
            ])
            let reader = ModelContext(container)
            let stored = try XCTUnwrap(reader.fetch(FetchDescriptor<Garment>()).first)
            let point = try XCTUnwrap(stored.measurementPhoto?.landmark("thigh_right"))
            XCTAssertEqual(point.x, manual.x)
            XCTAssertEqual(point.y, manual.y)
            XCTAssertEqual(point.autoX, automatic.x)
            XCTAssertEqual(point.autoY, automatic.y)
            XCTAssertEqual(point.hasAutomaticObservation, true)
            XCTAssertTrue(point.isMoved)
            XCTAssertNil(point.derivedFrom)
            XCTAssertNil(point.autoDerivedFrom)
            XCTAssertEqual(point.originRaw, "manual")
            XCTAssertEqual(point.autoOriginRaw, "model")
            let value = try XCTUnwrap(stored.measurement("thighWidthRight"))
            XCTAssertEqual(value.valueCm, 34.1, accuracy: 1e-10)
            XCTAssertEqual(try XCTUnwrap(value.autoValueCm), 32.125, accuracy: 1e-10)
            let product = ExportProduct(garment: stored, loadPhoto: { _ in nil })
            XCTAssertEqual(product.marketplacePayload.thigh, "34.1")
            XCTAssertEqual(product.exportMeasurements.map(\.title), ["총장", "허리", "밑위", "허벅지", "밑단"])
            point.resetToAuto()
            XCTAssertEqual(point.x, automatic.x)
            XCTAssertEqual(point.y, automatic.y)
            XCTAssertFalse(point.isMoved)
        }
        XCTAssertEqual(try recordBytes(record), encoded, "Product import must not rewrite the archived raw prediction")
    }

    func testParentEditedThighStoresRecomputedIntersectionWithoutCallingItADirectMove() throws {
        var record = try fixture(.bottoms)
        let automatic = ImagePoint(x: 0.75, y: 0.45)
        let recomputed = ImagePoint(x: 0.73, y: 0.48)
        try putResolvedThigh(automatic, in: &record.result)
        record.originalAutomaticLandmarks = record.landmarks
        record.originalAutomaticResult = record.result
        let parent = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "waist_right" })
        record.landmarks.points[parent].point.y = 0.18
        record.landmarks.points[parent].origin = .manual
        record.landmarks.points[parent].confidence = nil
        record.landmarks = record.landmarks.refreshingDerivations(affectedBy: ["waist_right"])
        try putResolvedThigh(recomputed, in: &record.result)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let point = try XCTUnwrap(stored.measurementPhoto?.landmark("thigh_right"))
        XCTAssertEqual(point.x, recomputed.x)
        XCTAssertEqual(point.y, recomputed.y)
        XCTAssertEqual(point.autoX, automatic.x)
        XCTAssertEqual(point.autoY, automatic.y)
        XCTAssertFalse(point.isMoved)
        XCTAssertNil(point.derivedFrom, "Contour dependence must not be stored as spatial-average parents")
        XCTAssertEqual(stored.measurementPhoto?.landmark("waist_right")?.isMoved, true)
    }

    func testUnavailableThighKeepsBlankRowButDoesNotExportZeroOrInventAutomaticPoint() throws {
        var record = try fixture(.bottoms)
        let index = try XCTUnwrap(record.result.values.firstIndex { $0.id == "bottom.thighWidthRight" })
        record.result.values[index].meters = nil
        record.result.values[index].status = .unavailable
        record.result.values[index].failure = .contourIntersectionUnavailable
        record.result.values[index].points = []
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let value = try XCTUnwrap(stored.measurement("thighWidthRight"))
        XCTAssertEqual(value.valueCm, 0)
        XCTAssertNil(value.autoValueCm)
        XCTAssertEqual(value.sourceStatusRaw, "unavailable")
        XCTAssertEqual(stored.visibleMeasurements.count, 5)
        let point = try XCTUnwrap(stored.measurementPhoto?.landmark("thigh_right"))
        XCTAssertEqual(point.isVisible, false)
        XCTAssertEqual(point.hasAutomaticObservation, false)
        XCTAssertFalse(point.isMoved)
        let product = ExportProduct(garment: stored, loadPhoto: { _ in nil })
        XCTAssertTrue(product.marketplacePayload.thigh.isEmpty)
        XCTAssertFalse(product.exportMeasurements.contains { $0.id == "thighWidthRight" })
        XCTAssertEqual(product.exportMeasurements.map(\.title), ["총장", "허리", "밑위", "밑단"])
    }

    func testExplicitThighEndpointRestorationDoesNotInventAnAutomaticBaseline() throws {
        var record = try fixture(.bottoms)
        record.originalAutomaticLandmarks = record.landmarks
        record.originalAutomaticLandmarks?.points.removeAll { $0.id == "thigh_right" }
        record.originalAutomaticResult = record.result
        let valueIndex = try XCTUnwrap(record.result.values.firstIndex { $0.id == "bottom.thighWidthRight" })
        record.originalAutomaticResult?.values[valueIndex].meters = nil
        record.originalAutomaticResult?.values[valueIndex].status = .unavailable
        record.originalAutomaticResult?.values[valueIndex].failure = .missingLandmark
        for (id, x) in [("crotch", 0.5), ("thigh_right", 0.75)] {
            let index = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == id })
            record.landmarks.points[index] = .init(id: id, point: .init(x: x, y: 0.45),
                confidence: nil, isVisible: true, origin: .manual)
        }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let point = try XCTUnwrap(stored.measurementPhoto?.landmark("thigh_right"))
        XCTAssertEqual(point.hasAutomaticObservation, false)
        XCTAssertTrue(point.isMoved)
        XCTAssertEqual(point.x, 0.75)
        XCTAssertEqual(point.originRaw, "manual")
        XCTAssertNil(stored.measurement("thighWidthRight")?.autoValueCm)
        XCTAssertGreaterThan(stored.measurement("thighWidthRight")?.valueCm ?? 0, 0)
    }

    func testBottomModelDefinitionAndContourMismatchesAreRejectedBeforeWritingPhotos() throws {
        let current = try fixture(.bottoms)
        let previous = try fixture(.bottoms, legacyBottom8: true)
        var invalid: [SavedMeasurement] = []
        var changed = current
        changed.landmarks.modelVersion = AutomaticGarmentKind.legacyBottom8ModelVersion
        invalid.append(changed)
        changed = previous
        changed.landmarks.modelVersion = AutomaticGarmentKind.bottoms.modelVersion
        invalid.append(changed)
        let index = try XCTUnwrap(current.landmarks.points.firstIndex { $0.id == "thigh_right" })
        changed = current
        changed.landmarks.points[index].contourRule = .neckPerpendicularMaskV1
        invalid.append(changed)
        changed = current
        changed.landmarks.points[index].derivedFrom = ["waist_left", "waist_right", "crotch"]
        invalid.append(changed)
        changed = current
        changed.landmarks.points[index].contourRule = nil
        invalid.append(changed)
        changed = current
        changed.landmarks.points[index].confidence = 0.8
        invalid.append(changed)
        changed = current
        changed.landmarks.modelVersion = "unknown-bottom-model"
        invalid.append(changed)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for record in invalid {
            XCTAssertThrowsError(try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
                photosDirectory: directory, allowsSynthetic: true))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testNewTotalLengthManualRestorationAndAutomaticBaselineStaySeparate() throws {
        var record = try fixture(.top)
        let original = record.landmarks
        record.originalAutomaticLandmarks = original
        record.originalAutomaticResult = record.result
        record.originalAutomaticLandmarks?.points.removeAll { $0.id == "top_length_start" }
        record.originalAutomaticResult?.values[5].meters = nil
        record.originalAutomaticResult?.values[5].status = .unavailable
        record.originalAutomaticResult?.values[5].failure = .missingLandmark
        for (id, y) in [("top_length_start", 0.2), ("hem_center", 0.8)] {
            let index = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == id })
            record.landmarks.points[index] = .init(id: id, point: .init(x: 0.5, y: y),
                confidence: nil, isVisible: true, origin: .manual)
        }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertEqual(stored.measurementPhoto?.landmark("top_length_start")?.hasAutomaticObservation, false)
        XCTAssertEqual(stored.measurementPhoto?.landmark("top_length_start")?.originRaw, "manual")
        XCTAssertNil(stored.measurement("totalLength")?.autoValueCm)
        XCTAssertGreaterThan(stored.measurement("totalLength")?.valueCm ?? 0, 0)
    }

    /// Fabricated calculated points verify the import boundary independently
    /// of the model and plane solver; they make no physical-accuracy claim.
    private func putResolvedContour(_ coordinate: ImagePoint, in result: inout GarmentMeasurementResult) throws {
        let index = try XCTUnwrap(result.values.firstIndex { $0.id == "top.totalLength" })
        result.values[index].points = [.init(id: "top_length_start", imagePoint: coordinate,
            position: .init(x: coordinate.x, y: coordinate.y, z: 1),
            quality: .init(validSamples: 70, candidateSamples: 80, confidenceAvailable: true,
                depthSpreadMeters: 0, planeResidualMeters: nil, method: .contourIntersection),
            sourceLandmarkIDs: ["neck_left", "neck_right", "hem_center"])]
    }

    private func recordBytes(_ record: SavedMeasurement) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(record)
    }

    func testAutomaticContourPersistsResolvedIntersectionAndResetsToThatSameCoordinate() throws {
        var record = try fixture(.top)
        let raw = try XCTUnwrap(record.landmarks.points.first { $0.id == "top_length_start" })
        XCTAssertFalse(raw.isVisible)
        let intersection = ImagePoint(x: 0.45, y: 0.14)
        XCTAssertNotEqual(raw.point, intersection)
        try putResolvedContour(intersection, in: &record.result)
        let originalBytes = try recordBytes(record)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let point = try XCTUnwrap(stored.measurementPhoto?.landmark("top_length_start"))
        XCTAssertEqual(point.x, intersection.x)
        XCTAssertEqual(point.y, intersection.y)
        XCTAssertEqual(point.autoX, intersection.x)
        XCTAssertEqual(point.autoY, intersection.y)
        XCTAssertEqual(point.isVisible, true)
        XCTAssertEqual(point.autoIsVisible, true)
        XCTAssertEqual(point.hasAutomaticObservation, true)
        XCTAssertFalse(point.isMoved)
        XCTAssertNil(point.derivedFrom, "Contour dependence must not be stored as a spatial mean")
        XCTAssertNil(point.autoDerivedFrom)
        point.move(toX: 0.51, y: 0.2)
        point.resetToAuto()
        XCTAssertEqual(point.x, intersection.x)
        XCTAssertEqual(point.y, intersection.y)
        XCTAssertEqual(point.isVisible, true)
        XCTAssertFalse(point.isMoved)
        XCTAssertEqual(try recordBytes(record), originalBytes, "Product import never rewrites raw placeholder evidence")
    }

    func testRecomputedContourAfterParentEditCanSaveWithoutBecomingADirectOverride() throws {
        var record = try fixture(.top)
        let automaticPoint = ImagePoint(x: 0.45, y: 0.14)
        let revisedPoint = ImagePoint(x: 0.46, y: 0.13)
        try putResolvedContour(automaticPoint, in: &record.result)
        record.originalAutomaticLandmarks = record.landmarks
        record.originalAutomaticResult = record.result
        let parent = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "neck_left" })
        record.landmarks.points[parent].point.x += 0.01
        record.landmarks.points[parent].origin = .manual
        record.landmarks.points[parent].confidence = nil
        record.landmarks = record.landmarks.refreshingDerivations(affectedBy: ["neck_left"])
        try putResolvedContour(revisedPoint, in: &record.result)
        let contour = try XCTUnwrap(record.landmarks.points.first { $0.id == "top_length_start" })
        XCTAssertEqual(contour.origin, .manual)
        XCTAssertEqual(contour.contourRule, .neckPerpendicularMaskV1)
        XCTAssertNil(contour.derivedFrom)
        let originalBytes = try recordBytes(record)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let point = try XCTUnwrap(stored.measurementPhoto?.landmark("top_length_start"))
        XCTAssertEqual(point.x, revisedPoint.x)
        XCTAssertEqual(point.y, revisedPoint.y)
        XCTAssertEqual(point.autoX, automaticPoint.x)
        XCTAssertEqual(point.autoY, automaticPoint.y)
        XCTAssertEqual(point.originRaw, "manual")
        XCTAssertFalse(point.isMoved, "A recomputed intersection is not a directly edited observation")
        XCTAssertEqual(point.movedDistance, 0)
        XCTAssertNil(point.derivedFrom)
        XCTAssertNil(point.autoDerivedFrom)
        point.resetToAuto()
        XCTAssertEqual(point.x, automaticPoint.x)
        XCTAssertEqual(point.y, automaticPoint.y)
        XCTAssertEqual(point.originRaw, "model")
        XCTAssertEqual(point.isVisible, true)
        XCTAssertEqual(try recordBytes(record), originalBytes)
    }

    func testManualContourOverrideKeepsDirectPositionAndOriginalResolvedAutomaticReset() throws {
        var record = try fixture(.top)
        let automaticPoint = ImagePoint(x: 0.45, y: 0.14)
        let manualPoint = ImagePoint(x: 0.47, y: 0.2)
        try putResolvedContour(automaticPoint, in: &record.result)
        record.originalAutomaticLandmarks = record.landmarks
        record.originalAutomaticResult = record.result
        let index = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "top_length_start" })
        record.landmarks.points[index] = .init(id: "top_length_start", point: manualPoint,
            confidence: nil, isVisible: true, origin: .manual)
        // No current contour result exists after a direct override; its source
        // coordinate is the explicit manual point, never an old automatic hint.
        record.result.values[5].points = []
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let point = try XCTUnwrap(stored.measurementPhoto?.landmark("top_length_start"))
        XCTAssertEqual(point.x, manualPoint.x)
        XCTAssertEqual(point.y, manualPoint.y)
        XCTAssertEqual(point.autoX, automaticPoint.x)
        XCTAssertEqual(point.autoY, automaticPoint.y)
        XCTAssertEqual(point.isVisible, true)
        XCTAssertEqual(point.hasAutomaticObservation, true)
        XCTAssertTrue(point.isMoved)
        point.resetToAuto()
        XCTAssertEqual(point.x, automaticPoint.x)
        XCTAssertEqual(point.y, automaticPoint.y)
        XCTAssertEqual(point.isVisible, true)
        XCTAssertFalse(point.isMoved)
    }

    func testUnresolvedContourDoesNotInventAutomaticResetCoordinate() throws {
        var record = try fixture(.top)
        record.originalAutomaticLandmarks = record.landmarks
        record.originalAutomaticResult = record.result
        record.originalAutomaticResult?.values[5].meters = nil
        record.originalAutomaticResult?.values[5].status = .unavailable
        record.originalAutomaticResult?.values[5].failure = .missingLandmark
        let index = try XCTUnwrap(record.landmarks.points.firstIndex { $0.id == "top_length_start" })
        let manualPoint = ImagePoint(x: 0.47, y: 0.2)
        record.landmarks.points[index] = .init(id: "top_length_start", point: manualPoint,
            confidence: nil, isVisible: true, origin: .manual)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
            photosDirectory: directory, allowsSynthetic: true)
        let point = try XCTUnwrap(stored.measurementPhoto?.landmark("top_length_start"))
        XCTAssertEqual(point.hasAutomaticObservation, false)
        XCTAssertTrue(point.isMoved)
        XCTAssertEqual(point.movedDistance, 0)
        point.resetToAuto()
        XCTAssertEqual(point.x, manualPoint.x)
        XCTAssertEqual(point.y, manualPoint.y)
        XCTAssertEqual(point.isVisible, true)
    }

    func testModelVersionPointAndDefinitionMixesAreRejected() throws {
        let current = try fixture(.top)
        let old = try fixture(.top, legacy: true)
        var invalid: [SavedMeasurement] = []
        var modified = current
        modified.landmarks.modelVersion = AutomaticGarmentKind.legacyTopModelVersion
        invalid.append(modified)
        modified = old
        modified.landmarks.modelVersion = AutomaticGarmentKind.top.modelVersion
        invalid.append(modified)
        modified = current
        modified.definitions = TopLandmarkSchema.legacyMeasurementDefinitions
        invalid.append(modified)
        modified = current
        let index = try XCTUnwrap(modified.landmarks.points.firstIndex { $0.id == "top_length_start" })
        modified.landmarks.points[index].contourRule = nil
        invalid.append(modified)
        modified = current
        modified.landmarks.points[index].derivedFrom = ["neck_left", "neck_right", "hem_center"]
        invalid.append(modified)
        var bottom = try fixture(.bottoms)
        bottom.landmarks.modelVersion = AutomaticGarmentKind.legacyBottomModelVersion
        invalid.append(bottom)
        bottom = try fixture(.bottoms, legacy: true)
        bottom.landmarks.modelVersion = AutomaticGarmentKind.bottoms.modelVersion
        invalid.append(bottom)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for record in invalid {
            XCTAssertThrowsError(try GarmentStore.importMeasurement(record, in: ModelContext(makeContainer()),
                photosDirectory: directory, allowsSynthetic: true))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPartialMeasurementsRemainPartialAndUncertainStatusIsNotUpgraded() throws {
        let container = try makeContainer()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var record = try fixture()
        record.result.values[1].status = .unavailable
        record.result.values[1].meters = nil
        record.result.values[1].failure = .insufficientDepth
        record.result.values[3].status = .uncertain
        let garment = try GarmentStore.importMeasurement(record, in: ModelContext(container),
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertEqual(garment.orderedMeasurements.count, 6)
        XCTAssertEqual(garment.measurement("chestWidth")?.valueCm, 0)
        XCTAssertEqual(GarmentMeasurementInputText.format(garment.measurement("chestWidth")!.valueCm), "")
        XCTAssertEqual(garment.visibleMeasurements.map(\.key), ["totalLength", "shoulderWidth", "chestWidth", "sleeveLengthLeft"])
        XCTAssertNil(garment.chestCm)
        XCTAssertEqual(garment.orderedMeasurements.map(\.displayOrder), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(garment.measurement("sleeveLengthLeft")?.sourceStatusRaw, "uncertain")
        XCTAssertEqual(record.result.values[1].status, .unavailable, "The archive input stays untouched")
    }

    func testRepeatImportDoesNotOverwriteProductEditsOrCreateDuplicatePhotos() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try fixture()
        let first = try GarmentStore.importMeasurement(record, in: context,
            photosDirectory: directory, allowsSynthetic: true)
        first.name = "사용자가 입력한 이름"
        first.measurement("chestWidth")?.update(to: 63.5)
        try context.save()
        let again = try GarmentStore.importMeasurement(record, in: context,
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertTrue(first === again)
        XCTAssertEqual(again.name, "사용자가 입력한 이름")
        XCTAssertEqual(again.measurement("chestWidth")?.valueCm, 63.5)
        XCTAssertEqual(again.measurement("chestWidth")?.autoValueCm, 60)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Garment>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GarmentPhoto>()), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testJPEGOrientationIsLosslessAndRawLandmarksStayInOriginalCoordinates() throws {
        let container = try makeContainer()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected: [ImageOrientation: UIImage.Orientation] = [.up: .up, .right: .right, .down: .down, .left: .left]
        for orientation in ImageOrientation.allCases {
            let record = try fixture(orientation: orientation)
            let garment = try GarmentStore.importMeasurement(record, in: ModelContext(container),
                photosDirectory: directory, allowsSynthetic: true)
            let photo = try XCTUnwrap(garment.measurementPhoto)
            let bytes = try Data(contentsOf: directory.appendingPathComponent(photo.fileName))
            let original = try XCTUnwrap(UIImage(data: record.snapshot.imageJPEG)?.cgImage)
            let imported = try XCTUnwrap(UIImage(data: bytes))
            XCTAssertEqual(imported.imageOrientation, expected[orientation])
            XCTAssertEqual(imported.cgImage?.width, 800)
            XCTAssertEqual(imported.cgImage?.height, 600)
            XCTAssertEqual(original.dataProvider?.data as Data?, imported.cgImage?.dataProvider?.data as Data?,
                           "Adding EXIF orientation must not recompress or rotate RGB pixels")
            XCTAssertEqual(photo.measurementOrientationRaw, orientation.rawValue)
            XCTAssertEqual(photo.orderedLandmarks.map(\.x), record.landmarks.points.map(\.point.x))
            XCTAssertEqual(photo.orderedLandmarks.map(\.y), record.landmarks.points.map(\.point.y))
        }
    }

    func testFailureRemovesOnlyNewFileAndPreservesUnrelatedDirtyModelChanges() throws {
        enum InjectedFailure: Error { case save }
        let container = try makeContainer()
        let context = ModelContext(container)
        let unrelated = Garment(category: "Shirt", group: .top, name: "저장한 이름")
        context.insert(unrelated)
        try context.save()
        unrelated.name = "아직 저장하지 않은 수정"
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("existing-user-photo.jpg")
        try Data([1, 2, 3]).write(to: sentinel)
        let record = try fixture()
        XCTAssertThrowsError(try GarmentStore.importMeasurement(record, in: context,
            photosDirectory: directory, allowsSynthetic: true, save: { _ in throw InjectedFailure.save }))
        XCTAssertEqual(unrelated.name, "아직 저장하지 않은 수정")
        XCTAssertTrue(context.hasChanges)
        let persisted = try ModelContext(container).fetch(FetchDescriptor<Garment>())
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.name, "저장한 이름")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing-user-photo.jpg"])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([1, 2, 3]))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<GarmentPhoto>()), 0)
    }

    func testSuccessDoesNotSaveUnrelatedDirtyModelChanges() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let unrelated = Garment(category: "Shirt", group: .top, name: "저장한 이름")
        context.insert(unrelated)
        try context.save()
        unrelated.name = "아직 저장하지 않은 수정"
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try fixture()
        let garment = try GarmentStore.importMeasurement(record, in: context,
            photosDirectory: directory, allowsSynthetic: true)
        XCTAssertEqual(garment.id, record.id)
        XCTAssertEqual(unrelated.name, "아직 저장하지 않은 수정")
        let persisted = try ModelContext(container).fetch(FetchDescriptor<Garment>())
        XCTAssertEqual(persisted.first { $0.id == unrelated.id }?.name, "저장한 이름")
        XCTAssertTrue(context.hasChanges)
    }

    func testBadEvidenceIsRejectedBeforeCreatingFilesOrModels() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = try fixture()
        var records: [SavedMeasurement] = []
        var bad = valid
        bad.result.frameID = UUID()
        records.append(bad)
        bad = valid
        bad.landmarks.garmentKind = .bottoms
        records.append(bad)
        bad = valid
        bad.landmarks.modelVersion = "unverified-model"
        records.append(bad)
        bad = valid
        bad.definitions[0].landmarkIDs = ["hem_left", "hem_right"]
        records.append(bad)
        bad = valid
        bad.snapshot.imageJPEG = Data([1, 2, 3])
        records.append(bad)
        bad = valid
        bad.snapshot.frame.imageSize.width = 801
        records.append(bad)
        bad = valid
        bad.result.values[0].meters = .infinity
        records.append(bad)
        bad = valid
        bad.result.values[0].meters = Double.greatestFiniteMagnitude
        records.append(bad)
        bad = valid
        for index in bad.result.values.indices {
            bad.result.values[index].status = .unavailable
            bad.result.values[index].meters = nil
        }
        records.append(bad)
        bad = valid
        bad.originalAutomaticLandmarks = valid.landmarks
        bad.originalAutomaticResult = valid.result
        bad.originalAutomaticResult?.sessionID = UUID()
        records.append(bad)
        for invalid in [Double.nan, Double.infinity, -1, 0, Double.greatestFiniteMagnitude] {
            bad = valid
            bad.originalAutomaticLandmarks = valid.landmarks
            bad.originalAutomaticResult = valid.result
            bad.originalAutomaticResult?.values[0].meters = invalid
            records.append(bad)
        }
        for record in records {
            XCTAssertThrowsError(try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: directory, allowsSynthetic: true))
        }
        XCTAssertThrowsError(try GarmentStore.importMeasurement(valid, in: context,
            photosDirectory: directory), "Production import rejects synthetic test records")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Garment>()), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testExplicitUIPreviewCanExerciseHandoffWithoutPretendingToBeModelEvidence() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for kind in AutomaticGarmentKind.allCases {
            let record = try GarmentCapturePreview.measurement(kind: kind).makeRecord()
            XCTAssertThrowsError(try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: directory))
            let garment = try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: directory, allowsSynthetic: true)
            XCTAssertEqual(garment.measurementPhoto?.measurementLandmarkOriginRaw, "synthetic")
            XCTAssertEqual(garment.measurementPhoto?.measurementDepthSourceRaw, "synthetic")
            XCTAssertEqual(garment.measurementPhoto?.measurementModelVersion, record.landmarks.modelVersion)
            XCTAssertTrue(garment.orderedMeasurements.allSatisfy { $0.valueCm.isFinite && $0.valueCm > 0 })
            XCTAssertEqual(garment.measurementPhoto?.landmarks.first?.originRaw, "synthetic")
        }
    }

    func testPersistedLandmarkResetRestoresOriginalProvenanceAndConfidence() throws {
        let point = LandmarkPoint(name: "shoulder_left", index: 0, x: 0.2, y: 0.3)
        point.originRaw = "model"
        point.autoOriginRaw = "model"
        point.confidence = 0.91
        point.autoConfidence = 0.91
        point.isVisible = true
        point.autoIsVisible = true
        point.move(toX: 0.24, y: 0.32)
        XCTAssertEqual(point.originRaw, "manual")
        XCTAssertNil(point.confidence)
        XCTAssertEqual(point.autoConfidence, 0.91)
        point.resetToAuto()
        XCTAssertEqual(point.x, 0.2)
        XCTAssertEqual(point.y, 0.3)
        XCTAssertEqual(point.originRaw, "model")
        XCTAssertEqual(point.confidence, 0.91)
        XCTAssertFalse(point.isMoved)
    }

    func testDiskReopenPreservesCorrectedEvidenceSelectionAndSubsequentUserInput() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("products.store")
        let photos = directory.appendingPathComponent("photos", isDirectory: true)
        let record = try fixture(corrected: true)
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)
            ])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let garment = try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: photos, allowsSynthetic: true)
            XCTAssertTrue(garment.modelContext === context, "The product must be editable in the caller's context")
            garment.name = "재실행 후 확인할 제품"
            garment.informationCompletedAt = Date(timeIntervalSince1970: 1_790_200_123)
            garment.measurement("chestWidth")?.update(to: 64.125)
            let measured = try XCTUnwrap(garment.measurementPhoto)
            measured.isSelectedForProduct = false
            measured.role = .detail
            let detail = GarmentPhoto(fileName: "selected-detail.jpg", role: .thumbnail, order: 1)
            detail.isSelectedForProduct = true
            context.insert(detail)
            garment.photos.append(detail)
            detail.garment = garment
            try record.snapshot.imageJPEG.write(to: photos.appendingPathComponent(detail.fileName))
            try context.save()
        }
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)
            ])
            let context = ModelContext(container)
            let garment = try XCTUnwrap(context.fetch(FetchDescriptor<Garment>()).first)
            XCTAssertEqual(garment.id, record.id)
            XCTAssertEqual(garment.name, "재실행 후 확인할 제품")
            XCTAssertEqual(garment.informationCompletedAt, Date(timeIntervalSince1970: 1_790_200_123))
            let chest = try XCTUnwrap(garment.measurement("chestWidth"))
            XCTAssertEqual(chest.valueCm, 64.125)
            XCTAssertEqual(chest.autoValueCm, 60)
            XCTAssertTrue(chest.isEdited)
            XCTAssertEqual(chest.sourceStatusRaw, "valid")
            XCTAssertEqual(garment.measurementPhoto?.isSelectedForProduct, false)
            XCTAssertEqual(garment.productPhotos.map(\.fileName), ["selected-detail.jpg"])
            XCTAssertEqual(garment.measurementPhoto?.landmark("armpit_left")?.originRaw, "manual")
            XCTAssertEqual(garment.measurementPhoto?.landmark("armpit_left")?.autoOriginRaw, "model")
            XCTAssertEqual(garment.measurementPhoto?.landmark("neck_center")?.derivedFrom, ["neck_left", "neck_right"])
            let product = ExportProduct(garment: garment, loadPhoto: {
                try? Data(contentsOf: photos.appendingPathComponent($0.fileName))
            })
            XCTAssertEqual(product.exportMeasurements.first { $0.id == "chestWidth" }?.value, "64.125")
            XCTAssertEqual(product.photos.count, 1)
            let same = try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: photos, allowsSynthetic: true)
            XCTAssertTrue(same === garment)
            XCTAssertEqual(same.measurement("chestWidth")?.valueCm, 64.125)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Garment>()), 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photos.path).count, 2)
        }
    }

    func testLegacyMainDiskStoreMigratesWithoutLosingExistingProductOrMeasurements() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("legacy-products.store")
        let identifier = UUID()
        let photoIdentifier = UUID()
        let pointIdentifier = UUID()
        try autoreleasepool {
            let schema = LegacyMainProductSchema.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)
            ])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let garment = LegacyMainProductSchema.Garment(id: identifier)
            context.insert(garment)
            let measured = LegacyMainProductSchema.MeasuredValue()
            context.insert(measured)
            garment.measurements.append(measured)
            measured.garment = garment
            let photo = LegacyMainProductSchema.GarmentPhoto(id: photoIdentifier)
            context.insert(photo)
            garment.photos.append(photo)
            photo.garment = garment
            let point = LegacyMainProductSchema.LandmarkPoint(id: pointIdentifier)
            context.insert(point)
            photo.landmarks.append(point)
            point.photo = photo
            let exported = LegacyMainProductSchema.ExportRecord()
            context.insert(exported)
            garment.exports.append(exported)
            exported.garment = garment
            try context.save()
        }
        try autoreleasepool {
            let schema = ProductAppStorage.schema
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)
            ])
            let context = ModelContext(container)
            let garment = try XCTUnwrap(context.fetch(FetchDescriptor<Garment>()).first)
            XCTAssertEqual(garment.id, identifier)
            XCTAssertEqual(garment.name, "기존 저장 제품")
            XCTAssertEqual(garment.brand, "기존 브랜드")
            XCTAssertEqual(garment.price, 23000)
            XCTAssertEqual(garment.group, .top)
            XCTAssertNil(garment.sourceMeasurementID)
            XCTAssertNil(garment.informationCompletedAt)
            XCTAssertEqual(garment.measurement("chestWidth")?.valueCm, 53.25)
            XCTAssertEqual(garment.measurement("chestWidth")?.autoValueCm, 51)
            XCTAssertEqual(garment.measurement("chestWidth")?.isEdited, true)
            XCTAssertNil(garment.measurement("chestWidth")?.sourceStatusRaw)
            let photo = try XCTUnwrap(garment.measurementPhoto)
            XCTAssertEqual(photo.id, photoIdentifier)
            XCTAssertNil(photo.isSelectedForProduct, "Legacy photos stay selected without a forced true migration")
            XCTAssertNil(photo.measurementRecordID)
            XCTAssertEqual(garment.productPhotos.map(\.id), [photoIdentifier])
            let point = try XCTUnwrap(photo.landmark("armpit_left"))
            XCTAssertEqual(point.id, pointIdentifier)
            XCTAssertEqual(point.x, 0.21)
            XCTAssertEqual(point.autoX, 0.2)
            XCTAssertTrue(point.isMoved)
            XCTAssertNil(point.originRaw)
            XCTAssertEqual(point.photo?.garment?.id, identifier)
            XCTAssertEqual(garment.exports.count, 1)
            XCTAssertEqual(garment.exports.first?.succeeded, true)
            XCTAssertEqual(garment.exports.first?.garment?.id, identifier)
            XCTAssertNil(garment.selectedExportChannelRawValues)
            XCTAssertEqual(garment.selectedExportChannels, [.instagram])
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Garment>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<GarmentPhoto>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MeasuredValue>()), 1)
            try context.save()
        }
    }

    func testPhotoPublishPreservesExistingDestinationAndCleansPrivateStaging() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.jpg")
        let original = try fixture().snapshot.imageJPEG
        try original.write(to: destination)
        let replacement = Data([1, 2, 3])
        XCTAssertThrowsError(try GarmentStore.writeMeasurementPhoto(replacement, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.jpg"])
        let newDestination = directory.appendingPathComponent("new.jpg")
        try GarmentStore.writeMeasurementPhoto(original, to: newDestination)
        XCTAssertEqual(try Data(contentsOf: newDestination), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["existing.jpg", "new.jpg"]))
    }
}

/// Stored-property shape from merged main 2328117, before flowConnection's
/// optional metadata. Nested model names match the original entity names; this
/// creates a genuine old SQLite store and exercises automatic migration.
private enum LegacyMainProductSchema {
    static var schema: Schema {
        Schema([Garment.self, GarmentPhoto.self, LandmarkPoint.self, MeasuredValue.self, ExportRecord.self])
    }

    @Model final class Garment {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var category: String
        var groupRaw: String
        var name: String
        var brand: String
        var detail: String
        var price: Int?
        var lengthCm: Double?
        var shoulderCm: Double?
        var chestCm: Double?
        var sleeveCm: Double?
        var waistCm: Double?
        @Relationship(deleteRule: .cascade, inverse: \GarmentPhoto.garment)
        var photos: [GarmentPhoto] = []
        @Relationship(deleteRule: .cascade, inverse: \MeasuredValue.garment)
        var measurements: [MeasuredValue] = []
        @Relationship(deleteRule: .cascade, inverse: \ExportRecord.garment)
        var exports: [ExportRecord] = []
        init(id: UUID) {
            let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
            self.id = id
            createdAt = timestamp
            updatedAt = timestamp
            category = "Shirt"
            groupRaw = "top"
            name = "기존 저장 제품"
            brand = "기존 브랜드"
            detail = "기존 설명"
            price = 23000
            chestCm = 53.25
        }
    }

    @Model final class GarmentPhoto {
        @Attribute(.unique) var id: UUID
        var fileName: String
        var roleRaw: String
        var order: Int
        var capturedAt: Date
        var isMeasurementSource: Bool
        var imageWidth: Int?
        var imageHeight: Int?
        var garmentScore: Double?
        var pixelsPerCm: Double?
        @Relationship(deleteRule: .cascade, inverse: \LandmarkPoint.photo)
        var landmarks: [LandmarkPoint] = []
        var garment: Garment?
        init(id: UUID) {
            self.id = id
            fileName = "legacy-test-owned.jpg"
            roleRaw = "thumbnail"
            order = 0
            capturedAt = Date(timeIntervalSince1970: 1_790_000_000)
            isMeasurementSource = true
            imageWidth = 800
            imageHeight = 600
        }
    }

    @Model final class LandmarkPoint {
        @Attribute(.unique) var id: UUID
        var name: String
        var index: Int
        var x: Double
        var y: Double
        var autoX: Double
        var autoY: Double
        var isMoved: Bool
        var photo: GarmentPhoto?
        init(id: UUID) {
            self.id = id
            name = "armpit_left"
            index = 0
            x = 0.21
            y = 0.3
            autoX = 0.2
            autoY = 0.3
            isMoved = true
        }
    }

    @Model final class MeasuredValue {
        @Attribute(.unique) var id: UUID
        var key: String
        var label: String
        var displayOrder: Int
        var valueCm: Double
        var autoValueCm: Double?
        var isEdited: Bool
        var garment: Garment?
        init() {
            id = UUID()
            key = "chestWidth"
            label = "가슴 단면"
            displayOrder = 0
            valueCm = 53.25
            autoValueCm = 51
            isEdited = true
        }
    }

    @Model final class ExportRecord {
        @Attribute(.unique) var id: UUID
        var channelRaw: String
        var exportedAt: Date
        var succeeded: Bool
        var message: String?
        var garment: Garment?
        init() {
            id = UUID()
            channelRaw = "instagram"
            exportedAt = Date(timeIntervalSince1970: 1_790_000_000)
            succeeded = true
        }
    }
}

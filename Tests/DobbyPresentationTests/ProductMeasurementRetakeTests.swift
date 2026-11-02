// Created by mason on 10/30/26.
import SwiftData
import UIKit
import XCTest
@testable import Dobby

/// Synthetic captures test draft transactions, not ML or LiDAR accuracy.
@MainActor
final class ProductMeasurementRetakeTests: XCTestCase {
    func testRetakeKeepsProductDetailsSelectionAndCaptureProvenanceThroughReloadAndSave() async throws {
        let f = try await Fixture()
        defer { f.remove() }
        let previousID = f.garment.id
        let originalID = f.model.input.measurement.id
        let previousURLs = f.measurementURLs
        let record = try GarmentCapturePreview.measurement(kind: .bottoms).makeRecord()
        XCTAssertNotEqual(record.snapshot.frame.sessionID, f.record.snapshot.frame.sessionID)
        let result = try await f.replace(record)
        let replacement = result.photoModel
        let visual = try XCTUnwrap(replacement.input.measurementVisualization)
        let selected = [f.detail.id, visual.id, originalID]
        XCTAssertEqual(result.garment.id, previousID)
        XCTAssertEqual(result.garment.brand, "retained brand")
        XCTAssertEqual(result.garment.group, .pants)
        XCTAssertNil(result.garment.measurement("chestWidth"))
        XCTAssertNotNil(result.garment.measurement("waistWidth"))
        XCTAssertEqual(replacement.detailPhotos, [f.detail])
        XCTAssertEqual(replacement.selectedPhotoIDs, selected)
        XCTAssertEqual(replacement.output?.representativePhotoID, f.detail.id)
        XCTAssertTrue(replacement.hasAcknowledgedCaptureGuide)
        XCTAssertEqual(f.model.measurementRecord?.id, f.record.id, "Old model is not partially mutated")
        XCTAssertEqual(result.garment.creationDraft?.measurementInputData, Data("new input".utf8))
        for url in previousURLs { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }

        let reader = ModelContext(f.container)
        let saved = try XCTUnwrap(reader.fetch(FetchDescriptor<Garment>()).first)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<Garment>()), 1)
        var input = try ProductPhotoHandoff.makeInput(for: saved,
            sessionID: record.snapshot.frame.sessionID, photosDirectory: f.directory)
        input.measurementVisualization = try await MeasurementProductPhoto.prepare(record: record,
            garment: saved, in: reader, directory: f.directory)
        let snapshot = try XCTUnwrap(saved.creationDraft?.photoState)
        let details = try snapshot.restoredDetailPhotos(for: input)
        XCTAssertEqual(details, [f.detail], "Retained file path and original capture session survive reload")
        let restored = try ProductPhotoModel(input: input, captureProvider: NoCapture(),
            initialDetailPhotos: details, initialSelectedPhotoIDs: snapshot.selectedPhotoIDs, measurementRecord: record)
        try await ProductPhotoHandoff.apply(XCTUnwrap(restored.output), to: saved, in: reader,
            input: input, photosDirectory: f.directory)
        XCTAssertEqual(saved.productPhotos.map(\.id), selected)
        XCTAssertEqual(saved.thumbnail?.id, f.detail.id)
    }

    func testFailedReplacementSaveRestoresLatestDraftAndRemovesOnlyNewFiles() async throws {
        let f = try await Fixture()
        defer { f.remove() }
        let files = try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted()
        let previousIDs = f.model.selectedPhotoIDs
        let record = try GarmentCapturePreview.measurement(kind: .bottoms).makeRecord()
        do {
            _ = try await f.replace(record, persist: { _ in throw TestError.save })
            XCTFail("Expected save failure")
        } catch TestError.save { }
        XCTAssertEqual(f.garment.sourceMeasurementID, f.record.id)
        XCTAssertEqual(f.garment.group, .top)
        XCTAssertNotNil(f.garment.measurement("chestWidth"))
        XCTAssertNil(f.garment.measurement("waistWidth"))
        XCTAssertEqual(f.model.selectedPhotoIDs, previousIDs)
        XCTAssertEqual(f.garment.brand, "retained brand")
        XCTAssertEqual(f.garment.creationDraft?.measurementInputData, Data("old input".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted(), files)
        let reader = ModelContext(f.container)
        let saved = try XCTUnwrap(reader.fetch(FetchDescriptor<Garment>()).first)
        XCTAssertEqual(saved.sourceMeasurementID, f.record.id)
        XCTAssertEqual(saved.creationDraft?.photoState?.selectedPhotoIDs, previousIDs)
        let retry = try await f.replace(record)
        XCTAssertEqual(retry.photoModel.measurementRecord?.id, record.id)
    }

    func testOldDraftWithoutPerPhotoSessionStillRestores() async throws {
        let f = try await Fixture()
        defer { f.remove() }
        let snapshot = try f.model.makeDraftSnapshot()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var photos = try XCTUnwrap(json["detailPhotos"] as? [[String: Any]])
        for index in photos.indices { photos[index].removeValue(forKey: "sessionID") }
        json["detailPhotos"] = photos
        let legacy = try JSONDecoder().decode(ProductPhotoDraftSnapshot.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(try legacy.restoredDetailPhotos(for: f.model.input), [f.detail])
    }

    func testConsecutiveRetakesReplaceEvidenceWithoutDuplicatingProductOrLosingDetailBytes() async throws {
        let f = try await Fixture()
        defer { f.remove() }
        guard case let .localFile(detailURL, _) = f.detail.source else { return XCTFail("Missing detail") }
        let detailBytes = try Data(contentsOf: detailURL)
        let firstRecord = try GarmentCapturePreview.measurement(kind: .bottoms).makeRecord()
        let first = try await f.replace(firstRecord)
        let finalRecord = try GarmentCapturePreview.measurement(kind: .top).makeRecord()
        let final = try await ProductMeasurementRetake.replace(finalRecord, garment: first.garment,
            photoModel: first.photoModel, previousInputData: Data(), replacementInputData: Data(),
            step: .details, in: first.context, directory: f.directory, allowsSynthetic: true)
        XCTAssertEqual(final.garment.id, f.garment.id)
        XCTAssertEqual(final.garment.sourceMeasurementID, finalRecord.id)
        XCTAssertEqual(final.garment.measurementPhoto?.measurementFrameID, finalRecord.snapshot.frame.frameID)
        XCTAssertNotEqual(final.photoModel.measurementRecord?.id, firstRecord.id)
        let visual = try XCTUnwrap(final.photoModel.input.measurementVisualization)
        XCTAssertEqual(final.photoModel.selectedPhotoIDs, [f.detail.id, visual.id, f.model.input.measurement.id])
        XCTAssertEqual(final.photoModel.detailPhotos, [f.detail])
        XCTAssertEqual(try Data(contentsOf: detailURL), detailBytes)
        let reader = ModelContext(f.container)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<Garment>()), 1)
        let saved = try XCTUnwrap(reader.fetch(FetchDescriptor<Garment>()).first)
        XCTAssertEqual(Set(saved.photos.map(\.id)), [f.model.input.measurement.id, visual.id])
        XCTAssertEqual(saved.creationDraft?.photoState?.selectedPhotoIDs, final.photoModel.selectedPhotoIDs)
    }

    private enum TestError: Error { case save }
    private struct NoCapture: CaptureProviding {
        func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset { throw CameraFailure.captureFailed }
    }
    private struct Fixture {
        let directory: URL
        let container: ModelContainer
        let context: ModelContext
        let record: SavedMeasurement
        let garment: Garment
        let model: ProductPhotoModel
        let detail: CapturedAsset

        init() async throws {
            directory = URL.temporaryDirectory.appending(path: "measurement-retake-\(UUID())")
            let schema = ProductAppStorage.schema
            container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
            context = ModelContext(container)
            context.autosaveEnabled = false
            record = try GarmentCapturePreview.measurement(kind: .top).makeRecord()
            garment = try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: directory, allowsSynthetic: true)
            var input = try ProductPhotoHandoff.makeInput(for: garment,
                sessionID: record.snapshot.frame.sessionID, photosDirectory: directory)
            input.measurementVisualization = try await MeasurementProductPhoto.prepare(record: record,
                garment: garment, in: context, directory: directory)
            detail = try await CameraPhotoStore(directory: directory.appending(path: "captures"))
                .save(record.snapshot.imageJPEG, sessionID: input.sessionID, garmentID: garment.id, capturedAt: .now)
            model = try ProductPhotoModel(input: input, captureProvider: NoCapture(), initialDetailPhotos: [detail],
                initialSelectedPhotoIDs: [detail.id, input.measurementVisualization!.id, input.measurement.id],
                measurementRecord: record)
            model.acknowledgeCaptureGuide()
            garment.brand = "retained brand"
        }
        var measurementURLs: [URL] {
            [model.input.measurement, model.input.measurementVisualization!].compactMap {
                if case let .localFile(url, _) = $0.source { return url }; return nil
            }
        }
        func replace(_ record: SavedMeasurement,
                     persist: (ModelContext) throws -> Void = { try $0.save() }) async throws -> ProductMeasurementRetake.Replacement {
            try await ProductMeasurementRetake.replace(record, garment: garment, photoModel: model,
                previousInputData: Data("old input".utf8), replacementInputData: Data("new input".utf8),
                step: .details, in: context, directory: directory, allowsSynthetic: true, persist: persist)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

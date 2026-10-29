// Created by mason on 10/30/26.
import SwiftData
import UIKit
import XCTest
@testable import Dobby

/// Synthetic measurements verify image handoff and storage, not measurement accuracy.
@MainActor
final class MeasurementProductPhotoTests: XCTestCase {
    func testRenderedPhotoCanBeSelectedAsRepresentativeSavedAndExportedIndependently() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let originalURL = f.directory.appending(path: f.garment.measurementPhoto!.fileName)
        let originalBytes = try Data(contentsOf: originalURL)
        let visual = try await f.prepare()
        let repeated = try await f.prepare()
        XCTAssertEqual(visual, repeated)
        XCTAssertEqual(f.garment.photos.count, 2)
        XCTAssertEqual(f.garment.productPhotos.map(\.id), [f.input.measurement.id])
        guard case let .localFile(url, metadata) = visual.source else { return XCTFail("Missing raster") }
        let bytes = try Data(contentsOf: url)
        let rendered = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertEqual(metadata.pixelWidth, 1608)
        XCTAssertEqual(Double(metadata.pixelWidth) / Double(metadata.pixelHeight),
            Double(SnapshotPresentation.resultAspectRatio(for: f.record.snapshot)), accuracy: 0.002)
        XCTAssertNotNil(rendered.cgImage)
        XCTAssertNotEqual(bytes, originalBytes)
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "measurement-values-saved-raster"
        attachment.lifetime = .keepAlways
        add(attachment)

        var input = f.input
        input.measurementVisualization = visual
        let model = try ProductPhotoModel(input: input, captureProvider: NoCapture())
        XCTAssertEqual(model.selectablePhotos.map(\.id), [input.measurement.id, visual.id])
        XCTAssertEqual(model.toggleSelection(visual.id), .updated)
        XCTAssertEqual(model.output?.representativePhotoID, visual.id)
        try await ProductPhotoHandoff.apply(XCTUnwrap(model.output), to: f.garment, in: f.context,
            input: input, photosDirectory: f.directory)
        XCTAssertEqual(f.garment.productPhotos.map(\.id), [visual.id])
        XCTAssertEqual(f.garment.thumbnail?.id, visual.id)
        XCTAssertEqual(f.garment.measurementPhoto?.id, input.measurement.id)
        let exported = ExportProduct(garment: f.garment) { try? Data(contentsOf: f.directory.appending(path: $0.fileName)) }
        XCTAssertEqual(exported.photos, [bytes])
        XCTAssertEqual(exported.thumbnailData, bytes)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)

        model.toggleSelection(visual.id)
        model.toggleSelection(input.measurement.id)
        try await ProductPhotoHandoff.apply(XCTUnwrap(model.output), to: f.garment, in: f.context,
            input: input, photosDirectory: f.directory)
        XCTAssertEqual(f.garment.productPhotos.map(\.id), [input.measurement.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Unselected derived evidence remains a reusable cache")
    }

    func testDraftReopenRestoresDerivedPhotoIdentitySelectionAndOrder() async throws {
        let f = try Fixture()
        defer { f.remove() }
        var input = f.input
        let visual = try await f.prepare()
        input.measurementVisualization = visual
        let model = try ProductPhotoModel(input: input, captureProvider: NoCapture(),
            initialSelectedPhotoIDs: [visual.id, input.measurement.id])
        try ProductDraftStore.save(garment: f.garment, step: .photoSelection,
            measurementRecordID: f.record.id, photoModel: model, measurementInputData: nil, in: f.context)

        let reader = ModelContext(f.container)
        let saved = try XCTUnwrap(reader.fetch(FetchDescriptor<Garment>()).first)
        var restoredInput = try ProductPhotoHandoff.makeInput(for: saved, sessionID: input.sessionID,
            photosDirectory: f.directory)
        restoredInput.measurementVisualization = try await MeasurementProductPhoto.prepare(record: f.record,
            garment: saved, in: reader, directory: f.directory)
        let state = try XCTUnwrap(saved.creationDraft?.photoState)
        let restored = try ProductPhotoModel(input: restoredInput, captureProvider: NoCapture(),
            initialDetailPhotos: state.restoredDetailPhotos(for: restoredInput),
            initialSelectedPhotoIDs: state.selectedPhotoIDs)
        XCTAssertEqual(restoredInput.measurementVisualization, visual)
        XCTAssertEqual(restored.output?.selectedPhotos.map(\.id), [visual.id, input.measurement.id])
        XCTAssertTrue(restored.detailPhotos.isEmpty)
        try await ProductPhotoHandoff.apply(XCTUnwrap(restored.output), to: saved, in: reader,
            input: restoredInput, photosDirectory: f.directory)
        XCTAssertEqual(saved.productPhotos.map(\.id), [visual.id, input.measurement.id])
    }

    func testConfirmedCorrectionReplacesSelectedVisualizationWithoutChangingOriginal() async throws {
        let f = try Fixture()
        defer { f.remove() }
        var input = f.input
        let visual = try await f.prepare()
        input.measurementVisualization = visual
        let model = try ProductPhotoModel(input: input, captureProvider: NoCapture(),
            initialSelectedPhotoIDs: [visual.id, input.measurement.id], measurementRecord: f.record)
        var corrected = f.record
        corrected.id = UUID()
        for index in corrected.result.values.indices where corrected.result.values[index].meters != nil {
            corrected.result.values[index].meters! += 0.07
        }
        let replacement = try await MeasurementProductPhoto.prepare(record: corrected, garment: f.garment,
            in: f.context, directory: f.directory)
        try model.updateMeasurementRecord(corrected, visualization: replacement)
        XCTAssertNotEqual(visual.id, replacement.id)
        XCTAssertEqual(model.selectedPhotoIDs, [replacement.id, input.measurement.id])
        XCTAssertEqual(model.input.measurement, input.measurement)
        guard case let .localFile(oldURL, _) = visual.source,
              case let .localFile(newURL, _) = replacement.source else { return XCTFail("Missing rendered files") }
        XCTAssertNotEqual(try Data(contentsOf: oldURL), try Data(contentsOf: newURL),
            "Changed confirmed values must be visible in the saved pixels")
    }

    func testFailedPreparationRollsBackOnlyNewDerivedPhotoAndCanRetry() async throws {
        let f = try Fixture()
        defer { f.remove() }
        let originalIDs = f.garment.photos.map(\.id)
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted()
        do {
            _ = try await MeasurementProductPhoto.prepare(record: f.record, garment: f.garment,
                in: f.context, directory: f.directory, persist: { _ in throw SaveFailure.failed })
            XCTFail("Expected save failure")
        } catch SaveFailure.failed { }
        XCTAssertEqual(f.garment.photos.map(\.id), originalIDs)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted(), originalFiles)
        let retry = try await f.prepare()
        XCTAssertEqual(f.garment.photos.filter { $0.id == retry.id }.count, 1)
        XCTAssertEqual(f.garment.measurementPhoto?.id, f.input.measurement.id)
    }

    private enum SaveFailure: Error { case failed }
    private final class NoCapture: CaptureProviding {
        func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset { throw CameraFailure.captureFailed }
    }
    private struct Fixture {
        let directory: URL
        let container: ModelContainer
        let context: ModelContext
        let record: SavedMeasurement
        let garment: Garment
        let input: ProductPhotoInput

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "measurement-product-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let schema = ProductAppStorage.schema
            container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
            context = ModelContext(container)
            context.autosaveEnabled = false
            record = try GarmentCapturePreview.measurement(kind: .top).makeRecord()
            garment = try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: directory, allowsSynthetic: true)
            input = try ProductPhotoHandoff.makeInput(for: garment, sessionID: record.snapshot.frame.sessionID,
                photosDirectory: directory)
        }
        func prepare() async throws -> CapturedAsset {
            try await MeasurementProductPhoto.prepare(record: record, garment: garment, in: context, directory: directory)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

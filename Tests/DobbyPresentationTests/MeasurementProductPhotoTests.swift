// Created by mason on 10/30/26.
import ImageIO
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import Dobby

/// Synthetic measurements verify image handoff and storage, not measurement accuracy.
@MainActor
final class MeasurementProductPhotoTests: XCTestCase {
    func testSavedPNGPointsMatchConfirmationHandleSizeAcrossRatiosAndRotation() throws {
        for orientation in [ImageOrientation.up, .right] {
            for aspect in MeasurementPhotoAspectRatio.allCases {
                try autoreleasepool {
                    let record = try isolatedSegmentRecord(aspect: aspect, orientation: orientation)
                    let image = try XCTUnwrap(SnapshotPresentation.image(for: record.snapshot))
                    let savedData = try MeasurementProductPhoto.render(record: record, image: image)
                    let saved = try XCTUnwrap(UIImage(data: savedData)?.cgImage)
                    // The reference retains the real confirmation editor's physical
                    // handles. The saved path deliberately has no editable handles.
                    let confirmation = try editorRaster(record: record, image: image)
                    let ratio = SnapshotPresentation.resultAspectRatio(for: record.snapshot)
                    let size = CGSize(width: 402, height: 402 / ratio)
                    let crop = try XCTUnwrap(record.snapshot.presentationCrop)
                    let context = "\(aspect.rawValue), \(orientation.rawValue)"
                    XCTAssertEqual(saved.width, 1608, context)
                    XCTAssertEqual(saved.width, confirmation.width, context)
                    XCTAssertEqual(saved.height, confirmation.height, context)
                    XCTAssertEqual(Double(saved.width) / Double(saved.height), Double(ratio),
                                   accuracy: 0.002, context)

                    for (index, point) in record.landmarks.points.enumerated() {
                        let center = GarmentPhotoGeometry.screenPoint(point.point, photoSize: size,
                            orientation: orientation, displayCrop: crop)
                        XCTAssertEqual(center.x, size.width * (index == 0 ? 0.25 : 0.75),
                                       accuracy: 0.0001, context)
                        XCTAssertEqual(center.y, size.height / 2, accuracy: 0.0001, context)
                        let pixelCenter = CGPoint(x: center.x * 4, y: center.y * 4)
                        // Scan perpendicular to the line so its white dash cannot
                        // masquerade as the endpoint's diameter. This fails for
                        // the old 6pt/24px export dots, even if constants agree.
                        let savedSpan = try whitePointSpan(in: saved, at: pixelCenter)
                        let referenceSpan = try whitePointSpan(in: confirmation, at: pixelCenter)
                        XCTAssertEqual(referenceSpan.diameter, 40, accuracy: 2, context)
                        XCTAssertEqual(savedSpan.diameter, referenceSpan.diameter, accuracy: 2, context)
                        XCTAssertEqual(savedSpan.centerOffset, 0, accuracy: 1, context)
                        XCTAssertEqual(referenceSpan.centerOffset, 0, accuracy: 1, context)
                    }
                }
            }
        }
    }

    func testUnversionedCurrentRasterIsRebuiltAndThenReused() async throws {
        try await assertCachedRasterIsRebuilt(usesLegacyFileName: false)
    }

    func testLegacyFileNameUpgradesWithoutChangingSelectionOrderRotationOrOriginal() async throws {
        try await assertCachedRasterIsRebuilt(usesLegacyFileName: true)
    }

    func testFailedCurrentRasterRepairRestoresBaseAndRotationCachesAndCanRetry() async throws {
        try await assertCachedRasterIsRebuilt(usesLegacyFileName: false, failsPersistence: true)
    }

    private func assertCachedRasterIsRebuilt(usesLegacyFileName: Bool,
                                             failsPersistence: Bool = false) async throws {
        let f = try Fixture()
        defer { f.remove() }
        let originalURL = f.directory.appending(path: try XCTUnwrap(f.garment.measurementPhoto).fileName)
        let originalBytes = try Data(contentsOf: originalURL)
        let visual = try await f.prepare()
        guard case let .localFile(url, _) = visual.source else { return XCTFail("Missing raster") }
        var input = f.input
        input.measurementVisualization = visual
        let model = try ProductPhotoModel(input: input, captureProvider: NoCapture(),
            initialSelectedPhotoIDs: [visual.id, input.measurement.id], measurementRecord: f.record)
        try await ProductPhotoHandoff.apply(XCTUnwrap(model.output), to: f.garment, in: f.context,
            input: input, photosDirectory: f.directory)
        let photo = try XCTUnwrap(f.garment.photos.first { $0.id == visual.id })
        let currentFileName = photo.fileName
        photo.order = 7
        photo.productRotationQuarterTurns = 1
        if usesLegacyFileName {
            photo.fileName = "\(f.garment.id.uuidString)-\(visual.id.uuidString).png"
        }
        try ProductDraftStore.save(garment: f.garment, step: .photoSelection,
            measurementRecordID: f.record.id, photoModel: model, measurementInputData: nil, in: f.context)
        let fileName = photo.fileName
        let staleURL = f.directory.appending(path: fileName)
        let role = photo.role
        let selected = photo.isSelectedForProduct
        let draft = f.garment.creationDraftData
        let ids = Set(f.garment.photos.map(\.id))

        // The original saved path retained only the 6pt Canvas endpoints and
        // wrote no render version. Build those actual old-style pixels.
        var legacyLandmarks = f.record.landmarks
        legacyLandmarks.points = []
        let image = try XCTUnwrap(SnapshotPresentation.image(for: f.record.snapshot))
        let legacy = try pngWithoutMetadata(editorRaster(record: f.record, image: image,
            editableLandmarks: legacyLandmarks))
        try legacy.write(to: staleURL, options: .atomic)
        if usesLegacyFileName { try FileManager.default.removeItem(at: url) }
        XCTAssertNil(MeasurementProductPhoto.renderingVersion(of: staleURL))
        let staleRotationURLs = [1, 2].map {
            staleURL.deletingPathExtension().appendingPathExtension("product-rotation-\($0).jpg")
        }
        for (index, rotationURL) in staleRotationURLs.enumerated() {
            try GarmentStore.writeProductRotation(original: staleURL, destination: rotationURL,
                quarterTurns: index + 1)
        }
        let staleRotations = try staleRotationURLs.map { try Data(contentsOf: $0) }
        if failsPersistence {
            let previousFiles = try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted()
            let previousWidth = photo.imageWidth
            let previousHeight = photo.imageHeight
            do {
                _ = try await MeasurementProductPhoto.prepare(record: f.record, garment: f.garment,
                    in: f.context, directory: f.directory, persist: { _ in throw SaveFailure.failed })
                XCTFail("Expected repaired-raster persistence failure")
            } catch SaveFailure.failed { }
            XCTAssertEqual(try Data(contentsOf: staleURL), legacy)
            XCTAssertNil(MeasurementProductPhoto.renderingVersion(of: staleURL))
            for (index, rotationURL) in staleRotationURLs.enumerated() {
                XCTAssertEqual(try Data(contentsOf: rotationURL), staleRotations[index],
                               "Failure must restore both active and inactive cached rotations")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).sorted(), previousFiles)
            XCTAssertEqual(photo.fileName, fileName)
            XCTAssertEqual(photo.imageWidth, previousWidth)
            XCTAssertEqual(photo.imageHeight, previousHeight)
            XCTAssertEqual(photo.role, role)
            XCTAssertEqual(photo.order, 7)
            XCTAssertEqual(photo.isSelectedForProduct, selected)
            XCTAssertEqual(photo.productRotationQuarterTurns, 1)
            XCTAssertEqual(f.garment.creationDraftData, draft)
            XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        }
        let rebuilt = try await f.prepare()
        let rebuiltBytes = try Data(contentsOf: url)
        XCTAssertEqual(rebuilt.id, visual.id)
        XCTAssertEqual(MeasurementProductPhoto.renderingVersion(of: url), 2)
        XCTAssertNotEqual(rebuiltBytes, legacy)
        XCTAssertEqual(Set(f.garment.photos.map(\.id)), ids)
        XCTAssertEqual(photo.fileName, currentFileName)
        XCTAssertEqual(photo.role, role)
        XCTAssertEqual(photo.order, 7)
        XCTAssertEqual(photo.isSelectedForProduct, selected)
        XCTAssertEqual(photo.productRotationQuarterTurns, 1)
        XCTAssertEqual(f.garment.creationDraftData, draft)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        guard case let .localFile(rebuiltURL, _) = rebuilt.source else { return XCTFail("Missing rebuilt raster") }
        XCTAssertEqual(rebuiltURL, url)
        XCTAssertTrue(rebuiltURL.lastPathComponent.hasSuffix("-r2.png"))
        let base = try XCTUnwrap(UIImage(data: rebuiltBytes)?.cgImage)
        let rotationURL = rebuiltURL.deletingPathExtension().appendingPathExtension("product-rotation-1.jpg")
        let rotatedBytes = try Data(contentsOf: rotationURL)
        let rotated = try XCTUnwrap(UIImage(data: rotatedBytes)?.cgImage)
        XCTAssertEqual(rotated.width, base.height)
        XCTAssertEqual(rotated.height, base.width)
        XCTAssertNotEqual(rotatedBytes, staleRotations[0],
                          "The active rotation must contain the rebuilt endpoint pixels")
        let inactiveURL = rebuiltURL.deletingPathExtension().appendingPathExtension("product-rotation-2.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactiveURL.path),
                       "An inactive old-style rotation must not survive for a later rotation action")
        if usesLegacyFileName {
            XCTAssertNotEqual(photo.fileName, fileName)
            XCTAssertEqual(try Data(contentsOf: staleURL), legacy,
                           "Upgrading the row must preserve immutable legacy file bytes")
            for (index, rotationURL) in staleRotationURLs.enumerated() {
                XCTAssertEqual(try Data(contentsOf: rotationURL), staleRotations[index])
            }
        }

        var restoredInput = f.input
        restoredInput.measurementVisualization = rebuilt
        let snapshot = try XCTUnwrap(f.garment.creationDraft?.photoState)
        let restored = try ProductPhotoModel(input: restoredInput, captureProvider: NoCapture(),
            initialDetailPhotos: snapshot.restoredDetailPhotos(for: restoredInput),
            initialSelectedPhotoIDs: snapshot.selectedPhotoIDs)
        XCTAssertEqual(restored.selectedPhotoIDs, [visual.id, input.measurement.id])
        XCTAssertEqual(restored.output?.representativePhotoID, visual.id)

        // A fixed old timestamp detects an unnecessary rewrite even if another
        // rendering happens to produce exactly the same PNG bytes.
        let cacheDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: cacheDate], ofItemAtPath: url.path)
        let repeated = try await f.prepare()
        XCTAssertEqual(repeated, rebuilt)
        XCTAssertEqual(try Data(contentsOf: url), rebuiltBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(try XCTUnwrap(attributes[.modificationDate] as? Date), cacheDate)
    }

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
        let camera = CameraPhotoStore(directory: f.directory.appending(path: "captures"))
        let first = try await camera.save(f.record.snapshot.imageJPEG,
            sessionID: input.sessionID, garmentID: input.garmentID, capturedAt: .now)
        let second = try await camera.save(f.record.snapshot.imageJPEG,
            sessionID: input.sessionID, garmentID: input.garmentID, capturedAt: .now)
        let selected = [second.id, visual.id, input.measurement.id, first.id]
        let model = try ProductPhotoModel(input: input, captureProvider: NoCapture(),
            initialDetailPhotos: [first, second], initialSelectedPhotoIDs: selected)
        XCTAssertEqual(model.selectablePhotos.map(\.id), [input.measurement.id, visual.id, first.id, second.id])
        XCTAssertEqual(model.photos.map(\.id), [input.measurement.id, first.id, second.id])
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
        XCTAssertEqual(restored.selectablePhotos.map(\.id), [input.measurement.id, visual.id, first.id, second.id])
        XCTAssertEqual(restored.output?.selectedPhotos.map(\.id), selected)
        XCTAssertEqual(restored.output?.representativePhotoID, second.id)
        XCTAssertEqual(restored.detailPhotos, [first, second])
        try await ProductPhotoHandoff.apply(XCTUnwrap(restored.output), to: saved, in: reader,
            input: restoredInput, photosDirectory: f.directory)
        XCTAssertEqual(saved.productPhotos.map(\.id), selected)
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

    private func isolatedSegmentRecord(aspect: MeasurementPhotoAspectRatio,
                                       orientation: ImageOrientation) throws -> SavedMeasurement {
        var record = try GarmentCapturePreview.measurement(kind: .top).makeRecord()
        let imageSize = PixelSize(width: 1920, height: 1440)
        record.snapshot.frame.imageSize = imageSize
        record.snapshot.frame.orientation = orientation
        let crop = try XCTUnwrap(aspect.displayCrop(imageSize: imageSize, orientation: orientation))
        record.snapshot.presentationCrop = crop
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let background = UIGraphicsImageRenderer(size: CGSize(width: imageSize.width, height: imageSize.height),
            format: format).image { context in
                UIColor(white: 0.15, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height))
            }
        record.snapshot.imageJPEG = try XCTUnwrap(background.jpegData(compressionQuality: 1))
        record.landmarks.points = [0.25, 0.75].enumerated().map { index, x in
            let display = ImagePoint(x: crop.x + x * crop.width, y: crop.y + 0.5 * crop.height)
            return GarmentLandmark(id: index == 0 ? "A" : "B",
                point: ImageCoordinateTransform.displayToOriginal(display, orientation: orientation), confidence: 1)
        }
        record.definitions = [.testDistance]
        let quality = PointQuality(validSamples: 12, candidateSamples: 12, confidenceAvailable: true,
            depthSpreadMeters: 0, planeResidualMeters: nil, method: .robustMedian)
        record.result.values = [.init(id: "test", title: "두 점 사이", meters: 0.5,
            status: .valid, failure: nil, points: record.landmarks.points.map {
                ResolvedLandmark(id: $0.id, imagePoint: $0.point,
                    position: .init(x: $0.point.x, y: $0.point.y, z: 1), quality: quality)
            })]
        return record
    }

    private func editorRaster(record: SavedMeasurement, image: UIImage,
                              editableLandmarks: GarmentLandmarkSet? = nil) throws -> CGImage {
        let measurement = AutomaticMeasurement(record: record)
        let ratio = SnapshotPresentation.resultAspectRatio(for: record.snapshot)
        let content = GarmentMeasurementPhotoEditor(image: image, snapshot: record.snapshot,
            editableLandmarks: editableLandmarks ?? record.landmarks, definitions: measurement.visibleDefinitions,
            values: measurement.visibleValues, showLabels: true, isEnabled: true,
            isRecalculating: false, showsEnlargeControl: false,
            onEnlarge: {}, onMove: { _, _ in }, onEditingChanged: { _ in })
            .frame(width: 402, height: 402 / ratio)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 4
        return try XCTUnwrap(renderer.uiImage?.cgImage)
    }

    private func pngWithoutMetadata(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func whitePointSpan(in image: CGImage, at center: CGPoint) throws
        -> (diameter: Double, centerOffset: Double) {
        let top = floor(center.y) - 40
        let strip = try XCTUnwrap(image.cropping(to: CGRect(x: floor(center.x), y: top, width: 1, height: 80)))
        var rgba = [UInt8](repeating: 0, count: strip.height * 4)
        let drew = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: strip.height,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: strip.height))
            return true
        }
        XCTAssertTrue(drew)
        let white = (0..<strip.height).filter { row in
            (0..<4).allSatisfy { rgba[row * 4 + $0] >= 240 }
        }
        let first = try XCTUnwrap(white.first, "No white endpoint at expected center \(center)")
        let last = try XCTUnwrap(white.last)
        XCTAssertEqual(white.count, last - first + 1, "The point's white core must be contiguous")
        return (Double(last - first + 1), Double(first + last + 1) / 2 - Double(center.y - top))
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

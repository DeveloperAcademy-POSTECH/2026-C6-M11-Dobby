import Foundation
import SwiftData
import XCTest
@testable import Dobby

@MainActor
final class SavedProductPhotoDeletionTests: XCTestCase {
    func testRemovingRepresentativePromotesNextSelectedPhotoWithoutReordering() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = insertGarment(in: context, photoCount: 4)
        let photos = garment.orderedPhotos
        photos[3].isSelectedForProduct = false
        let originalOrder = photos.map(\.order)
        try context.save()

        XCTAssertTrue(try GarmentStore.removeProductPhoto(id: photos[0].id, from: garment, in: context))

        XCTAssertEqual(garment.productPhotos.map(\.id), [photos[1].id, photos[2].id])
        XCTAssertEqual(garment.thumbnail?.id, photos[1].id)
        XCTAssertEqual(photos[0].isSelectedForProduct, false)
        XCTAssertEqual(photos[0].role, .detail)
        XCTAssertEqual(photos[1].role, .thumbnail)
        XCTAssertEqual(photos[3].isSelectedForProduct, false)
        XCTAssertEqual(garment.orderedPhotos.map(\.order), originalOrder)
        XCTAssertEqual(garment.photos.count, 4)
    }

    func testRemovingLastPhotoPreservesMeasurementEvidenceAndOriginalFile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = insertGarment(in: context, photoCount: 1)
        let measured = try XCTUnwrap(garment.measurementPhoto)
        let recordID = UUID()
        measured.measurementRecordID = recordID
        measured.measurementSessionID = UUID()
        measured.imageWidth = 1200
        measured.imageHeight = 1600
        measured.pixelsPerCm = 12.5
        let point = LandmarkPoint(name: "armpit_left", index: 0, x: 0.2, y: 0.3)
        context.insert(point)
        measured.landmarks.append(point)
        point.photo = measured
        let original = Data("Original measurement evidence \(UUID().uuidString)".utf8)
        let originalURL = GarmentStore.url(for: measured)
        try original.write(to: originalURL)
        defer { try? FileManager.default.removeItem(at: originalURL) }
        let sessionID = measured.measurementSessionID
        try context.save()

        XCTAssertTrue(try GarmentStore.removeProductPhoto(id: measured.id, from: garment, in: context))

        XCTAssertTrue(garment.productPhotos.isEmpty)
        XCTAssertNil(garment.thumbnail)
        XCTAssertEqual(garment.photos.count, 1)
        XCTAssertTrue(garment.measurementPhoto === measured)
        XCTAssertEqual(measured.isSelectedForProduct, false)
        XCTAssertEqual(measured.measurementRecordID, recordID)
        XCTAssertEqual(measured.measurementSessionID, sessionID)
        XCTAssertEqual(measured.imageWidth, 1200)
        XCTAssertEqual(measured.imageHeight, 1600)
        XCTAssertEqual(measured.pixelsPerCm, 12.5)
        XCTAssertEqual(measured.landmarks.map(\.id), [point.id])
        XCTAssertEqual(point.x, 0.2)
        XCTAssertEqual(point.y, 0.3)
        XCTAssertEqual(garment.measurements.first?.valueCm, 55.4)
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
    }

    func testForeignMissingAndRepeatedRequestsAreNoOps() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = insertGarment(in: context)
        let other = insertGarment(in: context)
        let target = try XCTUnwrap(garment.productPhotos.first)
        let foreign = try XCTUnwrap(other.productPhotos.first)
        let foreignUpdatedAt = other.updatedAt
        try context.save()
        var saveCount = 0
        let persist: @MainActor (ModelContext) throws -> Void = { context in
            saveCount += 1
            try context.save()
        }

        XCTAssertFalse(try GarmentStore.removeProductPhoto(id: foreign.id, from: garment,
            in: context, persist: persist))
        XCTAssertFalse(try GarmentStore.removeProductPhoto(id: UUID(), from: garment,
            in: context, persist: persist))
        XCTAssertEqual(saveCount, 0)
        XCTAssertTrue(try GarmentStore.removeProductPhoto(id: target.id, from: garment,
            in: context, persist: persist))
        let updatedAt = garment.updatedAt
        XCTAssertFalse(try GarmentStore.removeProductPhoto(id: target.id, from: garment,
            in: context, persist: persist))

        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(garment.updatedAt, updatedAt)
        XCTAssertNil(foreign.isSelectedForProduct)
        XCTAssertEqual(other.updatedAt, foreignUpdatedAt)
        XCTAssertEqual(other.productPhotos.count, 3)
    }

    func testFailedSaveRestoresPhotoStateAndPreservesPendingFormEdits() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = insertGarment(in: context)
        let other = insertGarment(in: context)
        let photos = garment.orderedPhotos
        photos[0].role = .detail
        photos[1].role = .thumbnail
        photos[2].isSelectedForProduct = false
        garment.updatedAt = Date(timeIntervalSince1970: 1000)
        let originalID = garment.id
        try context.save()
        let originalRoles = photos.map(\.roleRaw)
        let originalFlags = photos.map(\.isSelectedForProduct)
        let originalOrder = photos.map(\.order)
        let originalUpdatedAt = garment.updatedAt
        let originalURL = GarmentStore.url(for: photos[1])
        let originalBytes = Data("An original must survive a failed deletion save".utf8)
        try originalBytes.write(to: originalURL)
        defer { try? FileManager.default.removeItem(at: originalURL) }
        garment.name = "수정 중인 제품명"
        garment.detail = "수정 중인 설명"
        garment.price = 45_000
        other.name = "다른 화면의 미저장 제품명"
        let pending = Garment(category: "Shirt", group: .top, name: "미저장 초안")
        context.insert(pending)
        enum SaveFailure: Error { case unavailable }

        XCTAssertThrowsError(try GarmentStore.removeProductPhoto(id: photos[1].id, from: garment,
            in: context, persist: { _ in throw SaveFailure.unavailable })) { error in
            XCTAssertTrue(error is SaveFailure)
        }

        XCTAssertEqual(photos.map(\.roleRaw), originalRoles)
        XCTAssertEqual(photos.map(\.isSelectedForProduct), originalFlags)
        XCTAssertEqual(photos.map(\.order), originalOrder)
        XCTAssertEqual(garment.updatedAt, originalUpdatedAt)
        XCTAssertEqual(garment.name, "수정 중인 제품명")
        XCTAssertEqual(garment.detail, "수정 중인 설명")
        XCTAssertEqual(garment.price, 45_000)
        XCTAssertEqual(other.name, "다른 화면의 미저장 제품명")
        XCTAssertEqual(pending.name, "미저장 초안")
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertTrue(context.hasChanges)
        let durable = ModelContext(container)
        let saved = try durable.fetch(FetchDescriptor<Garment>())
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.first { $0.id == originalID }?.name, "저장된 제품명")
        XCTAssertFalse(saved.contains { $0.id == pending.id })
    }

    func testExclusionAndReplacementRepresentativeSurviveDiskReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dobby-saved-photo-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("products.store")
        var garmentID = UUID()
        var photoIDs: [UUID] = []

        try autoreleasepool {
            let container = try makeContainer(at: storeURL)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let garment = insertGarment(in: context)
            garmentID = garment.id
            photoIDs = garment.orderedPhotos.map(\.id)
            try context.save()
            XCTAssertTrue(try GarmentStore.removeProductPhoto(id: photoIDs[0], from: garment, in: context))
            XCTAssertTrue(try GarmentStore.removeProductPhoto(id: photoIDs[2], from: garment, in: context))
        }

        try autoreleasepool {
            let container = try makeContainer(at: storeURL)
            let context = ModelContext(container)
            let garment = try XCTUnwrap(context.fetch(FetchDescriptor<Garment>()).first { $0.id == garmentID })
            XCTAssertEqual(garment.photos.count, 3)
            XCTAssertEqual(garment.productPhotos.map(\.id), [photoIDs[1]])
            XCTAssertEqual(garment.thumbnail?.id, photoIDs[1])
            XCTAssertEqual(garment.measurementPhoto?.id, photoIDs[0])
            XCTAssertEqual(garment.measurementPhoto?.isSelectedForProduct, false)
            XCTAssertEqual(garment.measurements.first?.valueCm, 55.4)
        }
    }

    func testUnselectedLegacyThumbnailIsNeverUsedForProductDisplay() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let garment = insertGarment(in: context, photoCount: 2)
        let photos = garment.orderedPhotos
        photos[0].isSelectedForProduct = false
        XCTAssertEqual(photos[0].role, .thumbnail)
        XCTAssertEqual(garment.thumbnail?.id, photos[1].id)

        photos[1].isSelectedForProduct = false
        XCTAssertNil(garment.thumbnail)
        XCTAssertEqual(garment.measurementPhoto?.id, photos[0].id)
    }

    private func makeContainer(at url: URL? = nil) throws -> ModelContainer {
        let schema = ProductAppStorage.schema
        let configuration = url.map {
            ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none)
        } ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func insertGarment(in context: ModelContext, photoCount: Int = 3) -> Garment {
        let garment = Garment(category: "Jacket", group: .top, name: "저장된 제품명",
            detail: "저장된 설명", price: 30_000)
        context.insert(garment)
        for index in 0..<photoCount {
            let photo = GarmentPhoto(fileName: "saved-photo-test-\(UUID().uuidString).jpg",
                role: index == 0 ? .thumbnail : .detail, order: index, isMeasurementSource: index == 0)
            context.insert(photo)
            garment.photos.append(photo)
            photo.garment = garment
        }
        let measurement = MeasuredValue(key: "chestWidth", label: "가슴", displayOrder: 0,
            valueCm: 55.4, autoValueCm: 55.4)
        context.insert(measurement)
        garment.measurements.append(measurement)
        measurement.garment = garment
        return garment
    }
}

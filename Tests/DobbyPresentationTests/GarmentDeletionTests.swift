import Foundation
import SwiftData
import XCTest
@testable import Dobby

/// Uses private stores and uniquely named test-owned photo files.
@MainActor
final class GarmentDeletionTests: XCTestCase {
    func testSavedDeletionPersistsCascadesAndRemovesEveryTargetPhotoOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dobby-garment-deletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("products.store")
        let targetID = UUID()
        let retainedID = UUID()
        let prefix = "deletion-test-\(UUID().uuidString)"
        let fileNames = ["\(prefix)-measurement.jpg", "\(prefix)-detail.jpg", "\(prefix)-retained.jpg"]
        let fileURLs = fileNames.map { GarmentStore.photosDirectory.appendingPathComponent($0) }
        let retainedBytes = Data("Retained product's original photo".utf8)
        defer { for url in fileURLs { try? FileManager.default.removeItem(at: url) } }
        for (index, url) in fileURLs.enumerated() {
            try (index == 2 ? retainedBytes : Data("Target photo \(index)".utf8)).write(to: url)
        }

        try autoreleasepool {
            let container = try makeDiskContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let target = insertGraph(id: targetID, name: "삭제할 제품",
                photoFileNames: Array(fileNames.prefix(2)), in: context)
            target.photos.first { $0.order == 0 }?.isSelectedForProduct = false
            insertGraph(id: retainedID, name: "유지할 제품", photoFileNames: [fileNames[2]], in: context)
            try context.save()
            XCTAssertEqual(target.photos.count, 2)
            XCTAssertEqual(target.productPhotos.count, 1, "Deselected originals still need file cleanup")
        }

        try autoreleasepool {
            let container = try makeDiskContainer(at: store)
            XCTAssertTrue(try GarmentStore.deleteSavedGarment(id: targetID, in: container))
            XCTAssertFalse(try GarmentStore.deleteSavedGarment(id: targetID, in: container))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURLs[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURLs[1].path))
        XCTAssertEqual(try Data(contentsOf: fileURLs[2]), retainedBytes)

        try autoreleasepool {
            let container = try makeDiskContainer(at: store)
            let context = ModelContext(container)
            let garments = try context.fetch(FetchDescriptor<Garment>())
            let retained = try XCTUnwrap(garments.first)
            XCTAssertEqual(garments.count, 1)
            XCTAssertEqual(retained.id, retainedID)
            XCTAssertEqual(retained.name, "유지할 제품")
            XCTAssertEqual(retained.photos.map(\.fileName), [fileNames[2]])
            XCTAssertEqual(retained.selectedExportChannels, [.instagram])
            XCTAssertEqual(retained.measurements.first?.valueCm, 55)
            XCTAssertEqual(retained.photos.first?.landmarks.count, 1)
            XCTAssertEqual(retained.exports.first?.succeeded, true)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<GarmentPhoto>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<LandmarkPoint>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MeasuredValue>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExportRecord>()), 1)
        }
    }

    func testDeletionDoesNotSaveOrRollBackUnrelatedPendingMainContextEdits() throws {
        let container = try makeMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let target = Garment(category: "Jacket", group: .top, name: "삭제할 제품")
        let targetID = target.id
        let retained = Garment(category: "Shirt", group: .top, name: "저장된 제품명")
        context.insert(target)
        context.insert(retained)
        try context.save()

        retained.name = "아직 저장하지 않은 제품명"
        let draft = Garment(category: "Sweater", group: .top, name: "미저장 초안")
        context.insert(draft)
        XCTAssertTrue(context.hasChanges)

        XCTAssertTrue(try GarmentStore.deleteSavedGarment(id: targetID, in: container))

        XCTAssertEqual(retained.name, "아직 저장하지 않은 제품명")
        XCTAssertEqual(draft.name, "미저장 초안")
        XCTAssertTrue(context.hasChanges, "Deletion must not consume another screen's pending edits")
        let durableContext = ModelContext(container)
        let stored = try durableContext.fetch(FetchDescriptor<Garment>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, retained.id)
        XCTAssertEqual(stored.first?.name, "저장된 제품명")
        XCTAssertFalse(stored.contains { $0.id == draft.id })
        XCTAssertFalse(stored.contains { $0.id == targetID })
    }

    func testMissingProductIsANoOp() throws {
        let container = try makeMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top, name: "유지할 제품")
        context.insert(garment)
        try context.save()

        XCTAssertFalse(try GarmentStore.deleteSavedGarment(id: UUID(), in: container))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Garment>()), 1)
        XCTAssertEqual(garment.name, "유지할 제품")
        XCTAssertFalse(context.hasChanges)
    }

    @discardableResult
    private func insertGraph(id: UUID, name: String, photoFileNames: [String],
                             in context: ModelContext) -> Garment {
        let garment = Garment(category: "Jacket", group: .top, name: name)
        garment.id = id
        garment.selectedExportChannelRawValues = [ExportChannel.instagram.rawValue]
        context.insert(garment)
        for (index, fileName) in photoFileNames.enumerated() {
            let photo = GarmentPhoto(fileName: fileName,
                role: index == 0 ? .thumbnail : .detail, order: index,
                isMeasurementSource: index == 0)
            context.insert(photo)
            garment.photos.append(photo)
            photo.garment = garment
            let point = LandmarkPoint(name: "armpit_left", index: 0, x: 0.2, y: 0.3)
            context.insert(point)
            photo.landmarks.append(point)
            point.photo = photo
        }
        let measurement = MeasuredValue(key: "chestWidth", label: "가슴", displayOrder: 0,
            valueCm: 55, autoValueCm: 55)
        context.insert(measurement)
        garment.measurements.append(measurement)
        measurement.garment = garment
        let export = ExportRecord(channel: .instagram, succeeded: true)
        context.insert(export)
        garment.exports.append(export)
        export.garment = garment
        return garment
    }

    private func makeMemoryContainer() throws -> ModelContainer {
        let schema = ProductAppStorage.schema
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    private func makeDiskContainer(at url: URL) throws -> ModelContainer {
        let schema = ProductAppStorage.schema
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        ])
    }
}

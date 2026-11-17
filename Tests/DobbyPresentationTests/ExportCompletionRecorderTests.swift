import Foundation
import SwiftData
import XCTest
@testable import Dobby

@MainActor
final class ExportCompletionRecorderTests: XCTestCase {
    func testOnlySuccessfulUploadsProduceOneBadgePerChannelInStableOrder() {
        let garment = Garment(category: "Jacket", group: .top)
        garment.selectedExportChannelRawValues = ExportChannel.availableCases.map(\.rawValue)
        garment.exports = [ExportRecord(channel: .instagram, succeeded: false)]
        XCTAssertTrue(garment.completedExportChannels.isEmpty)
        XCTAssertTrue(ExportProduct(garment: garment, loadPhoto: { _ in nil }).completedChannels.isEmpty)

        let unknown = ExportRecord(channel: .cafe24, succeeded: true)
        unknown.channelRaw = "future-platform"
        garment.exports += [
            ExportRecord(channel: .cafe24, succeeded: true),
            ExportRecord(channel: .instagram, succeeded: true),
            ExportRecord(channel: .cafe24, succeeded: true),
            ExportRecord(channel: .fruitsFamily, succeeded: false),
            unknown
        ]
        XCTAssertEqual(garment.completedExportChannels, [.instagram, .cafe24])
        XCTAssertEqual(ExportProduct(garment: garment, loadPhoto: { _ in nil }).completedChannels,
                       [.instagram, .cafe24])
    }

    func testSuccessIsProductSpecificAndPersistsAcrossDiskStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dobby-export-completion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("products.store")
        let completedID = UUID()
        let selectedID = UUID()

        try autoreleasepool {
            let container = try makeContainer(url: url)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let completed = Garment(category: "Jacket", group: .top)
            completed.id = completedID
            let selected = Garment(category: "Sweater", group: .top)
            selected.id = selectedID
            context.insert(completed)
            context.insert(selected)
            try context.save()
            try GarmentStore.recordSelectedExportChannel(.cafe24, productID: selectedID.uuidString, in: context)
            try ExportCompletionRecorder.record(productID: completedID.uuidString, channel: .cafe24, in: context)
            try ExportCompletionRecorder.record(productID: completedID.uuidString, channel: .cafe24, in: context)
            XCTAssertEqual(completed.completedExportChannels, [.cafe24])
            XCTAssertTrue(selected.completedExportChannels.isEmpty)
        }

        try autoreleasepool {
            let container = try makeContainer(url: url)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let garments = try context.fetch(FetchDescriptor<Garment>())
            let completed = try XCTUnwrap(garments.first { $0.id == completedID })
            let selected = try XCTUnwrap(garments.first { $0.id == selectedID })
            XCTAssertEqual(completed.completedExportChannels, [.cafe24])
            XCTAssertEqual(completed.exports.count, 2, "Each successful upload keeps its history")
            XCTAssertTrue(completed.exports.allSatisfy { $0.garment?.id == completedID && $0.succeeded })
            XCTAssertTrue(selected.completedExportChannels.isEmpty)
            XCTAssertEqual(selected.selectedExportChannels, [.cafe24])
        }
    }

    func testFailedHistorySaveRevertsOnlyNewRecordAndCanBeRetried() throws {
        enum SaveFailure: Error { case unavailable }
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top)
        context.insert(garment)
        try context.save()
        try ExportCompletionRecorder.record(productID: garment.id.uuidString, channel: .instagram, in: context)
        garment.detail = "Keep pending product edits"

        XCTAssertThrowsError(try ExportCompletionRecorder.record(
            productID: garment.id.uuidString, channel: .cafe24, in: context,
            save: { _ in throw SaveFailure.unavailable }
        ))
        XCTAssertEqual(garment.completedExportChannels, [.instagram])
        XCTAssertEqual(garment.exports.count, 1)
        XCTAssertEqual(garment.detail, "Keep pending product edits")
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExportRecord>()), 1)

        try ExportCompletionRecorder.record(productID: garment.id.uuidString, channel: .cafe24, in: context)
        XCTAssertEqual(garment.completedExportChannels, [.instagram, .cafe24])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExportRecord>()), 2)
    }

    func testInvalidOrDeletedProductNeverCreatesACompletionRecord() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top)
        let deletedID = garment.id.uuidString
        context.insert(garment)
        try context.save()
        context.delete(garment)
        try context.save()

        for id in [ExportProduct.demo.id, "", "not-a-uuid", UUID().uuidString, deletedID] {
            try ExportCompletionRecorder.record(productID: id, channel: .cafe24, in: context)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Garment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExportRecord>()), 0)
    }

    private func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let schema = ProductAppStorage.schema
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

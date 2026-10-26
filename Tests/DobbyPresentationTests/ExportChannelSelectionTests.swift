import Foundation
import SwiftData
import XCTest
@testable import Dobby

/// Records platform-button selections in test-owned stores. No external app,
/// network request, or successful upload is required to create a badge.
@MainActor
final class ExportChannelSelectionTests: XCTestCase {
    func testSelectionIsIsolatedToTheProductWhoseButtonWasPressed() throws {
        let container = try makeMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let first = Garment(category: "Jacket", group: .top, name: "첫 번째 제품")
        let second = Garment(category: "Sweater", group: .top, name: "두 번째 제품")
        context.insert(first)
        context.insert(second)
        try context.save()

        try GarmentStore.recordSelectedExportChannel(.instagram, productID: first.id.uuidString, in: context)
        try GarmentStore.recordSelectedExportChannel(.cafe24, productID: second.id.uuidString, in: context)

        XCTAssertEqual(first.selectedExportChannels, [.instagram])
        XCTAssertEqual(second.selectedExportChannels, [.cafe24])
        XCTAssertTrue(first.exports.isEmpty)
        XCTAssertTrue(second.exports.isEmpty)
        XCTAssertFalse(first.hasExported(to: .instagram), "Selecting a platform does not claim a successful upload")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExportRecord>()), 0)
    }

    func testAllFourChannelsHaveOneBadgeInStableOrderAfterRepeatedSelections() throws {
        let container = try makeMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top)
        context.insert(garment)
        try context.save()

        for channel in ExportChannel.allCases.reversed() {
            try GarmentStore.recordSelectedExportChannel(channel, productID: garment.id.uuidString, in: context)
            try GarmentStore.recordSelectedExportChannel(channel, productID: garment.id.uuidString, in: context)
        }

        XCTAssertEqual(garment.selectedExportChannels, ExportChannel.allCases)
        let values = try XCTUnwrap(garment.selectedExportChannelRawValues)
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(Set(values), Set(ExportChannel.allCases.map(\.rawValue)))
    }

    func testUnknownStoredValuesAndDuplicateEntriesDoNotCreateExtraBadges() {
        let garment = Garment(category: "Jacket", group: .top)
        garment.selectedExportChannelRawValues = ["future-platform", "naverStore", "naverStore", "INSTAGRAM"]
        let unknownLegacyRecord = ExportRecord(channel: .fruitsFamily, succeeded: true)
        unknownLegacyRecord.channelRaw = "removed-platform"
        garment.exports = [unknownLegacyRecord]

        XCTAssertEqual(garment.selectedExportChannels, [.naverStore])
    }

    func testSelectionsSurviveFullDiskStoreReopenWithAutosaveDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dobby-export-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("products.store")
        let selectedID = UUID()
        let untouchedID = UUID()

        try autoreleasepool {
            let container = try makeDiskContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let selected = Garment(category: "Jacket", group: .top)
            selected.id = selectedID
            let untouched = Garment(category: "Sweater", group: .top)
            untouched.id = untouchedID
            context.insert(selected)
            context.insert(untouched)
            try context.save()

            for channel in ExportChannel.allCases.reversed() {
                try GarmentStore.recordSelectedExportChannel(channel, productID: selectedID.uuidString, in: context)
            }
            try GarmentStore.recordSelectedExportChannel(.instagram, productID: selectedID.uuidString, in: context)
            // No caller save: the selection API must persist even though this
            // creation-style context has autosave disabled.
        }

        try autoreleasepool {
            let container = try makeDiskContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let garments = try context.fetch(FetchDescriptor<Garment>())
            let selected = try XCTUnwrap(garments.first { $0.id == selectedID })
            let untouched = try XCTUnwrap(garments.first { $0.id == untouchedID })

            XCTAssertEqual(garments.count, 2)
            XCTAssertEqual(selected.selectedExportChannels, ExportChannel.allCases)
            XCTAssertEqual(selected.selectedExportChannelRawValues?.count, 4)
            XCTAssertTrue(selected.exports.isEmpty)
            XCTAssertNil(untouched.selectedExportChannelRawValues)
            XCTAssertTrue(untouched.selectedExportChannels.isEmpty)
        }
    }

    func testDemoInvalidAndMissingProductIdentifiersDoNotCreateOrModifyProducts() throws {
        let container = try makeMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top)
        context.insert(garment)
        try context.save()

        for identifier in [ExportProduct.demo.id, "", "not-a-uuid", UUID().uuidString] {
            try GarmentStore.recordSelectedExportChannel(.instagram, productID: identifier, in: context)
        }

        XCTAssertNil(garment.selectedExportChannelRawValues)
        XCTAssertTrue(garment.selectedExportChannels.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Garment>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExportRecord>()), 0)
    }

    func testDeletedProductIsNotRecreatedByALateSelection() throws {
        let container = try makeMemoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top)
        let identifier = garment.id.uuidString
        context.insert(garment)
        try context.save()
        context.delete(garment)
        try context.save()

        try GarmentStore.recordSelectedExportChannel(.fruitsFamily, productID: identifier, in: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Garment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExportRecord>()), 0)
    }

    func testLegacySuccessfulExportsRemainVisibleButFailuresDoNotBecomeSelections() {
        let garment = Garment(category: "Jacket", group: .top)
        garment.exports = [
            ExportRecord(channel: .cafe24, succeeded: true),
            ExportRecord(channel: .instagram, succeeded: true),
            ExportRecord(channel: .instagram, succeeded: true),
            ExportRecord(channel: .naverStore, succeeded: false),
            ExportRecord(channel: .fruitsFamily, succeeded: false)
        ]

        XCTAssertNil(garment.selectedExportChannelRawValues)
        XCTAssertEqual(garment.selectedExportChannels, [.instagram, .cafe24])

        garment.selectedExportChannelRawValues = ["naverStore", "instagram"]
        XCTAssertEqual(garment.selectedExportChannels, [.instagram, .naverStore, .cafe24])
        XCTAssertFalse(garment.hasExported(to: .naverStore), "A separate click badge does not turn a failed upload into success")
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

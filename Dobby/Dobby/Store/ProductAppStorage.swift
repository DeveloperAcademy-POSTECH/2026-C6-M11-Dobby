import Foundation
import SwiftData

/// One persistent product store shared by creation, library and export.
enum ProductAppStorage {
    static var schema: Schema {
        Schema([Garment.self, GarmentPhoto.self, LandmarkPoint.self, MeasuredValue.self, ExportRecord.self])
    }

    static var fixtureDirectory: URL? {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let tokenText: String?
        if args.contains("--flow-preview"), let index = args.firstIndex(of: "--flow-test-store"),
           args.indices.contains(index + 1) {
            tokenText = args[index + 1]
        } else {
            tokenText = ProcessInfo.processInfo.environment["DOBBY_FLOW_TEST_STORE_TOKEN"]
        }
        guard let tokenText, let token = UUID(uuidString: tokenText) else { return nil }
        return URL.documentsDirectory.appending(path: "FlowUITests", directoryHint: .isDirectory)
            .appending(path: token.uuidString, directoryHint: .isDirectory)
#else
        return nil
#endif
    }

    static func makeContainer() throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let directory = fixtureDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "products.store"),
                cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, configurations: configuration)
        try normalizeStoredMeasurements(in: container)
        return container
    }

    /// 기존 상품의 소수 실측값을 정수로 맞추고 원본 자동 측정값과 상품 수정일은 보존한다.
    static func normalizeStoredMeasurements(in container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garments = try context.fetch(FetchDescriptor<Garment>())
        var hasChanges = false

        for garment in garments {
            let measurements = garment.measurements.filter { measurement in
                measurement.valueCm.isFinite
                    && measurement.valueCm != StoredMeasurementValue.centimeters(measurement.valueCm)
            }
            guard !measurements.isEmpty else { continue }

            let previousUpdatedAt = garment.updatedAt
            for measurement in measurements {
                measurement.valueCm = StoredMeasurementValue.centimeters(measurement.valueCm)
            }
            garment.syncFilterFields()
            garment.updatedAt = previousUpdatedAt
            hasChanges = true
        }

        if hasChanges {
            try context.save()
        }
    }
}

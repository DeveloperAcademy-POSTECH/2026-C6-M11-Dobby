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
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

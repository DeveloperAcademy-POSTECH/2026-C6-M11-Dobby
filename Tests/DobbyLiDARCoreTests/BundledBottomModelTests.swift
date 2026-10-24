import XCTest
import CryptoKit
#if canImport(CoreML)
import CoreML
#endif
@testable import DobbyLiDARCore

final class BundledBottomModelTests: XCTestCase {
    private var packageURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Dobby/Dobby/LiDAR/Models/BottomLandmarks.mlpackage")
    }

    func testBundledWeightsMatchNewVersionAndKeepPreviousIdentities() throws {
        let weights = try Data(contentsOf: packageURL
            .appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin"))
        let hash = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "4a576205b409912cdeda083d4fac801185ffea7802ccd112efbdb9d39ade875f")
        XCTAssertEqual(AutomaticGarmentKind.bottoms.modelVersion, "bottom8-jogger-" + hash.prefix(12))
        XCTAssertEqual(AutomaticGarmentKind.legacyBottom8ModelVersion, "bottom8-5f65f2483f98")
        XCTAssertEqual(AutomaticGarmentKind.legacyBottomModelVersion, "bottom7-976144d4d652")
    }

    #if canImport(CoreML)
    func testBundledModelCompilesAndLoadsWithEightPointContract() throws {
        let compiledURL = try MLModel.compileModel(at: packageURL)
        defer { try? FileManager.default.removeItem(at: compiledURL) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let description = try MLModel(contentsOf: compiledURL, configuration: configuration).modelDescription
        let image = try XCTUnwrap(description.inputDescriptionsByName["image"]?.imageConstraint)
        XCTAssertEqual(image.pixelsWide, 640)
        XCTAssertEqual(image.pixelsHigh, 640)
        let output = try XCTUnwrap(description.outputDescriptionsByName["var_1345"]?.multiArrayConstraint)
        XCTAssertEqual(output.shape.map(\.intValue), [1, 29, 8400])
        XCTAssertEqual(output.dataType, .float32)
        let schema = try BottomLandmarkSchema(jsonData: Data(contentsOf: packageURL.deletingLastPathComponent()
            .appendingPathComponent("schema_bottom8.json")))
        XCTAssertEqual(schema.keypoints, BottomLandmarkSchema.expectedBottom8Keypoints)
        XCTAssertEqual(schema.keypoints.last, "waist_front_center")
        XCTAssertEqual(schema.keypoints.count, 8)
    }
    #endif
}

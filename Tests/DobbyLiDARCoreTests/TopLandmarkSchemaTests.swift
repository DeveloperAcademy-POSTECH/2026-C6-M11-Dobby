import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Fabricated tensors exercise the integration contract, not trained-model accuracy.
final class TopLandmarkSchemaTests: XCTestCase {
    private func data() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository.appendingPathComponent("Dobby/Dobby/LiDAR/Models/schema_top.json"))
    }

    private func schema() throws -> TopLandmarkSchema { try .init(jsonData: data()) }

    private func tensor(anchors: Int = 1) -> [[Double]] {
        var values = Array(repeating: Array(repeating: 0.0, count: anchors), count: 38)
        for anchor in 0..<anchors {
            values[0][anchor] = 320; values[1][anchor] = 320
            values[2][anchor] = 400; values[3][anchor] = 500
            values[4][anchor] = 0.9 - Double(anchor) * 0.1
            let points = [(280.0, 100.0), (360, 100), (220, 130), (420, 130),
                          (230, 230), (410, 230), (80, 350), (560, 350),
                          (230, 530), (325, 540), (410, 530)]
            for (index, point) in points.enumerated() {
                values[5 + 3 * index][anchor] = point.0
                values[6 + 3 * index][anchor] = point.1
                values[7 + 3 * index][anchor] = 0.95
            }
        }
        return values
    }

    private func decode(_ values: [[Double]], geometry: BottomLetterboxGeometry? = nil) throws -> BottomLandmarkPrediction {
        let geometry = try geometry ?? BottomLetterboxGeometry(originalSize: .init(width: 640, height: 640), orientation: .up)
        return try BottomLandmarkDecoder(schema: schema().decoderSchema).decode(
            shape: [1, values.count, values[0].count], geometry: geometry
        ) { values[$0][$1] }
    }

    func testBundledSchemaAndSixMeasurementsMatchTopModelContract() throws {
        let schema = try schema()
        XCTAssertEqual(schema.name, "top")
        XCTAssertEqual(schema.keypoints, TopLandmarkSchema.expectedKeypoints)
        XCTAssertEqual(schema.derivedOrder, ["neck_center"])
        XCTAssertEqual(schema.skeleton.count, 11)
        let definitions = schema.measurementDefinitions
        XCTAssertEqual(definitions.map(\.id), ["top.shoulderWidth", "top.chestWidth", "top.hemWidth",
            "top.sleeveLengthLeft", "top.sleeveLengthRight", "top.totalLength"])
        XCTAssertEqual(definitions.map(\.landmarkIDs), [
            ["shoulder_left", "shoulder_right"], ["armpit_left", "armpit_right"],
            ["hem_left", "hem_right"], ["shoulder_left", "sleeve_end_left"],
            ["shoulder_right", "sleeve_end_right"], ["neck_center", "hem_center"]
        ])
        XCTAssertTrue(definitions.allSatisfy { $0.projection == nil },
                      "Current top measurements keep their physical endpoints and use straight distances")
        XCTAssertEqual(Set(definitions.map(\.id)).count, 6)
        XCTAssertTrue(definitions[3].title.contains("직선"))
        XCTAssertTrue(definitions[4].title.contains("직선"))
        XCTAssertFalse(definitions.flatMap(\.landmarkIDs).contains("armpitLeft"))
    }

    func testSchemaRejectsWrongNameChannelOrderAndNeckDerivation() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        var documents: [[String: Any]] = []
        var changed = original; changed["name"] = "bottom7"; documents.append(changed)
        changed = original; changed["keypoints"] = Array(TopLandmarkSchema.expectedKeypoints.reversed()); documents.append(changed)
        changed = original; changed["derived"] = [:]; documents.append(changed)
        changed = original; changed["derived"] = ["neck_center": ["shoulder_left", "shoulder_right"]]; documents.append(changed)
        for document in documents {
            XCTAssertThrowsError(try TopLandmarkSchema(jsonData: JSONSerialization.data(withJSONObject: document))) { error in
                XCTAssertTrue(error is TopLandmarkSchemaError)
            }
        }
        XCTAssertThrowsError(try TopLandmarkSchema(jsonData: Data("[]".utf8)))
    }

    func testDecoderUsesElevenChannelsAndRetainsSpatialNeckDerivation() throws {
        var values = tensor()
        values[7][0] = 0.87; values[10][0] = 0.66
        let prediction = try decode(values)
        XCTAssertEqual(prediction.points.count, 12)
        XCTAssertEqual(prediction.points.map(\.id), TopLandmarkSchema.expectedKeypoints + ["neck_center"])
        let neck = try XCTUnwrap(prediction.points.last)
        XCTAssertEqual(neck.point, .init(x: 0.5, y: 100 / 640.0))
        XCTAssertEqual(neck.derivedFrom, ["neck_left", "neck_right"])
        XCTAssertEqual(neck.confidence, 0.66)
        let bottomTensor = Array(values.prefix(26))
        XCTAssertThrowsError(try decode(bottomTensor)) { XCTAssertEqual($0 as? BottomLandmarkError, .invalidOutputShape) }
    }

    func testAllOrientationsInvertLetterboxToOriginalCoordinates() throws {
        let original = TopLandmarkSchema.expectedKeypoints.indices.map {
            ImagePoint(x: 0.2 + Double($0) * 0.04, y: 0.25 + Double($0) * 0.02)
        }
        for orientation in ImageOrientation.allCases {
            let geometry = try BottomLetterboxGeometry(originalSize: .init(width: 1920, height: 1080), orientation: orientation)
            var values = tensor()
            for (index, point) in original.enumerated() {
                let displayed = ImageCoordinateTransform.originalToDisplay(point, orientation: orientation)
                values[5 + 3 * index][0] = Double(geometry.padLeft) + displayed.x * Double(geometry.resizedSize.width)
                values[6 + 3 * index][0] = Double(geometry.padTop) + displayed.y * Double(geometry.resizedSize.height)
            }
            let prediction = try decode(values, geometry: geometry)
            for (expected, actual) in zip(original, prediction.points) {
                XCTAssertEqual(actual.point.x, expected.x, accuracy: 1e-12, "\(orientation)/\(actual.id)")
                XCTAssertEqual(actual.point.y, expected.y, accuracy: 1e-12, "\(orientation)/\(actual.id)")
            }
        }
    }

    func testMissingNeckPointDoesNotInventMidpointOrDiscardIndependentPoints() throws {
        var values = tensor()
        values[5][0] = -1
        let prediction = try decode(values)
        XCTAssertFalse(prediction.points.contains { $0.id == "neck_left" || $0.id == "neck_center" })
        XCTAssertEqual(prediction.points.count, 10)
        XCTAssertTrue(prediction.points.contains { $0.id == "armpit_left" })
        XCTAssertTrue(prediction.points.contains { $0.id == "hem_center" })
    }

    func testMultipleSeparatedTopsAreRejectedWhileDuplicateAnchorsAreSuppressed() throws {
        let duplicate = try decode(tensor(anchors: 2))
        XCTAssertEqual(duplicate.detectionConfidence, 0.9)
        var separated = tensor(anchors: 2)
        separated[0] = [100, 540]; separated[2] = [120, 120]
        XCTAssertThrowsError(try decode(separated)) { XCTAssertEqual($0 as? BottomLandmarkError, .multipleGarments) }
        var blank = tensor(); blank[4][0] = 0.249
        XCTAssertThrowsError(try decode(blank)) { XCTAssertEqual($0 as? BottomLandmarkError, .noDetection) }
    }
}

import Foundation
import XCTest
@testable import DobbyLiDARCore

final class BottomLandmarkDecoderTests: XCTestCase {
    private var document: [String: Any] {
        ["name": "bottom7",
         "keypoints": ["waist_left", "waist_right", "crotch", "hem_left_outer", "hem_left_inner", "hem_right_inner", "hem_right_outer"],
         "labels": ["waist_left": ["허리 좌", "왼쪽 끝"], "waist_right": ["허리 우", "오른쪽 끝"]],
         "derived": ["waist_center": ["waist_left", "waist_right"]],
         "flip_pairs": [["waist_left", "waist_right"]],
         "skeleton": [["waist_left", "waist_right"], ["waist_center", "crotch"],
                      ["waist_left", "hem_left_outer"], ["hem_left_outer", "hem_left_inner"],
                      ["crotch", "hem_left_inner"], ["waist_right", "hem_right_outer"],
                      ["hem_right_outer", "hem_right_inner"], ["crotch", "hem_right_inner"]]]
    }

    private func schema(_ document: [String: Any]? = nil) throws -> BottomLandmarkSchema {
        try .decode(JSONSerialization.data(withJSONObject: document ?? self.document))
    }

    private func geometry(_ width: Int = 640, _ height: Int = 640,
                          _ orientation: ImageOrientation = .up) throws -> BottomLetterboxGeometry {
        try .init(originalSize: .init(width: width, height: height), orientation: orientation)
    }

    /// Channel-major synthetic output; these tests validate geometry/contracts, not trained accuracy.
    private func tensor(anchors: Int = 1) -> [[Double]] {
        var values = Array(repeating: Array(repeating: 0.0, count: anchors), count: 26)
        for anchor in 0..<anchors {
            values[0][anchor] = 320
            values[1][anchor] = 320
            values[2][anchor] = 400
            values[3][anchor] = 500
            values[4][anchor] = 0.9 - Double(anchor) * 0.1
            let points = [(180.0, 100.0), (460, 100), (320, 280), (160, 550), (270, 550), (370, 550), (480, 550)]
            for (index, point) in points.enumerated() {
                values[5 + 3 * index][anchor] = point.0
                values[6 + 3 * index][anchor] = point.1
                values[7 + 3 * index][anchor] = 0.9
            }
        }
        return values
    }

    private func decode(_ values: [[Double]], geometry: BottomLetterboxGeometry? = nil) throws -> BottomLandmarkPrediction {
        try BottomLandmarkDecoder(schema: schema()).decode(shape: [1, values.count, values[0].count],
            geometry: try geometry ?? self.geometry()) { values[$0][$1] }
    }

    func testSchemaDerivesEightMeasurementsWithoutUsingManualPresetIDs() throws {
        let definitions = try schema().measurementDefinitions
        XCTAssertEqual(definitions.count, 8)
        XCTAssertEqual(Set(definitions.map(\.id)).count, 8)
        XCTAssertEqual(definitions[0].title, "허리 단면")
        XCTAssertEqual(definitions[1].landmarkIDs, ["waist_center", "crotch"])
        XCTAssertEqual(definitions[2].title, "왼쪽 총장(직선)")
        XCTAssertEqual(definitions[7].title, "오른쪽 인심(직선)")
        XCTAssertEqual(definitions[0].id, "bottom.waist_left.waist_right")
        XCTAssertFalse(definitions.flatMap(\.landmarkIDs).contains("waistLeft"))
    }

    func testBundledSchemaMatchesChannelOrderAndMeasurementGraphUsedByAdapter() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appendingPathComponent("Dobby/Dobby/LiDAR/Models/schema_bottom7.json")
        let bundled = try BottomLandmarkSchema(jsonData: Data(contentsOf: url))
        let expected = try schema()
        XCTAssertEqual(bundled.name, "bottom7")
        XCTAssertEqual(bundled.keypoints, expected.keypoints)
        XCTAssertEqual(bundled.derived, expected.derived)
        XCTAssertEqual(bundled.skeleton, expected.skeleton)
        XCTAssertEqual(bundled.measurementDefinitions.map(\.id), expected.measurementDefinitions.map(\.id))
    }

    func testBundledBottom8UsesDirectFrontCenterAndPreservesDobbyMeasurementOrder() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let schema = try BottomLandmarkSchema(jsonData: Data(contentsOf:
            repository.appendingPathComponent("Dobby/Dobby/LiDAR/Models/schema_bottom8.json")))
        XCTAssertEqual(schema.name, "bottom8")
        XCTAssertEqual(schema.keypoints, BottomLandmarkSchema.expectedBottom8Keypoints)
        XCTAssertEqual(schema.derivedOrder, ["waist_center"])
        let legacy = try self.schema().measurementDefinitions
        let definitions = schema.measurementDefinitions
        XCTAssertEqual(definitions.map(\.id), legacy.enumerated().map { index, definition in
            index == 1 ? "bottom.crotch.waist_front_center" : definition.id
        })
        XCTAssertEqual(definitions[1].landmarkIDs, ["waist_front_center", "crotch"])
        var values = tensor()
        values.append([330]); values.append([140]); values.append([0.81])
        let geometry = try geometry()
        let decoded = try BottomLandmarkDecoder(schema: schema).decode(shape: [1, 29, 1], geometry: geometry) { values[$0][$1] }
        let front = try XCTUnwrap(decoded.points.first { $0.id == "waist_front_center" })
        let middle = try XCTUnwrap(decoded.points.first { $0.id == "waist_center" })
        XCTAssertEqual(front.point, .init(x: 330 / 640.0, y: 140 / 640.0))
        XCTAssertNil(front.derivedFrom)
        XCTAssertNotEqual(front.point, middle.point)
        XCTAssertEqual(middle.derivedFrom, ["waist_left", "waist_right"])
        XCTAssertThrowsError(try BottomLandmarkDecoder(schema: schema).decode(shape: [1, 26, 1], geometry: geometry) { values[$0][$1] })
    }

    func testMissingEighthDirectPointDoesNotFallbackToWaistMidpoint() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let schema = try BottomLandmarkSchema(jsonData: Data(contentsOf:
            repository.appendingPathComponent("Dobby/Dobby/LiDAR/Models/schema_bottom8.json")))
        var values = tensor()
        values.append([-1]); values.append([140]); values.append([0.91])
        let decoded = try BottomLandmarkDecoder(schema: schema).decode(shape: [1, 29, 1], geometry: geometry()) { values[$0][$1] }
        XCTAssertFalse(decoded.points.contains { $0.id == "waist_front_center" })
        XCTAssertTrue(decoded.points.contains { $0.id == "waist_center" })
        let frame = SyntheticFixtures.scene().frame
        let set = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .model, modelVersion: AutomaticGarmentKind.bottoms.modelVersion,
            points: decoded.points, mask: nil, garmentKind: .bottoms)
        let result = LiDARMeasurementEngine().measure(frame: frame, landmarks: set, definitions: schema.measurementDefinitions)
        XCTAssertEqual(result.values[1].id, "bottom.crotch.waist_front_center")
        XCTAssertEqual(result.values[1].failure, .missingLandmark)
        XCTAssertNil(result.values[1].meters)
        XCTAssertTrue(result.values.enumerated().filter { $0.offset != 1 }.allSatisfy { $0.element.meters != nil })
    }

    func testMeasurementIDStableWhenSkeletonOrderingAndDirectionChanges() throws {
        var changed = document
        let original = try schema().measurementDefinitions
        changed["skeleton"] = (document["skeleton"] as! [[String]]).reversed().map { Array($0.reversed()) }
        XCTAssertEqual(Set(try schema(changed).measurementDefinitions.map(\.id)), Set(original.map(\.id)))
    }

    func testDynamicSchemaSupportsNewChannelCountAndDerivedDependencyOrder() throws {
        let schema = try schema(["name": "future", "keypoints": ["A", "B", "C"],
                                 "derived": ["Z": ["A", "B"], "D": ["Z", "C"]],
                                 "labels": ["A": ["끝점 A"]], "skeleton": [["A", "D"]]])
        XCTAssertEqual(schema.derivedOrder, ["Z", "D"])
        XCTAssertEqual(schema.measurementDefinitions[0].title, "끝점 A ↔ D(직선)")
        var values = Array(repeating: 0.0, count: 14)
        values[0] = 320; values[1] = 320; values[2] = 500; values[3] = 500; values[4] = 0.8
        for index in 0..<3 {
            values[5 + 3 * index] = Double(index + 1) * 100
            values[6 + 3 * index] = 200
            values[7 + 3 * index] = 0.9 - Double(index) * 0.2
        }
        let prediction = try BottomLandmarkDecoder(schema: schema).decode(shape: [1, 14, 1], geometry: geometry()) { channel, _ in values[channel] }
        let point = try XCTUnwrap(prediction.points.first { $0.id == "D" })
        XCTAssertEqual(point.point.x, 225 / 640.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(point.confidence), 0.5, accuracy: 1e-12)
    }

    func testSchemaRejectsUnknownDuplicateAndCyclicReferences() throws {
        let badDocuments: [[String: Any]] = [
            ["name": "bad", "keypoints": ["A", "A"], "skeleton": [["A", "B"]]],
            ["name": "bad", "keypoints": ["A", "B"], "derived": ["A": ["A", "B"]], "skeleton": [["A", "B"]]],
            ["name": "bad", "keypoints": ["A", "B"], "derived": ["C": ["A", "missing"]], "skeleton": [["A", "B"]]],
            ["name": "bad", "keypoints": ["A", "B"], "derived": ["C": ["A", "D"], "D": ["B", "C"]], "skeleton": [["A", "B"]]],
            ["name": "bad", "keypoints": ["A", "B"], "skeleton": [["A", "missing"]]],
            ["name": "bad", "keypoints": ["A", "B"], "skeleton": [["A", "B"], ["B", "A"]]],
            ["name": "bad", "keypoints": ["A", "B"], "skeleton": [["A", "A"]]],
            ["name": "bad", "keypoints": ["A", "B"], "skeleton": [["A", "B"]], "flip_pairs": [["A", "unknown"]]],
            ["name": "bad", "keypoints": ["A", "B"], "skeleton": [["A", "B"]], "derived": ["C": ["A", "A"]]]
        ]
        for value in badDocuments { XCTAssertThrowsError(try schema(value)) }
        XCTAssertThrowsError(try BottomLandmarkSchema(jsonData: Data("[]".utf8)))
    }

    func testPortraitAndLandscapeUseIntegerPaddingAndActualResizedScale() throws {
        let landscape = try geometry(1000, 667)
        XCTAssertEqual(landscape.resizedSize, .init(width: 640, height: 427))
        XCTAssertEqual(landscape.padTop, 106)
        XCTAssertEqual(landscape.padBottom, 107)
        let original = try XCTUnwrap(landscape.originalPoint(modelX: 128, modelY: 106 + 427 * 0.3))
        XCTAssertEqual(original.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(original.y, 0.3, accuracy: 1e-12)
        let portrait = try geometry(667, 1000)
        XCTAssertEqual(portrait.resizedSize, .init(width: 427, height: 640))
        XCTAssertEqual(portrait.padLeft, 106)
        XCTAssertEqual(portrait.padRight, 107)
        XCTAssertEqual(try XCTUnwrap(portrait.originalPoint(modelX: 106 + 427 * 0.4, modelY: 128)).x, 0.4, accuracy: 1e-12)
    }

    func testResizeRoundHalfToEvenMatchesTrainingLetterbox() throws {
        let geometry = try geometry(1280, 853)
        XCTAssertEqual(geometry.resizedSize.height, 426)
        XCTAssertEqual(geometry.padTop, 107)
    }

    func testAllOrientationsReturnSameOriginalPointForRectangularImage() throws {
        let expected = ImagePoint(x: 0.23, y: 0.61)
        for orientation in ImageOrientation.allCases {
            let geometry = try geometry(1920, 1080, orientation)
            let displayed = ImageCoordinateTransform.originalToDisplay(expected, orientation: orientation)
            let point = try XCTUnwrap(geometry.originalPoint(
                modelX: Double(geometry.padLeft) + displayed.x * Double(geometry.resizedSize.width),
                modelY: Double(geometry.padTop) + displayed.y * Double(geometry.resizedSize.height)))
            XCTAssertEqual(point.x, expected.x, accuracy: 1e-12, "\(orientation)")
            XCTAssertEqual(point.y, expected.y, accuracy: 1e-12, "\(orientation)")
            XCTAssertEqual(geometry.orientedSize.width, orientation == .up || orientation == .down ? 1920 : 1080)
        }
    }

    func testPaddingAndOutOfBoundsAreRejectedWithoutClipping() throws {
        let geometry = try geometry(1920, 1080)
        XCTAssertNil(geometry.originalPoint(modelX: 300, modelY: 139.999))
        XCTAssertNil(geometry.originalPoint(modelX: -0.001, modelY: 320))
        XCTAssertNil(geometry.originalPoint(modelX: 640, modelY: 320))
        XCTAssertNil(geometry.originalPoint(modelX: 300, modelY: 500))
        XCTAssertNil(geometry.originalPoint(modelX: .nan, modelY: 320))
        XCTAssertNil(geometry.originalPoint(modelX: 320, modelY: .infinity))
        XCTAssertEqual(geometry.originalPoint(modelX: 0, modelY: 140), .init(x: 0, y: 0))
    }

    func testRotatedBoundariesFollowOriginalHalfOpenImageExtent() throws {
        let right = try geometry(1920, 1080, .right)
        XCTAssertEqual(right.originalPoint(modelX: 500, modelY: 0), .init(x: 0, y: 0))
        XCTAssertNil(right.originalPoint(modelX: 140, modelY: 320))
        XCTAssertNil(right.originalPoint(modelX: 500.001, modelY: 320))
    }

    func testInvalidGeometryIsRejectedBeforeIntegerConversion() throws {
        for size in [PixelSize(width: 0, height: 10), .init(width: Int.max, height: 10), .init(width: 16_384, height: 1)] {
            XCTAssertThrowsError(try BottomLetterboxGeometry(originalSize: size, orientation: .up))
        }
        XCTAssertThrowsError(try BottomLetterboxGeometry(originalSize: .init(width: 640, height: 480), orientation: .up, inputSize: Int.max))
    }

    func testDetectionThresholdIsInclusiveAndDerivedConfidenceUsesMinimum() throws {
        var values = tensor()
        values[4][0] = 0.25
        values[7][0] = 0.9
        values[10][0] = 0.31
        let prediction = try decode(values)
        XCTAssertEqual(prediction.detectionConfidence, 0.25)
        XCTAssertEqual(prediction.points.count, 8)
        let center = try XCTUnwrap(prediction.points.first { $0.id == "waist_center" })
        XCTAssertEqual(center.point, .init(x: 0.5, y: 100 / 640.0))
        XCTAssertEqual(center.confidence, 0.31)
        XCTAssertTrue(center.isVisible)
        XCTAssertEqual(prediction.points[1].confidence, 0.31)
        XCTAssertTrue(prediction.points[1].isVisible)
    }

    func testNoDetectionForBelowThresholdAndNonfiniteScores() throws {
        for score in [0.249999, -0.5, Double.nan, .infinity] {
            var values = tensor()
            values[4][0] = score
            XCTAssertThrowsError(try decode(values)) { XCTAssertEqual($0 as? BottomLandmarkError, .noDetection) }
        }
    }

    func testNMSKeepsBestDuplicateAnchorAndSuppressesOverlappingBoxes() throws {
        var values = tensor(anchors: 3)
        values[4] = [0.4, 0.95, 0.5]
        values[0][2] = 325
        values[5][1] = 200
        let prediction = try decode(values)
        XCTAssertEqual(prediction.detectionConfidence, 0.95)
        XCTAssertEqual(prediction.points[0].point.x, 200 / 640.0)
    }

    func testNMSRejectsSeparateGarmentsEvenWhenOneHasHigherScore() throws {
        var values = tensor(anchors: 2)
        values[0] = [120, 520]
        values[2] = [150, 150]
        XCTAssertThrowsError(try decode(values)) { XCTAssertEqual($0 as? BottomLandmarkError, .multipleGarments) }
    }

    func testLowScoreSecondaryGarmentDoesNotBecomeDetection() throws {
        var values = tensor(anchors: 2)
        values[0] = [120, 520]
        values[2] = [150, 150]
        values[4][1] = 0.249
        XCTAssertEqual(try decode(values).points.count, 8)
    }

    func testInvalidBoxFailsInsteadOfProducingConfidentMeasurement() throws {
        for (channel, value) in [(0, Double.nan), (1, -1.0), (2, 0.0), (3, .infinity), (4, 1.01)] {
            var values = tensor()
            values[channel][0] = value
            XCTAssertThrowsError(try decode(values)) { XCTAssertEqual($0 as? BottomLandmarkError, .invalidCandidate) }
        }
    }

    func testMalformedTensorNeverCallsValueAccessor() throws {
        let decoder = try BottomLandmarkDecoder(schema: schema())
        let geometry = try geometry()
        for shape in [[], [26, 8400], [2, 26, 8400], [1, 27, 8400], [1, 26, 0], [1, 26, Int.max]] {
            var reads = 0
            XCTAssertThrowsError(try decoder.decode(shape: shape, geometry: geometry) { _, _ in reads += 1; return 0 }) {
                XCTAssertEqual($0 as? BottomLandmarkError, .invalidOutputShape)
            }
            XCTAssertEqual(reads, 0)
        }
    }

    func testAccessorSupportsPaddedNoncontiguousTensorStrides() throws {
        let values = tensor(anchors: 2)
        let channelStride = 7, anchorStride = 3, base = 5
        var storage = Array(repeating: Float.nan, count: 26 * channelStride + base)
        for channel in 0..<26 {
            for anchor in 0..<2 { storage[base + channel * channelStride + anchor * anchorStride] = Float(values[channel][anchor]) }
        }
        let prediction = try BottomLandmarkDecoder(schema: schema()).decode(shape: [1, 26, 2], geometry: geometry()) {
            Double(storage[base + $0 * channelStride + $1 * anchorStride])
        }
        XCTAssertEqual(prediction.points.count, 8)
        XCTAssertEqual(prediction.points[0].point.x, 180 / 640.0, accuracy: 1e-12)
        XCTAssertEqual(prediction.detectionConfidence, 0.9, accuracy: 1e-6)
    }

    func testInvalidPointIsOmittedButOtherMeasurementsSurvive() throws {
        for invalid in [Double.nan, .infinity, -1, 640] {
            var values = tensor()
            values[11][0] = invalid // crotch x
            let prediction = try decode(values)
            XCTAssertEqual(prediction.points.count, 7)
            XCTAssertNil(prediction.points.first { $0.id == "crotch" })
            XCTAssertNotNil(prediction.points.first { $0.id == "waist_center" })
        }
    }

    func testDerivedPointIsOmittedWhenAnySourceIsOutsideImage() throws {
        var values = tensor()
        values[5][0] = -1
        let prediction = try decode(values)
        XCTAssertEqual(prediction.points.count, 6)
        XCTAssertNil(prediction.points.first { $0.id == "waist_left" })
        XCTAssertNil(prediction.points.first { $0.id == "waist_center" })
        XCTAssertNotNil(prediction.points.first { $0.id == "waist_right" })
    }

    func testNonfiniteOrOutOfRangePointConfidenceIsOmitted() throws {
        for confidence in [Double.nan, .infinity, -0.1, 1.1] {
            var values = tensor()
            values[7][0] = confidence
            let prediction = try decode(values)
            XCTAssertNil(prediction.points.first { $0.id == "waist_left" })
            XCTAssertNil(prediction.points.first { $0.id == "waist_center" })
        }
        var zero = tensor()
        zero[7][0] = 0
        XCTAssertEqual(try decode(zero).points.first { $0.id == "waist_left" }?.confidence, 0)
    }

    func testMeasurementEnginePreservesLowConfidenceAndMissingLandmarkFailures() throws {
        let fixture = SyntheticFixtures.scene()
        var values = tensor()
        values[7][0] = 0.3 // waist_left: preserve confidence, do not mark as occluded
        values[11][0] = .nan // crotch: no invented/clipped fallback point
        let prediction = try decode(values, geometry: geometry(800, 600))
        let landmarks = GarmentLandmarkSet(sessionID: fixture.frame.sessionID, frameID: fixture.frame.frameID,
            origin: .model, modelVersion: "synthetic-decoder-regression", points: prediction.points, mask: nil)
        let result = LiDARMeasurementEngine().measure(frame: fixture.frame, landmarks: landmarks,
            definitions: try schema().measurementDefinitions)
        XCTAssertEqual(result.values[0].failure, .lowLandmarkConfidence)
        XCTAssertEqual(result.values[4].failure, .missingLandmark)
        XCTAssertEqual(result.values[7].failure, .missingLandmark)
        XCTAssertEqual(result.values[3].status, .valid)
        XCTAssertEqual(result.values[5].status, .valid)
        XCTAssertEqual(result.values[6].status, .valid)
    }
}

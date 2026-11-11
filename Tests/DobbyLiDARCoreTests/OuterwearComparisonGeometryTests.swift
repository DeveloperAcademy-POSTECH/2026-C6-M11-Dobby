import XCTest
@testable import DobbyLiDARCore

final class OuterwearComparisonGeometryTests: XCTestCase {
    func testTwoCenterRecoveryRestoresEachCropAndSupportsWithoutOtherObservations() throws {
        let support = OuterwearCenterSupport(left: .init(x: 0.4, y: 0.5), right: .init(x: 0.6, y: 0.5))
        let input = OuterwearLengthRefinementResponse(requestID: "test", view: .front, neckStyle: .hood,
            frontNeckSeamCenter: .init(point: support.midpoint, visibility: .estimated),
            hemCenter: .init(point: .init(x: 0.5, y: 0.8), visibility: .visible),
            centerSupport: .init(frontNeckSeamCenter: support))
        let crops: [OuterwearComparisonCrop] = [
            .init(region: .upper, rect: .init(x: 0.2, y: 0.1, width: 0.6, height: 0.3)),
            .init(region: .hem, rect: .init(x: 0.3, y: 0.7, width: 0.4, height: 0.3))]
        let restored = try input.restoring(crops: crops).landmarkResponse(expectedRequestID: "test")
        XCTAssertEqual(restored.frontNeckSeamCenter?.point?.y ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(restored.points["hem_center"]?.point?.y ?? 0, 0.94, accuracy: 1e-9)
        XCTAssertEqual(restored.centerSupport?.frontNeckSeamCenter?.left.x ?? 0, 0.44, accuracy: 1e-9)
        XCTAssertTrue(restored.points.filter { $0.key != "hem_center" }.allSatisfy { $0.value.point == nil })
        XCTAssertThrowsError(try input.restoring(crops: [crops[0], crops[0]]))
        XCTAssertThrowsError(try input.landmarkResponse(expectedRequestID: "another-frame"))
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        wire["points"] = ["shoulder_left": ["x": 0.1, "y": 0.1]]
        XCTAssertThrowsError(try JSONDecoder().decode(OuterwearLengthRefinementResponse.self,
            from: JSONSerialization.data(withJSONObject: wire)))
    }

    private func response() -> OuterwearLandmarkResponse {
        .init(requestID: "test", schemaVersion: OuterwearLandmarkResponse.expectedViewLengthSchemaVersion,
              modelVersion: OuterwearLandmarkResponse.expectedViewLengthModelVersion,
              view: .front, neckStyle: .hood,
              points: Dictionary(uniqueKeysWithValues: TopLandmarkSchema.expectedKeypoints.map {
                ($0, .init(point: .init(x: 0.25, y: 0.75), visibility: .visible))
              }), backNeckSeamCenter: .init(point: nil, visibility: .uncertain),
              frontNeckSeamCenter: .init(point: .init(x: 0.5, y: 0.4), visibility: .visible))
    }

    func testCropCoordinatesRestoreIntoOriginalWithoutSnappingOrFillingNulls() throws {
        var input = response()
        input.points["hem_center"] = .init(point: nil, visibility: .uncertain)
        let crop = OuterwearComparisonCrop(region: .garment, rect: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.4))
        let restored = try OuterwearComparisonGeometry.restoring(input, crops: [crop])
        XCTAssertEqual(restored.points["shoulder_left"]?.point?.x ?? 0, 0.25, accuracy: 1e-12)
        XCTAssertEqual(restored.points["shoulder_left"]?.point?.y ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(restored.frontNeckSeamCenter?.point?.x ?? 0, 0.4, accuracy: 1e-12)
        XCTAssertEqual(restored.frontNeckSeamCenter?.point?.y ?? 0, 0.36, accuracy: 1e-12)
        XCTAssertNil(restored.points["hem_center"]?.point)
        XCTAssertNil(restored.backNeckSeamCenter.point)
        XCTAssertEqual(input.points["shoulder_left"]?.point?.y, 0.75, "A/B source response stays immutable")
    }

    func testRegionMappingUsesItsOwnCropIncludingBothTotalLengthHelpers() throws {
        let regions = OuterwearComparisonRegion.allCases.filter { $0 != .garment }
        let crops = regions.enumerated().map { index, region in
            OuterwearComparisonCrop(region: region, rect: .init(x: Double(index) * 0.1, y: 0.1, width: 0.2, height: 0.3))
        }
        let result = try OuterwearComparisonGeometry.restoring(response(), crops: crops)
        for (index, region) in regions.enumerated() {
            for id in region.pointIDs where !["top_length_start", "front_length_start"].contains(id) {
                XCTAssertEqual(result.points[id]?.point?.x ?? -1, Double(index) * 0.1 + 0.05, accuracy: 1e-12)
            }
        }
        XCTAssertEqual(result.frontNeckSeamCenter?.point?.x, 0.1)
        XCTAssertThrowsError(try OuterwearComparisonGeometry.restoring(response(), crops: Array(crops.dropLast())))
        XCTAssertThrowsError(try OuterwearComparisonGeometry.restoring(response(), crops: crops + [crops[0]]))
    }

    func testPixelAlignmentIncludesEntireBoundsAtEveryImageEdge() throws {
        let rect = try OuterwearComparisonGeometry.aligned(.init(x: 0.101, y: 0.203, width: 0.399, height: 0.797),
                                                            size: .init(width: 101, height: 77))
        XCTAssertEqual(rect.x * 101, 10, accuracy: 1e-12)
        XCTAssertEqual(rect.y * 77, 15, accuracy: 1e-12)
        XCTAssertEqual(rect.width * 101, 41, accuracy: 1e-12)
        XCTAssertEqual((rect.y + rect.height) * 77, 77, accuracy: 1e-12)
        XCTAssertThrowsError(try OuterwearComparisonGeometry.aligned(.init(x: -.infinity, y: 0, width: 1, height: 1), size: .init(width: 101, height: 77)))
    }

    func testMissingPointsUseBroadFallbackRegionsNotNeutralPlaceholders() throws {
        var input = response()
        for id in input.points.keys { input.points[id] = .init(point: nil, visibility: .uncertain) }
        input.frontNeckSeamCenter = .init(point: nil, visibility: .occluded)
        let crops = try OuterwearComparisonGeometry.refinementCrops(response: input,
            bounds: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8), size: .init(width: 1000, height: 1000))
        XCTAssertEqual(crops.count, 5)
        XCTAssertTrue(crops.allSatisfy { $0.rect.isValid })
        let left = try XCTUnwrap(crops.first { $0.region == .leftCuff })
        XCTAssertEqual(left.rect.x, 0.1)
        XCTAssertEqual(left.rect.width, 0.4)
        XCTAssertEqual(left.rect.height, 0.8)
    }

    func testMaskBoundsKeepPaddingAndDoNotBorrowOtherPixels() throws {
        var values = [UInt8](repeating: 0, count: 100)
        for y in 2..<8 { for x in 1..<9 { values[y * 10 + x] = 1 } }
        let rect = try OuterwearComparisonGeometry.garmentBounds(mask: .init(size: .init(width: 10, height: 10), values: values))
        XCTAssertEqual(rect, .init(x: 0.1, y: 0.2, width: 0.8, height: 0.6))
        let padded = OuterwearComparisonGeometry.padded(rect)
        XCTAssertLessThan(padded.x, rect.x)
        XCTAssertGreaterThan(padded.width, rect.width)
        XCTAssertTrue(padded.isValid)
        XCTAssertThrowsError(try OuterwearComparisonGeometry.garmentBounds(mask: .init(size: .init(width: 10, height: 10), values: [])))
    }
}

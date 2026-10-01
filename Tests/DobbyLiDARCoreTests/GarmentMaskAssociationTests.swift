import XCTest
@testable import DobbyLiDARCore

final class GarmentMaskAssociationTests: XCTestCase {
    private let size = PixelSize(width: 100, height: 80)

    private func pants() -> GarmentMask {
        var mask = GarmentMask(size: size, values: .init(repeating: 0, count: 8_000))
        for y in 10..<70 {
            for x in 20..<80 where y < 35 || x < 44 || x >= 56 {
                mask.values[y * size.width + x] = 1
            }
        }
        return mask
    }

    private func points() -> [GarmentLandmark] {
        [("waist_left", 0.20, 0.125), ("waist_right", 0.79, 0.125),
         ("crotch", 0.5, 0.425), ("hem_left_outer", 0.2, 0.8625),
         ("hem_left_inner", 0.43, 0.8625), ("hem_right_inner", 0.56, 0.8625),
         ("hem_right_outer", 0.79, 0.8625)].map {
            .init(id: $0.0, point: .init(x: $0.1, y: $0.2), confidence: 0.9)
        }
    }

    func testMatchedSilhouetteRetainsLegGapInsteadOfBoundingBox() throws {
        let mask = pants()
        let result = try GarmentMaskAssociation.select(masks: [mask], points: points(), imageSize: size)
        XCTAssertEqual(result.mask, mask)
        XCTAssertEqual(result.mask.values[60 * 100 + 50], 0)
        XCTAssertEqual(result.mask.values[60 * 100 + 30], 1)
        XCTAssertEqual(result.matchedLandmarkCount, 7)
        XCTAssertEqual(result.bounds, .init(x: 0.2, y: 0.125, width: 0.6, height: 0.75))
    }

    func testGenericForegroundWithoutSemanticPointsIsNotGarment() {
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [pants()], points: [], imageSize: size)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
    }

    func testMultipleSubstantialObjectsAreRejectedRatherThanChoosingLargest() {
        var second = GarmentMask(size: size, values: .init(repeating: 0, count: 8_000))
        for y in 20..<60 { for x in 0..<10 { second.values[y * 100 + x] = 1 } }
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [pants(), second], points: points(), imageSize: size)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .multipleForegrounds)
        }
    }

    func testTinySpeckDoesNotReplaceTheMatchedGarment() throws {
        var speck = GarmentMask(size: size, values: .init(repeating: 0, count: 8_000))
        speck.values[0] = 1
        let result = try GarmentMaskAssociation.select(masks: [speck, pants()], points: points(), imageSize: size)
        XCTAssertEqual(result.mask, pants())
    }

    func testBoundaryMatchingToleranceDoesNotDilateTheMeasurementMask() throws {
        var landmarks = points()
        landmarks[0].point.x = 0.19
        let result = try GarmentMaskAssociation.select(masks: [pants()], points: landmarks, imageSize: size)
        XCTAssertEqual(result.matchedLandmarkCount, 7)
        XCTAssertEqual(result.mask.values[10 * 100 + 19], 0)
        XCTAssertEqual(result.mask, pants())
    }

    func testWrongForegroundAndPredictionsInTheLegGapAreRejected() {
        var wrong = points()
        for i in wrong.indices { wrong[i].point = .init(x: 0.5, y: 0.75) }
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [pants()], points: wrong, imageSize: size)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
    }

    func testDerivedAndLowConfidencePointsDoNotInventEnoughSemanticSupport() {
        var landmarks = Array(points().prefix(2))
        landmarks.append(.init(id: "middle", point: .init(x: 0.5, y: 0.2), confidence: 1,
                               derivedFrom: ["waist_left", "waist_right"]))
        landmarks.append(.init(id: "low", point: .init(x: 0.3, y: 0.8), confidence: 0.49))
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [pants()], points: landmarks, imageSize: size)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
    }

    func testMalformedOrWrongAspectMaskCannotEnterDepthEngine() {
        var truncated = pants(); truncated.values.removeLast()
        var illegal = pants(); illegal.values[0] = 2
        var wrongAspect = pants(); wrongAspect.size = .init(width: 80, height: 100)
        for mask in [truncated, illegal, wrongAspect] {
            XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [mask], points: points(), imageSize: size)) {
                XCTAssertEqual($0 as? GarmentMaskAssociationError, .invalidMask)
            }
        }
    }

    func testDistinctPointNamesAtOneLocationCannotConfirmSilhouette() {
        let clustered = (0..<7).map { GarmentLandmark(id: "p\($0)", point: .init(x: 0.3, y: 0.2), confidence: 1) }
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [pants()], points: clustered, imageSize: size)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
    }
}

import Foundation
import XCTest
@testable import DobbyLiDARCore

final class TopMaskRecoveryTests: XCTestCase {
    private let size = PixelSize(width: 100, height: 100)

    private func mask() -> GarmentMask {
        var values = [UInt8](repeating: 0, count: 10_000)
        for y in 20..<80 { for x in 20..<80 { values[y * 100 + x] = 1 } }
        return .init(size: size, values: values)
    }

    private func pointsWithThreeOutliers() -> [GarmentLandmark] {
        let direct: [(String, Double, Double)] = [
            ("neck_left", 0.98, 0.01), ("neck_right", 0.55, 0.21),
            ("shoulder_left", 0.25, 0.25), ("shoulder_right", 0.75, 0.25),
            ("armpit_left", 0.25, 0.4), ("armpit_right", 0.75, 0.4),
            ("sleeve_end_left", 0.98, 0.04), ("sleeve_end_right", 0.98, 0.07),
            ("hem_left", 0.25, 0.78), ("hem_center", 0.5, 0.78), ("hem_right", 0.75, 0.78)
        ]
        return direct.map { .init(id: $0.0, point: .init(x: $0.1, y: $0.2), confidence: 0.9) }
            + [.init(id: "neck_center", point: .init(x: 0.765, y: 0.11), confidence: 0.9,
                     derivedFrom: ["neck_left", "neck_right"])]
    }

    func testPartialTopKeepsExactMaskButRejectsUnassociatedPointsAndTheirDerivedPoints() throws {
        let original = pointsWithThreeOutliers()
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [mask()], points: original, imageSize: size)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
        let selection = try GarmentMaskAssociation.select(masks: [mask()], points: original,
            imageSize: size, policy: .partialTop)
        XCTAssertEqual(selection.mask, mask())
        XCTAssertEqual(selection.matchedLandmarkCount, 8)
        let validated = selection.validatedPoints(original)
        XCTAssertEqual(validated.map(\.point), original.map(\.point))
        XCTAssertEqual(validated.map(\.confidence), original.map(\.confidence))
        XCTAssertEqual(validated.map(\.derivedFrom), original.map(\.derivedFrom))
        XCTAssertEqual(Set(validated.filter { !$0.isVisible }.map(\.id)),
            Set(["neck_left", "neck_center", "sleeve_end_left", "sleeve_end_right"]))
    }

    func testPartialTopOnlyInvalidatesDependentMeasurements() throws {
        let selection = try GarmentMaskAssociation.select(masks: [mask()], points: pointsWithThreeOutliers(),
            imageSize: size, policy: .partialTop)
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1, capturedAt: .now,
            imageSize: size, intrinsics: .init(fx: 100, fy: 100, cx: 50, cy: 50, referenceSize: size),
            depth: .init(size: size, values: .init(repeating: 1, count: 10_000),
                         confidence: .init(repeating: 2, count: 10_000)), source: .synthetic, orientation: .up)
        let landmarks = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID, origin: .model,
            modelVersion: "top-test", points: selection.validatedPoints(pointsWithThreeOutliers()), mask: selection.mask)
        let result = LiDARMeasurementEngine().measure(frame: frame, landmarks: landmarks,
            definitions: TopLandmarkSchema.canonicalMeasurementDefinitions)
        for id in ["top.shoulderWidth", "top.chestWidth", "top.hemWidth"] {
            XCTAssertEqual(result.values.first { $0.id == id }?.status, .valid)
        }
        for id in ["top.totalLength", "top.sleeveLengthLeft", "top.sleeveLengthRight"] {
            XCTAssertEqual(result.values.first { $0.id == id }?.status, .unavailable)
            XCTAssertEqual(result.values.first { $0.id == id }?.failure, .occludedLandmark)
        }
    }

    func testPartialTopRejectsWeakBodyAnchorsEvenWhenManyOtherPointsMatch() {
        var points = pointsWithThreeOutliers()
        for index in points.indices where ["hem_left", "hem_right"].contains(points[index].id) {
            points[index].confidence = 0.69
        }
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [mask()], points: points,
            imageSize: size, policy: .partialTop)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
    }

    func testPartialTopRejectsBodyAnchorsWithoutSpatialSeparation() {
        var points = pointsWithThreeOutliers()
        for index in points.indices where points[index].id == "hem_left" {
            points[index].point = .init(x: 0.25, y: 0.4)
        }
        for index in points.indices where points[index].id == "hem_right" {
            points[index].point = .init(x: 0.75, y: 0.4)
        }
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [mask()], points: points,
            imageSize: size, policy: .partialTop)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
    }

    func testPartialTopRejectsFewerThanSixDirectMatches() {
        let points = pointsWithThreeOutliers().filter {
            ["armpit_left", "armpit_right", "hem_left", "hem_right", "hem_center", "neck_left"].contains($0.id)
        }
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [mask()], points: points,
            imageSize: size, policy: .partialTop)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
    }

    func testPartialTopCannotOverrideMultipleForegroundsOrAnUnrelatedObject() {
        var second = mask()
        for index in second.values.indices { second.values[index] = index % 100 < 10 ? 1 : 0 }
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [mask(), second], points: pointsWithThreeOutliers(),
            imageSize: size, policy: .partialTop)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .multipleForegrounds)
        }
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [second], points: pointsWithThreeOutliers(),
            imageSize: size, policy: .partialTop)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
    }

    func testDerivedPointCannotReplaceMissingStrongDirectBodyAnchor() {
        var points = pointsWithThreeOutliers()
        let index = points.firstIndex { $0.id == "hem_left" }!
        points[index].derivedFrom = ["shoulder_left", "armpit_left"]
        XCTAssertThrowsError(try GarmentMaskAssociation.select(masks: [mask()], points: points,
            imageSize: size, policy: .partialTop)) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
    }
}

import XCTest
@testable import DobbyLiDARCore

final class ManualLandmarkEditingTests: XCTestCase {
    private func encoded(_ set: GarmentLandmarkSet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(set)
    }

    private func measure(frame: MeasurementFrame, points: GarmentLandmarkSet) throws -> MeasurementValue {
        try XCTUnwrap(LiDARMeasurementEngine().measure(
            frame: frame, landmarks: points, definitions: [.testDistance]
        ).values.first)
    }

    func testEditingOneModelPointCannotValidateAnUnconfirmedLowConfidencePoint() throws {
        let scene = SyntheticFixtures.scene()
        var set = scene.landmarks
        set.origin = .model
        set.modelVersion = "garment-test-model"
        set.points[1].confidence = 0.1
        let originalA = set.points[0].point, originalB = set.points[1].point
        XCTAssertEqual(try measure(frame: scene.frame, points: set).failure, .lowLandmarkConfidence)

        XCTAssertTrue(set.placeManualLandmark(at: 0, point: originalA))
        XCTAssertEqual(set.origin, .manual)
        XCTAssertNil(set.modelVersion)
        XCTAssertTrue(set.points[0].isVisible)
        XCTAssertNil(set.points[0].confidence)
        XCTAssertFalse(set.points[1].isVisible)
        XCTAssertNil(set.points[1].confidence)
        XCTAssertEqual(set.points[1].point, originalB)
        XCTAssertEqual(set.sessionID, scene.frame.sessionID)
        XCTAssertEqual(set.frameID, scene.frame.frameID)
        XCTAssertEqual(set.mask?.values, scene.landmarks.mask?.values)
        let partial = try measure(frame: scene.frame, points: set)
        XCTAssertEqual(partial.status, .unavailable)
        XCTAssertEqual(partial.failure, .occludedLandmark)
        XCTAssertNil(partial.meters)

        // Only an explicit confirmation of B permits the final manual measurement.
        XCTAssertTrue(set.placeManualLandmark(at: 1, point: originalB))
        XCTAssertTrue(set.points[0].isVisible)
        XCTAssertEqual(set.points[0].point, originalA)
        let completed = try measure(frame: scene.frame, points: set)
        XCTAssertEqual(completed.status, .valid)
        XCTAssertEqual(try XCTUnwrap(completed.meters), scene.expectedMeters, accuracy: 0.0001)
    }

    func testMissingModelConfidenceAlsoRequiresTheOtherPointToBeConfirmed() throws {
        let scene = SyntheticFixtures.scene()
        var set = scene.landmarks
        set.origin = .model
        set.points[1].confidence = nil
        XCTAssertEqual(try measure(frame: scene.frame, points: set).status, .uncertain)
        XCTAssertTrue(set.placeManualLandmark(at: 0, point: set.points[0].point))
        XCTAssertFalse(set.points[1].isVisible)
        XCTAssertEqual(try measure(frame: scene.frame, points: set).status, .unavailable)
    }

    func testFirstManualConfirmationInvalidatesEveryOtherModelPoint() {
        var set = SyntheticFixtures.scene().landmarks
        set.origin = .model
        set.points.append(.init(id: "C", point: .init(x: 0.5, y: 0.2), confidence: 0.9))
        XCTAssertTrue(set.placeManualLandmark(at: 1, point: .init(x: 0.7, y: 0.4)))
        XCTAssertEqual(set.points.map(\.isVisible), [false, true, false])
        XCTAssertTrue(set.points.allSatisfy { $0.confidence == nil })
    }

    func testLaterManualEditsKeepPreviouslyConfirmedPoints() {
        var set = SyntheticFixtures.scene().landmarks
        set.origin = .manual
        set.points[1].confidence = nil
        let other = set.points[1]
        XCTAssertTrue(set.placeManualLandmark(at: 0, point: .init(x: 0.32, y: 0.48)))
        XCTAssertEqual(set.points[1].point, other.point)
        XCTAssertEqual(set.points[1].confidence, other.confidence)
        XCTAssertEqual(set.points[1].isVisible, other.isVisible)
    }

    func testSyntheticDemoKeepsItsOtherPointAndSyntheticResultSource() {
        let scene = SyntheticFixtures.scene()
        var set = scene.landmarks
        let other = set.points[1]
        XCTAssertTrue(set.placeManualLandmark(at: 0, point: set.points[0].point))
        XCTAssertEqual(set.origin, .manual)
        XCTAssertEqual(set.points[1].point, other.point)
        XCTAssertEqual(set.points[1].confidence, other.confidence)
        XCTAssertTrue(set.points[1].isVisible)
        let output = LiDARMeasurementEngine().measure(
            frame: scene.frame, landmarks: set, definitions: [.testDistance]
        )
        XCTAssertEqual(output.source, .synthetic)
        XCTAssertEqual(output.values.first?.status, .valid)
    }

    func testInvalidIndexAndCoordinatesNeverMutateTheSet() throws {
        var original = SyntheticFixtures.scene().landmarks
        original.origin = .model
        original.modelVersion = "retained-model"
        let before = try encoded(original)
        for index in [-1, original.points.count, Int.max] {
            var set = original
            XCTAssertFalse(set.placeManualLandmark(at: index, point: .init(x: 0.4, y: 0.4)))
            XCTAssertEqual(try encoded(set), before)
        }
        for point in [ImagePoint(x: .nan, y: 0.5), .init(x: 0.5, y: .infinity),
                      .init(x: -0.01, y: 0.5), .init(x: 1, y: 0.5), .init(x: 0.5, y: 1)] {
            var set = original
            XCTAssertFalse(set.placeManualLandmark(at: 0, point: point))
            XCTAssertEqual(try encoded(set), before)
        }
    }

    func testMalformedIdentifiersNeverMutateTheSet() throws {
        for identifiers in [["", "B"], ["A", "A"], ["A", " \n"]] {
            var set = SyntheticFixtures.scene().landmarks
            set.origin = .model
            set.modelVersion = "retained-model"
            for index in set.points.indices { set.points[index].id = identifiers[index] }
            let before = try encoded(set)
            XCTAssertFalse(set.placeManualLandmark(at: 0, point: .init(x: 0.4, y: 0.4)))
            XCTAssertEqual(try encoded(set), before)
        }
    }
}

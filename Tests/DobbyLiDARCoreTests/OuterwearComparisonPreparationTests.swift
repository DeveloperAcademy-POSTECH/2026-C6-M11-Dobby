import XCTest
@testable import DobbyLiDARCore

final class OuterwearComparisonPreparationTests: XCTestCase {
    private func prediction(_ degrees: Int) throws -> GarmentOrientationPrediction {
        try .init(probabilities: Dictionary(uniqueKeysWithValues: [0, 90, 180, 270].map {
            ($0, $0 == degrees ? 1.0 : 0.0)
        }))
    }

    func testRechecksIncorrectQuarterTurnBeforeClassifyingSuppliedHoodie() throws {
        // Observed failure: the first 90-degree correction turned a hoodie
        // upside down; that image predicted another 180, then upright at 270.
        var requested: [ImageOrientation] = []
        let result = try GarmentOrientationResolutionPolicy.resolve { orientation in
            requested.append(orientation)
            return try prediction([90, 180, 0][requested.count - 1])
        }
        XCTAssertEqual(requested, [.up, .right, .left])
        XCTAssertEqual(result.orientation, .left)
        XCTAssertEqual(result.attempts.map(\.prediction.correction.rawValue), [90, 180, 0])
        XCTAssertEqual(result.attempts.map(\.orientation), requested)
    }

    func testAlreadyUprightDoesNotRequestExtraPrediction() throws {
        var calls = 0
        let result = try GarmentOrientationResolutionPolicy.resolve { orientation in
            calls += 1
            XCTAssertEqual(orientation, .up)
            return try prediction(0)
        }
        XCTAssertEqual(result.orientation, .up)
        XCTAssertEqual(calls, 1)
    }

    func testConsistentQuarterTurnNeedsOneVerification() throws {
        var calls = 0
        let result = try GarmentOrientationResolutionPolicy.resolve { _ in
            calls += 1
            return try prediction(calls == 1 ? 90 : 0)
        }
        XCTAssertEqual(result.orientation, .right)
        XCTAssertEqual(calls, 2)
    }

    func testCaptureComposesEveryDeviceOrientationBeforeVerification() throws {
        for device in ImageOrientation.allCases {
            var requested: [ImageOrientation] = []
            let result = try GarmentOrientationResolutionPolicy.resolve(startingAt: device) { orientation in
                requested.append(orientation)
                return try prediction([90, 180, 0][requested.count - 1])
            }
            let afterFirst = GarmentOrientationTransform.composed(device: device, correction: .clockwise90)
            let verified = GarmentOrientationTransform.composed(device: device, correction: .clockwise270)
            XCTAssertEqual(requested, [device, afterFirst, verified])
            XCTAssertEqual(result.orientation, verified)
            XCTAssertEqual(result.attempts.last?.prediction.correction, .upright)
            let data = try JSONEncoder().encode(result)
            XCTAssertEqual(try JSONDecoder().decode(GarmentOrientationResolution.self, from: data), result)
        }
    }

    func testCaptureCycleCannotSilentlyUseFirstCorrectionAsFinalOrientation() throws {
        for device in ImageOrientation.allCases {
            var count = 0
            XCTAssertThrowsError(try GarmentOrientationResolutionPolicy.resolve(startingAt: device) { _ in
                count += 1
                return try prediction(count == 1 ? 180 : 180)
            }) { error in
                let rejection = error as? GarmentOrientationResolutionError
                XCTAssertEqual(rejection?.attempts.first?.orientation, device)
                XCTAssertEqual(rejection?.attempts.count, 2)
                XCTAssertEqual(rejection?.automaticMeasurementFailureCause, .garmentOrientationUnverified)
            }
            XCTAssertEqual(count, 2)
        }
    }

    func testContradictoryDirectionsStopWithoutPickingACategory() throws {
        var calls = 0
        XCTAssertThrowsError(try GarmentOrientationResolutionPolicy.resolve { _ in
            calls += 1
            return try prediction(calls == 1 ? 90 : 270)
        }) { error in
            XCTAssertEqual((error as? GarmentOrientationResolutionError)?.attempts.count, 2)
        }
        XCTAssertEqual(calls, 2)
    }

    func testUnsettledDirectionsStopAfterThreePredictions() throws {
        var calls = 0
        XCTAssertThrowsError(try GarmentOrientationResolutionPolicy.resolve { _ in
            calls += 1
            return try prediction(90)
        }) { XCTAssertTrue($0 is GarmentOrientationResolutionError) }
        XCTAssertEqual(calls, 3)
    }

    func testPredictionFailurePropagatesWithoutRetry() throws {
        var calls = 0
        XCTAssertThrowsError(try GarmentOrientationResolutionPolicy.resolve { _ in
            calls += 1
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testAutomaticTargetsMatchCaptureForEveryClassifierLabel() throws {
        let expected: Set<String> = ["Blazer", "Jacket", "Coat", "Denim Jacket", "Sports Jacket", "Hoodie", "Sweater", "Polo"]
        for label in GarmentClassificationCategory.allCases.map(\.rawValue) {
            let scores: [GarmentClassificationScore] = [.init(label: label, confidence: 0.8)]
            let route = GarmentClassifierRoutingPolicy.route(scores: scores, minimumConfidence: 0.10, minimumCrossKindMargin: 0.01)
            if expected.contains(label) {
                XCTAssertEqual(try OuterwearComparisonClassificationPolicy.category(route: route, scores: scores), label)
            } else {
                XCTAssertThrowsError(try OuterwearComparisonClassificationPolicy.category(route: route, scores: scores)) { error in
                    let rejection = error as? OuterwearComparisonClassificationError
                    XCTAssertEqual(rejection?.route, route)
                    XCTAssertEqual(rejection?.scores, scores)
                    XCTAssertTrue(error.localizedDescription.contains(label))
                    XCTAssertFalse(error.localizedDescription.contains("자동 실측은 아직 지원하지"))
                }
            }
        }
    }

    func testUncertainHoodieIsExplainedWithoutBypassingTheExistingGate() throws {
        let scores: [GarmentClassificationScore] = [.init(label: "Hoodie", confidence: 0.401),
            .init(label: "Shirt", confidence: 0.4)]
        let route = GarmentClassifierRoutingPolicy.route(scores: scores, minimumConfidence: 0.10, minimumCrossKindMargin: 0.01)
        XCTAssertThrowsError(try OuterwearComparisonClassificationPolicy.category(route: route, scores: scores)) { error in
            XCTAssertTrue(error.localizedDescription.contains("구분이 충분하지"))
            XCTAssertTrue(error.localizedDescription.contains("Hoodie 0.401"))
            XCTAssertTrue(error.localizedDescription.contains("Shirt 0.400"))
        }
    }
}

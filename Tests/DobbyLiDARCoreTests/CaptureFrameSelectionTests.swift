import XCTest
@testable import DobbyLiDARCore

final class CaptureFrameSelectionTests: XCTestCase {
    private func quality(_ timestamp: Double = 1, coverage: Double = 1,
                         high: Double? = 1, speed: Double? = 0,
                         angular: Double? = 0, tracking: Bool = true) -> CaptureFrameQuality {
        CaptureFrameQuality(timestamp: timestamp, validDepthCoverage: coverage,
                            highConfidenceCoverage: high, validDepthSampleCount: 100,
                            trackingNormal: tracking, translationSpeedMetersPerSecond: speed,
                            angularSpeedRadiansPerSecond: angular)
    }

    func testQueuedPreShutterFrameAndExactBoundaryCannotWin() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100, minimumFrameTimestamp: 1)
        // AR source time and arrival uptime intentionally have different origins.
        XCTAssertFalse(selector.consider(quality(0.9), requestID: requestID, now: 100))
        XCTAssertFalse(selector.consider(quality(1), requestID: requestID, now: 100.1))
        XCTAssertNil(selector.windowEndsAt)
        XCTAssertTrue(selector.consider(quality(1.01), requestID: requestID, now: 100.2))
        let summary = try XCTUnwrap(selector.finish(requestID: requestID, now: 100.55))
        XCTAssertEqual(summary.selectedFrameTimestamp, 1.01)
        XCTAssertEqual(summary.eligibleCandidateCount, 1)
        XCTAssertEqual(summary.observedFrameCount, 3)
    }

    func testInvalidSourceBoundaryDoesNotSilentlyDisablePreShutterFiltering() {
        for boundary in [Double.nan, .infinity, -.infinity, -1] {
            let requestID = UUID()
            var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100,
                                                 minimumFrameTimestamp: boundary)
            XCTAssertFalse(selector.consider(quality(2), requestID: requestID, now: 100))
            XCTAssertNil(selector.finish(requestID: requestID, now: 101))
        }
    }

    func testNewRequestHasIndependentShutterBoundaryAndIgnoresCancelledRequest() throws {
        let oldID = UUID(), newID = UUID()
        var old = CaptureFrameSelector(requestID: oldID, startedAt: 100, minimumFrameTimestamp: 1)
        _ = old.consider(quality(1.1), requestID: oldID, now: 100.1)
        old.cancel(requestID: oldID)
        var current = CaptureFrameSelector(requestID: newID, startedAt: 100.2, minimumFrameTimestamp: 1.2)
        XCTAssertFalse(current.consider(quality(1.15), requestID: newID, now: 100.3))
        XCTAssertFalse(current.consider(quality(1.3), requestID: oldID, now: 100.3))
        XCTAssertNil(old.finish(requestID: oldID, now: 101))
        XCTAssertTrue(current.consider(quality(1.3), requestID: newID, now: 100.3))
        XCTAssertEqual(try XCTUnwrap(current.finish(requestID: newID, now: 100.65)).selectedFrameTimestamp, 1.3)
    }

    func testSelectsBetterDepthAndConfidenceWithinBoundedWindow() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        XCTAssertTrue(selector.consider(quality(1, coverage: 0.6, high: 0.3), requestID: requestID, now: 100))
        XCTAssertTrue(selector.consider(quality(1.1, coverage: 0.9, high: 0.8), requestID: requestID, now: 100.1))
        XCTAssertFalse(selector.consider(quality(1.2, coverage: 0.7, high: 0.5), requestID: requestID, now: 100.2))
        XCTAssertNil(selector.finish(requestID: requestID, now: 100.3))
        let summary = try XCTUnwrap(selector.finish(requestID: requestID, now: 100.35))
        XCTAssertEqual(summary.selectedFrameTimestamp, 1.1)
        XCTAssertEqual(summary.eligibleCandidateCount, 3)
        XCTAssertEqual(summary.observedFrameCount, 3)
        XCTAssertEqual(summary.waitingDurationSeconds, 0.35, accuracy: 1e-8)
        XCTAssertEqual(summary.selectionWindowSeconds, 0.35)
        XCTAssertTrue(summary.selectedQuality.isEligible)
    }

    func testFrameAfterWindowCannotReplaceEarlierWinner() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        _ = selector.consider(quality(1, coverage: 0.8, high: 0.7), requestID: requestID, now: 100)
        XCTAssertFalse(selector.consider(quality(1.4), requestID: requestID, now: 100.4))
        XCTAssertEqual(try XCTUnwrap(selector.finish(requestID: requestID, now: 100.4)).selectedFrameTimestamp, 1)
    }

    func testQuieterFrameWinsOverSmallDepthCoverageIncreaseForTranslationOrRotation() throws {
        for moving in [quality(1, speed: 0.09), quality(1, angular: 11 * .pi / 180)] {
            let requestID = UUID()
            var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
            XCTAssertTrue(selector.consider(moving, requestID: requestID, now: 100))
            let quieter = quality(1.1, coverage: 0.9, high: 0.85)
            XCTAssertTrue(selector.consider(quieter, requestID: requestID, now: 100.1))
            // Improving stability changes only the winner, not the shutter window.
            XCTAssertEqual(selector.windowEndsAt, 100.35)
            let summary = try XCTUnwrap(selector.finish(requestID: requestID, now: 100.35))
            XCTAssertEqual(summary.selectedFrameTimestamp, quieter.timestamp)
            XCTAssertEqual(summary.waitingDurationSeconds, 0.35, accuracy: 1e-8)
        }
    }

    func testSubstantiallyBetterDepthCanStillWinWhenMotionRemainsEligible() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        XCTAssertTrue(selector.consider(quality(1, coverage: 0.4, high: 0.3),
                                        requestID: requestID, now: 100))
        XCTAssertTrue(selector.consider(quality(1.1, speed: 0.08), requestID: requestID, now: 100.1))
        XCTAssertEqual(try XCTUnwrap(selector.finish(requestID: requestID, now: 100.35))
            .selectedFrameTimestamp, 1.1)
    }

    func testUnknownMotionAloneStillCompletesInExistingWindow() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        let unknown = quality(speed: nil, angular: nil)
        XCTAssertTrue(selector.consider(unknown, requestID: requestID, now: 100))
        XCTAssertEqual(selector.windowEndsAt, 100.35)
        let summary = try XCTUnwrap(selector.finish(requestID: requestID, now: 100.35))
        XCTAssertEqual(summary.selectedFrameTimestamp, unknown.timestamp)
        XCTAssertFalse(summary.selectedQuality.motionKnown)
        XCTAssertEqual(summary.waitingDurationSeconds, 0.35, accuracy: 1e-8)
        XCTAssertEqual(summary.selectionWindowSeconds, 0.35)
    }

    func testQuieterCandidateAtWindowBoundaryCannotExtendCapture() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        let moving = quality(1, speed: 0.09)
        XCTAssertTrue(selector.consider(moving, requestID: requestID, now: 100))
        XCTAssertFalse(selector.consider(quality(1.1), requestID: requestID, now: 100.35))
        XCTAssertEqual(try XCTUnwrap(selector.finish(requestID: requestID, now: 100.35))
            .selectedFrameTimestamp, moving.timestamp)
    }

    func testTimerCanCompleteWithoutAnotherCameraFrame() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        _ = selector.consider(quality(), requestID: requestID, now: 100)
        XCTAssertNotNil(selector.finish(requestID: requestID, now: 100.35))
        XCTAssertNil(selector.finish(requestID: requestID, now: 100.5))
        XCTAssertFalse(selector.consider(quality(2), requestID: requestID, now: 100.6))
    }

    func testNoEligibleCandidateDoesNotStartWindowOrProduceSnapshot() {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        XCTAssertFalse(selector.consider(quality(tracking: false), requestID: requestID, now: 100))
        XCTAssertFalse(selector.consider(quality(2, speed: 0.2), requestID: requestID, now: 101))
        XCTAssertFalse(selector.consider(quality(3, angular: .pi), requestID: requestID, now: 102))
        XCTAssertNil(selector.windowEndsAt)
        XCTAssertNil(selector.finish(requestID: requestID, now: 104))
        XCTAssertEqual(selector.observedFrameCount, 3)
        XCTAssertEqual(selector.eligibleCandidateCount, 0)
        // The adapter's existing independent 4 s deadline cancels this request.
        selector.cancel(requestID: requestID)
        XCTAssertFalse(selector.consider(quality(4), requestID: requestID, now: 104.1))
    }

    func testWindowStartsAtFirstUsableCandidateAndIncludesInitialWaitInSummary() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        _ = selector.consider(quality(1, tracking: false), requestID: requestID, now: 100)
        _ = selector.consider(quality(3), requestID: requestID, now: 102)
        XCTAssertEqual(selector.windowEndsAt, 102.35)
        let summary = try XCTUnwrap(selector.finish(requestID: requestID, now: 102.35))
        XCTAssertEqual(summary.waitingDurationSeconds, 2.35, accuracy: 1e-8)
        XCTAssertEqual(summary.eligibleCandidateCount, 1)
    }

    func testCancelledRequestAndItsDelayedTimerCannotAffectNewRequest() throws {
        let oldID = UUID(), newID = UUID()
        var old = CaptureFrameSelector(requestID: oldID, startedAt: 100)
        _ = old.consider(quality(), requestID: oldID, now: 100)
        old.cancel(requestID: oldID)
        XCTAssertNil(old.finish(requestID: oldID, now: 101))
        var current = CaptureFrameSelector(requestID: newID, startedAt: 100.1)
        XCTAssertFalse(current.consider(quality(1.1), requestID: oldID, now: 100.2))
        XCTAssertTrue(current.consider(quality(1.2), requestID: newID, now: 100.2))
        current.cancel(requestID: oldID)
        XCTAssertNil(current.finish(requestID: oldID, now: 101))
        let summary = try XCTUnwrap(current.finish(requestID: newID, now: 101))
        XCTAssertEqual(summary.selectedFrameTimestamp, 1.2)
        XCTAssertEqual(summary.eligibleCandidateCount, 1)
    }

    func testNonfiniteNegativeDuplicateAndReorderedFrameTimesCannotWin() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        _ = selector.consider(quality(10, coverage: 0.7, high: 0.6), requestID: requestID, now: 100)
        for timestamp in [Double.nan, .infinity, -.infinity, -1, 10, 9] {
            XCTAssertFalse(selector.consider(quality(timestamp), requestID: requestID, now: 100.1))
        }
        XCTAssertEqual(try XCTUnwrap(selector.finish(requestID: requestID, now: 100.35)).selectedFrameTimestamp, 10)
    }

    func testInvalidOrReversedMonotonicClockCannotComplete() {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        _ = selector.consider(quality(), requestID: requestID, now: 100.1)
        for now in [Double.nan, .infinity, -1, 100, 99] {
            XCTAssertFalse(selector.consider(quality(2), requestID: requestID, now: now))
            XCTAssertNil(selector.finish(requestID: requestID, now: now))
        }
        for startedAt in [Double.nan, .infinity, -1] {
            var invalid = CaptureFrameSelector(requestID: requestID, startedAt: startedAt)
            XCTAssertFalse(invalid.consider(quality(), requestID: requestID, now: 100))
            XCTAssertNil(invalid.finish(requestID: requestID, now: 101))
        }
    }

    func testMotionAndTrackingEligibilityUsesExistingThresholds() {
        XCTAssertFalse(quality(speed: 0.10).isEligible)
        XCTAssertFalse(quality(angular: 12 * .pi / 180).isEligible)
        XCTAssertFalse(quality(tracking: false).isEligible)
        for value in [Double.nan, .infinity, -1] {
            XCTAssertFalse(quality(speed: value).isEligible)
            XCTAssertFalse(quality(angular: value).isEligible)
        }
        XCTAssertTrue(quality(speed: 0.099, angular: 11 * .pi / 180).isEligible)
    }

    func testUnknownConfidenceAndMotionAreNotInventedAsHighConfidenceOrSteady() {
        let unknown = quality(high: nil, speed: nil, angular: nil)
        XCTAssertTrue(unknown.isEligible)
        XCTAssertFalse(unknown.motionKnown)
        XCTAssertGreaterThan(quality().score, unknown.score)
        XCTAssertGreaterThan(quality().score, quality(speed: 0.09).score)
        XCTAssertFalse(quality(speed: nil).motionKnown)
        XCTAssertFalse(quality(angular: nil).motionKnown)
        for invalid in [Double.nan, .infinity, -1] {
            XCTAssertFalse(quality(speed: invalid).motionKnown)
            XCTAssertFalse(quality(angular: invalid).motionKnown)
        }
    }

    func testDepthSummaryRejectsInvalidDepthAndUsesAllPixelsAsDenominator() {
        var depth = DepthMap(size: .init(width: 10, height: 10),
                             values: .init(repeating: 1.2, count: 100), confidence: .init(repeating: 2, count: 100))
        for index in 0..<20 { depth.values[index] = 0 }
        for index in 20..<30 { depth.values[index] = .nan }
        for index in 30..<40 { depth.values[index] = 3.1 }
        for index in 40..<50 { depth.confidence?[index] = 1 }
        let result = CaptureFrameQuality.evaluate(depth: depth, timestamp: 1, trackingNormal: true,
                                                  translationSpeedMetersPerSecond: 0, angularSpeedRadiansPerSecond: 0)
        XCTAssertEqual(result.validDepthCoverage, 0.6)
        XCTAssertEqual(result.highConfidenceCoverage, 0.5)
        XCTAssertEqual(result.validDepthSampleCount, 60)
        XCTAssertTrue(result.isEligible)
        depth.confidence?[50] = 3
        let unknown = CaptureFrameQuality.evaluate(depth: depth, timestamp: 1, trackingNormal: true,
                                                   translationSpeedMetersPerSecond: 0, angularSpeedRadiansPerSecond: 0)
        XCTAssertNil(unknown.highConfidenceCoverage)
    }

    func testMalformedDepthAndQualityCannotBeSelected() {
        for depth in [nil, DepthMap(size: .init(width: 0, height: 1), values: [], confidence: nil),
                      DepthMap(size: .init(width: 10, height: 10), values: [1], confidence: [2])] {
            XCTAssertFalse(CaptureFrameQuality.evaluate(depth: depth, timestamp: 1, trackingNormal: true,
                                                        translationSpeedMetersPerSecond: 0,
                                                        angularSpeedRadiansPerSecond: 0).isEligible)
        }
        XCTAssertFalse(quality(coverage: .nan).isEligible)
        XCTAssertFalse(quality(coverage: 0.5, high: 0.6).isEligible)
        XCTAssertFalse(quality(high: .infinity).isEligible)
        var sparse = quality()
        sparse.validDepthSampleCount = 29
        XCTAssertFalse(sparse.isEligible)
    }

    func testSummaryRoundTripsAndEqualScoreKeepsFirstCandidate() throws {
        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        XCTAssertTrue(selector.consider(quality(), requestID: requestID, now: 100))
        XCTAssertFalse(selector.consider(quality(1.1), requestID: requestID, now: 100.1))
        let summary = try XCTUnwrap(selector.finish(requestID: requestID, now: 100.35))
        let roundTrip = try JSONDecoder().decode(CaptureSelectionSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(summary, roundTrip)
        XCTAssertEqual(summary.selectedFrameTimestamp, 1)
        XCTAssertEqual(summary.policyVersion, "depth-confidence-motion-v2")
    }
}

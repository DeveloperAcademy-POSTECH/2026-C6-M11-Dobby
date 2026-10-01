import XCTest
@testable import DobbyLiDARCore

final class LiveReadinessFreshnessGateTests: XCTestCase {
    func testFrozenCameraCannotBeRevivedByLateAnalysis() {
        var gate = LiveReadinessFreshnessGate()
        XCTAssertTrue(gate.recordCamera(timestamp: 10, receivedAt: 100, trackingStable: true, hasDepth: true))
        // No new camera callbacks; currentFrame still points to the frozen frame.
        XCTAssertFalse(gate.acceptAnalysis(timestamp: 10, currentFrameTimestamp: 10,
                                           trackingStable: true, hasDepth: true, now: 101.1))
        XCTAssertTrue(gate.expireIfNeeded(now: 101.1, currentFrameTimestamp: 10))
        XCTAssertFalse(gate.expireIfNeeded(now: 101.4, currentFrameTimestamp: 10))
    }

    func testProcessingLatencyDoesNotExtendTheSourceLifetime() {
        var gate = LiveReadinessFreshnessGate()
        XCTAssertTrue(gate.recordCamera(timestamp: 11.9, receivedAt: 100, trackingStable: true, hasDepth: true))
        XCTAssertTrue(gate.acceptAnalysis(timestamp: 10, currentFrameTimestamp: 11.9,
                                          trackingStable: true, hasDepth: true, now: 100))
        XCTAssertFalse(gate.expireIfNeeded(now: 100.05, currentFrameTimestamp: 11.9))
        // Only 0.1 s of the 2 s budget remained on arrival, not another full 2 s.
        XCTAssertTrue(gate.expireIfNeeded(now: 100.11, currentFrameTimestamp: 11.9))
    }

    func testExpiryBarrierRejectsCompletionAlreadyQueuedBeforeInvalidation() {
        var gate = LiveReadinessFreshnessGate()
        _ = gate.recordCamera(timestamp: 10, receivedAt: 100, trackingStable: true, hasDepth: true)
        XCTAssertTrue(gate.acceptAnalysis(timestamp: 10, currentFrameTimestamp: 10,
                                          trackingStable: true, hasDepth: true, now: 100))
        _ = gate.recordCamera(timestamp: 12.1, receivedAt: 102.1, trackingStable: true, hasDepth: true)
        XCTAssertTrue(gate.expireIfNeeded(now: 102.1, currentFrameTimestamp: 12.1))
        // This result finished on the analysis queue before invalidation, but
        // only reaches the main actor afterward. Its source must stay invalid.
        XCTAssertFalse(gate.acceptAnalysis(timestamp: 12, currentFrameTimestamp: 12.1,
                                           trackingStable: true, hasDepth: true, now: 102.15))
        _ = gate.recordCamera(timestamp: 12.5, receivedAt: 102.5, trackingStable: true, hasDepth: true)
        XCTAssertTrue(gate.acceptAnalysis(timestamp: 12.5, currentFrameTimestamp: 12.5,
                                          trackingStable: true, hasDepth: true, now: 102.6))
    }

    func testMotionOrMissingDepthInvalidatesEarlierAnalysis() {
        for hasDepth in [true, false] {
            var gate = LiveReadinessFreshnessGate()
            _ = gate.recordCamera(timestamp: 10, receivedAt: 100, trackingStable: true, hasDepth: true)
            _ = gate.recordCamera(timestamp: 10.5, receivedAt: 100.5, trackingStable: !hasDepth, hasDepth: hasDepth)
            XCTAssertFalse(gate.acceptAnalysis(timestamp: 10.4, currentFrameTimestamp: 10.5,
                                               trackingStable: true, hasDepth: true, now: 100.6))
            _ = gate.recordCamera(timestamp: 11, receivedAt: 101, trackingStable: true, hasDepth: true)
            XCTAssertFalse(gate.acceptAnalysis(timestamp: 10.5, currentFrameTimestamp: 11,
                                               trackingStable: true, hasDepth: true, now: 101))
            XCTAssertTrue(gate.acceptAnalysis(timestamp: 10.9, currentFrameTimestamp: 11,
                                              trackingStable: true, hasDepth: true, now: 101))
        }
    }

    func testDuplicateOrReorderedCameraCallbacksCannotRefreshLiveness() {
        var gate = LiveReadinessFreshnessGate()
        _ = gate.recordCamera(timestamp: 10, receivedAt: 100, trackingStable: true, hasDepth: true)
        XCTAssertFalse(gate.recordCamera(timestamp: 10, receivedAt: 100.9, trackingStable: true, hasDepth: true))
        XCTAssertFalse(gate.recordCamera(timestamp: 9.9, receivedAt: 101, trackingStable: true, hasDepth: true))
        XCTAssertFalse(gate.acceptAnalysis(timestamp: 10, currentFrameTimestamp: 10,
                                           trackingStable: true, hasDepth: true, now: 101.1))
    }

    func testResultsAreOrderedAndNeedCurrentTrackingAndDepth() {
        var gate = LiveReadinessFreshnessGate()
        _ = gate.recordCamera(timestamp: 10, receivedAt: 100, trackingStable: true, hasDepth: true)
        XCTAssertFalse(gate.acceptAnalysis(timestamp: 10, currentFrameTimestamp: 10,
                                           trackingStable: false, hasDepth: true, now: 100))
        XCTAssertFalse(gate.acceptAnalysis(timestamp: 10, currentFrameTimestamp: 10,
                                           trackingStable: true, hasDepth: false, now: 100))
        XCTAssertTrue(gate.acceptAnalysis(timestamp: 10, currentFrameTimestamp: 10,
                                          trackingStable: true, hasDepth: true, now: 100))
        for timestamp in [9.9, 10] {
            XCTAssertFalse(gate.acceptAnalysis(timestamp: timestamp, currentFrameTimestamp: 10,
                                               trackingStable: true, hasDepth: true, now: 100.1))
        }
    }

    func testResetAllowsNewSessionTimestamps() {
        var gate = LiveReadinessFreshnessGate()
        _ = gate.recordCamera(timestamp: 10, receivedAt: 100, trackingStable: true, hasDepth: true)
        _ = gate.acceptAnalysis(timestamp: 10, currentFrameTimestamp: 10,
                                trackingStable: true, hasDepth: true, now: 100)
        gate.reset()
        XCTAssertFalse(gate.acceptAnalysis(timestamp: 1, currentFrameTimestamp: 1,
                                           trackingStable: true, hasDepth: true, now: 101))
        _ = gate.recordCamera(timestamp: 1, receivedAt: 101, trackingStable: true, hasDepth: true)
        XCTAssertTrue(gate.acceptAnalysis(timestamp: 1, currentFrameTimestamp: 1,
                                          trackingStable: true, hasDepth: true, now: 101))
    }

    func testInvalidFutureAndOverageTimestampsNeverAppearFresh() {
        for timestamp in [Double.nan, .infinity, -1, 7.9, 10.1] {
            var gate = LiveReadinessFreshnessGate()
            _ = gate.recordCamera(timestamp: 10, receivedAt: 100, trackingStable: true, hasDepth: true)
            XCTAssertFalse(gate.acceptAnalysis(timestamp: timestamp, currentFrameTimestamp: 10,
                                               trackingStable: true, hasDepth: true, now: 100))
        }
        var gate = LiveReadinessFreshnessGate()
        XCTAssertFalse(gate.recordCamera(timestamp: .nan, receivedAt: 100, trackingStable: true, hasDepth: true))
        XCTAssertFalse(gate.recordCamera(timestamp: 10, receivedAt: .infinity, trackingStable: true, hasDepth: true))
        _ = gate.recordCamera(timestamp: 10, receivedAt: 100, trackingStable: true, hasDepth: true)
        XCTAssertFalse(gate.acceptAnalysis(timestamp: 10, currentFrameTimestamp: 10,
                                           trackingStable: true, hasDepth: true, now: 99))
    }
}

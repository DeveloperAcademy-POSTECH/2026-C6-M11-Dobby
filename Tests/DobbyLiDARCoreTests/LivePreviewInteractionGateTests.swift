import XCTest
@testable import DobbyLiDARCore

final class LivePreviewInteractionGateTests: XCTestCase {
    func testOnlyTheActiveSessionMaySubmitPreviewAnalysis() {
        var gate = LivePreviewInteractionGate()
        let current = UUID(), other = UUID()
        XCTAssertFalse(gate.allowsAnalysis(sessionID: current, captureSuspended: false, now: 10))
        gate.reset(sessionID: current)
        XCTAssertTrue(gate.allowsAnalysis(sessionID: current, captureSuspended: false, now: 10))
        XCTAssertFalse(gate.allowsAnalysis(sessionID: other, captureSuspended: false, now: 10))
    }

    func testFocusWindowUsesHostUptimeAndExpiresWithoutATimer() {
        var gate = LivePreviewInteractionGate()
        let session = UUID()
        gate.reset(sessionID: session)
        XCTAssertTrue(gate.prioritize(sessionID: session, duration: 0.6, now: 100))
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 100.59))
        XCTAssertTrue(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 100.6))
    }

    func testLaterInteractionExtendsTheWindowAndAShorterRequestCannotShortenIt() {
        var gate = LivePreviewInteractionGate()
        let session = UUID()
        gate.reset(sessionID: session)
        XCTAssertTrue(gate.prioritize(sessionID: session, duration: 0.6, now: 10))
        XCTAssertTrue(gate.prioritize(sessionID: session, duration: 0.6, now: 10.5))
        XCTAssertFalse(gate.prioritize(sessionID: session, duration: 0.1, now: 10.6))
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 11.09))
        XCTAssertTrue(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 11.1))
    }

    func testActiveDragKeepsPriorityUntilEndThenAddsOnlyAShortTail() {
        var gate = LivePreviewInteractionGate()
        let session = UUID()
        gate.reset(sessionID: session)
        XCTAssertTrue(gate.setExposureAdjustmentActive(true, sessionID: session, now: 10))
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 100))
        XCTAssertTrue(gate.setExposureAdjustmentActive(false, sessionID: session, now: 100))
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 100.19))
        XCTAssertTrue(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 100.2))
    }

    func testDuplicateEndDoesNotKeepPreviewPausedIndefinitely() {
        var gate = LivePreviewInteractionGate()
        let session = UUID()
        gate.reset(sessionID: session)
        XCTAssertFalse(gate.setExposureAdjustmentActive(false, sessionID: session, now: 10))
        XCTAssertTrue(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 10))
        _ = gate.setExposureAdjustmentActive(true, sessionID: session, now: 11)
        _ = gate.setExposureAdjustmentActive(false, sessionID: session, now: 12)
        XCTAssertFalse(gate.setExposureAdjustmentActive(false, sessionID: session, now: 12.19))
        XCTAssertTrue(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 12.2))
    }

    func testNewDragDuringTheTailCannotBeReleasedByTheOldDeadline() {
        var gate = LivePreviewInteractionGate()
        let session = UUID()
        gate.reset(sessionID: session)
        _ = gate.setExposureAdjustmentActive(true, sessionID: session, now: 10)
        _ = gate.setExposureAdjustmentActive(false, sessionID: session, now: 11)
        _ = gate.setExposureAdjustmentActive(true, sessionID: session, now: 11.1)
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 20))
        _ = gate.setExposureAdjustmentActive(false, sessionID: session, now: 20)
        XCTAssertTrue(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 20.2))
    }

    func testEndingADragDoesNotShortenAFocusPriorityWindow() {
        var gate = LivePreviewInteractionGate()
        let session = UUID()
        gate.reset(sessionID: session)
        _ = gate.prioritize(sessionID: session, duration: 0.6, now: 10)
        _ = gate.setExposureAdjustmentActive(true, sessionID: session, now: 10.1)
        _ = gate.setExposureAdjustmentActive(false, sessionID: session, now: 10.2)
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 10.5))
        XCTAssertTrue(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 10.6))
    }

    func testCaptureSuspensionIsIndependentOfGestureAndDeadlineExpiry() {
        var gate = LivePreviewInteractionGate()
        let session = UUID()
        gate.reset(sessionID: session)
        _ = gate.setExposureAdjustmentActive(true, sessionID: session, now: 10)
        _ = gate.setExposureAdjustmentActive(false, sessionID: session, now: 11)
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: true, now: 100))
        XCTAssertTrue(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 100))
        _ = gate.setExposureAdjustmentActive(true, sessionID: session, now: 101)
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 102))
    }

    func testResetDiscardsOldPriorityAndRejectsOldSessionLifecycleCallbacks() {
        var gate = LivePreviewInteractionGate()
        let old = UUID(), current = UUID()
        gate.reset(sessionID: old)
        _ = gate.prioritize(sessionID: old, duration: 50, now: 100)
        _ = gate.setExposureAdjustmentActive(true, sessionID: old, now: 101)
        gate.reset(sessionID: current)
        XCTAssertTrue(gate.allowsAnalysis(sessionID: current, captureSuspended: false, now: 1))
        _ = gate.setExposureAdjustmentActive(true, sessionID: current, now: 2)
        XCTAssertFalse(gate.setExposureAdjustmentActive(false, sessionID: old, now: 200))
        XCTAssertFalse(gate.prioritize(sessionID: old, duration: 50, now: 200))
        XCTAssertFalse(gate.allowsAnalysis(sessionID: current, captureSuspended: false, now: 3))
        _ = gate.setExposureAdjustmentActive(false, sessionID: current, now: 3)
        XCTAssertTrue(gate.allowsAnalysis(sessionID: current, captureSuspended: false, now: 3.2))
        gate.reset(sessionID: nil)
        XCTAssertFalse(gate.allowsAnalysis(sessionID: current, captureSuspended: false, now: 4))
    }

    func testInvalidOrReorderedTimesCannotCreateOrReleasePriority() {
        var gate = LivePreviewInteractionGate()
        let session = UUID()
        gate.reset(sessionID: session)
        for now in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertFalse(gate.prioritize(sessionID: session, duration: 0.6, now: now))
            XCTAssertFalse(gate.setExposureAdjustmentActive(true, sessionID: session, now: now))
            XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: now))
        }
        for duration in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertFalse(gate.prioritize(sessionID: session, duration: duration, now: 10))
        }
        _ = gate.setExposureAdjustmentActive(true, sessionID: session, now: 10)
        XCTAssertFalse(gate.setExposureAdjustmentActive(false, sessionID: session, now: 9))
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 9))
        XCTAssertFalse(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 20))
        _ = gate.setExposureAdjustmentActive(false, sessionID: session, now: 20)
        XCTAssertTrue(gate.allowsAnalysis(sessionID: session, captureSuspended: false, now: 20.2))
    }
}

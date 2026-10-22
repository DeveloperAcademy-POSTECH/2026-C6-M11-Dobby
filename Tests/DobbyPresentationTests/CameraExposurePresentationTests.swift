import XCTest
@testable import Dobby

@MainActor
final class CameraExposurePresentationTests: XCTestCase {
    func testDragBuffersInputsAndReceiptsWithoutPublishingUntilGestureEnd() throws {
        let published = CameraControlState(sessionID: UUID())
        var buffer = CameraControlPresentationBuffer()
        buffer.begin(published: published)
        for revision in 1...240 {
            var controls = buffer.current(published: published)
            controls.requestedExposureBias = Double(revision) / 120
            controls.requestedExposureRevision = UInt64(revision)
            XCTAssertNil(buffer.stage(controls), "Raw input must not invalidate the SwiftUI camera hierarchy.")
            let accepted = CameraHardwareReceipt(revision: UInt64(revision), focusPoint: nil,
                exposureBias: controls.requestedExposureBias)
            XCTAssertNil(buffer.stage(controls.acceptingExposureReceipt(accepted)))
            buffer.begin(published: published) // Repeated begin cannot replace in-flight intent.
        }
        let final = try XCTUnwrap(buffer.end())
        XCTAssertEqual(final.requestedExposureBias, 2)
        XCTAssertEqual(final.exposureBias, 2)
        XCTAssertEqual(final.requestedExposureRevision, 240)
        XCTAssertEqual(buffer.current(published: final), final)
        XCTAssertNil(buffer.end())
    }

    func testFinalReceiptAfterGestureEndPublishesWithoutRevertingRequestedTarget() throws {
        var published = CameraControlState(exposureBias: 0.3, requestedExposureBias: 1.2,
            requestedExposureRevision: 9, settingsRevision: 3)
        var buffer = CameraControlPresentationBuffer()
        buffer.begin(published: published)
        published = try XCTUnwrap(buffer.end())
        let receipt = CameraHardwareReceipt(revision: 4, focusPoint: nil, exposureBias: 1.2)
        let final = try XCTUnwrap(buffer.stage(buffer.current(published: published).acceptingExposureReceipt(receipt)))
        XCTAssertEqual(final.exposureBias, 1.2)
        XCTAssertEqual(final.requestedExposureBias, 1.2)
        XCTAssertEqual(final.requestedExposureRevision, 9)
        XCTAssertEqual(final.settingsRevision, 4)
    }

    func testOlderReceiptCannotReplaceLaterAcceptedEVOrCurrentObservation() {
        let observation = observed(uptime: 30)
        let controls = CameraControlState(hardwareObservation: observation, exposureBias: 0.8,
            requestedExposureBias: 1.2, requestedExposureRevision: 9, settingsRevision: 4)
        let stale = CameraHardwareReceipt(revision: 3, focusPoint: nil, exposureBias: 0)
        XCTAssertEqual(controls.acceptingExposureReceipt(stale), controls)
    }

    func testLateEVReceiptAtCaptureRevisionPreservesNewerFullObservation() {
        let observation = observed(uptime: 30)
        let controls = CameraControlState(hardwareObservation: observation, exposureBias: 0.8,
            requestedExposureBias: 0.8, settingsRevision: 4)
        let late = CameraHardwareReceipt(revision: 4, focusPoint: nil, exposureBias: 0.8)
        XCTAssertEqual(controls.acceptingExposureReceipt(late).hardwareObservation, observation)
        let newer = CameraHardwareReceipt(revision: 5, focusPoint: nil, exposureBias: 1)
        XCTAssertNil(controls.acceptingExposureReceipt(newer).hardwareObservation,
            "A different EV must not retain an older frame's exposure observation.")
    }

    func testFailedLatestRequestReconcilesAcceptedEVAndKeepsInputRevisionForUIKitRollback() throws {
        let controls = CameraControlState(exposureBias: 0, requestedExposureBias: 1.5,
            requestedExposureRevision: 12, settingsRevision: 1)
        var buffer = CameraControlPresentationBuffer()
        buffer.begin(published: .init())
        let failure = CameraHardwareControlError.exposureConfiguration("scripted failure",
            .init(revision: 2, focusPoint: nil, exposureBias: 0.4))
        XCTAssertNil(buffer.stage(controls.reconcilingFailedExposure(failure)))
        let final = try XCTUnwrap(buffer.end())
        XCTAssertEqual(final.requestedExposureBias, 0.4)
        XCTAssertEqual(final.exposureBias, 0.4)
        XCTAssertEqual(final.requestedExposureRevision, 12)
        XCTAssertEqual(final.settingsRevision, 2)
    }

    func testSessionResetDiscardsBufferedGestureAndNewSessionStartsFromItsOwnState() throws {
        let previous = CameraControlState(exposureBias: 1, requestedExposureBias: 1,
            requestedExposureRevision: 20, settingsRevision: 10, sessionID: UUID())
        var buffer = CameraControlPresentationBuffer()
        buffer.begin(published: previous)
        buffer.reset()
        XCTAssertNil(buffer.end())
        let restarted = CameraControlState(sessionID: UUID())
        XCTAssertEqual(buffer.current(published: restarted), restarted)
        XCTAssertEqual(try XCTUnwrap(buffer.stage(restarted)).requestedExposureBias, 0)
    }

    func testDeferredEndKeepsLatestTargetAvailableToAnImmediateShutterAndReceipt() throws {
        let published = CameraControlState(sessionID: UUID())
        var buffer = CameraControlPresentationBuffer()
        buffer.begin(published: published)
        var pending = published
        pending.requestedExposureBias = 1.2
        pending.requestedExposureRevision = 10
        XCTAssertNil(buffer.stage(pending))
        let ending = try XCTUnwrap(buffer.scheduleEnd())
        XCTAssertEqual(buffer.current(published: published).requestedExposureBias, 1.2,
            "The shutter must see the final request before the deferred UI publication.")
        let receipt = CameraHardwareReceipt(revision: 2, focusPoint: nil, exposureBias: 1.2)
        XCTAssertNil(buffer.stage(pending.acceptingExposureReceipt(receipt)))
        let final = try XCTUnwrap(buffer.finishScheduledEnd(ending))
        XCTAssertEqual(final.exposureBias, 1.2)
        XCTAssertEqual(final.requestedExposureBias, 1.2)
    }

    func testOldDeferredEndCannotCloseANewGestureOrReviveStateAfterFocusOrSessionReset() throws {
        let published = CameraControlState(sessionID: UUID())
        var buffer = CameraControlPresentationBuffer()
        buffer.begin(published: published)
        let oldEnd = try XCTUnwrap(buffer.scheduleEnd())
        buffer.begin(published: published)
        XCTAssertNil(buffer.finishScheduledEnd(oldEnd))
        XCTAssertNotNil(buffer.deferred)
        let resetEnd = try XCTUnwrap(buffer.scheduleEnd())
        buffer.reset()
        XCTAssertNil(buffer.finishScheduledEnd(resetEnd))
        XCTAssertNil(buffer.deferred)
    }

    private func observed(uptime: Double) -> CameraHardwareObservation {
        .init(observedAtUptime: uptime, focusMode: .single, exposureMode: .continuous,
            isAdjustingFocus: false, isAdjustingExposure: false,
            lensPosition: 0.4, exposureDurationSeconds: 1.0 / 60, iso: 200, exposureTargetBias: 0.8)
    }
}

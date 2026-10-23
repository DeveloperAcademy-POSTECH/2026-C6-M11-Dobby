import UIKit
import XCTest
@testable import Dobby

/// UIKit routing and feedback checks without a running camera. Successful
/// callbacks and marker drawing do not establish optical autofocus quality.
@MainActor
final class CameraTapFocusTests: XCTestCase {
    func testInteractionInstallsTapAndPanWithoutLongPressAndRemovesBothOnTeardown() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let interaction = CameraPreviewInteraction(view: view)
        let recognizers = try XCTUnwrap(view.gestureRecognizers)
        XCTAssertEqual(recognizers.count, 2)
        let tap = try XCTUnwrap(recognizers.first { $0 is UITapGestureRecognizer } as? UITapGestureRecognizer)
        XCTAssertEqual(tap.numberOfTapsRequired, 1)
        XCTAssertFalse(tap.delaysTouchesBegan)
        XCTAssertFalse(tap.delaysTouchesEnded)
        XCTAssertFalse(tap.cancelsTouchesInView)
        XCTAssertEqual(recognizers.filter { $0 is UIPanGestureRecognizer }.count, 1)
        XCTAssertFalse(recognizers.contains { $0 is UILongPressGestureRecognizer })
        interaction.tearDown()
        XCTAssertTrue(view.gestureRecognizers?.isEmpty ?? true)
    }

    func testEveryTapIncludingSamePointSubmitsARequest() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let interaction = CameraPreviewInteraction(view: view)
        defer { interaction.tearDown() }
        interaction.enabled = true
        interaction.capabilities = .init(focusSupported: true)
        interaction.sensorPoint = { .init(x: Double($0.x / 200), y: Double($0.y / 300)) }
        var received: [ImagePoint] = []
        interaction.onFocus = { point, _ in received.append(point) }

        interaction.focus(at: CGPoint(x: 40, y: 210))
        interaction.focus(at: CGPoint(x: 40, y: 210))
        interaction.focus(at: CGPoint(x: 160, y: 60))
        XCTAssertEqual(received, [.init(x: 0.2, y: 0.7), .init(x: 0.2, y: 0.7), .init(x: 0.8, y: 0.2)])
    }

    func testDisabledAndMeteringOnlyDevicesCannotReportFocus() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let interaction = CameraPreviewInteraction(view: view)
        defer { interaction.tearDown() }
        interaction.sensorPoint = { _ in .init(x: 0.5, y: 0.5) }
        var requests = 0
        interaction.onFocus = { _, _ in requests += 1 }
        interaction.capabilities = .init(focusSupported: true)
        interaction.focus(at: CGPoint(x: 100, y: 150))
        interaction.enabled = true
        interaction.capabilities = .init(focusSupported: false, meteringSupported: true)
        interaction.focus(at: CGPoint(x: 100, y: 150))
        XCTAssertEqual(requests, 0, "Metering support cannot stand in for real focus support.")
    }

    func testCroppedViewportAndInvalidSensorCoordinatesAreRejected() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let interaction = CameraPreviewInteraction(view: view)
        defer { interaction.tearDown() }
        interaction.enabled = true
        interaction.capabilities = .init(focusSupported: true)
        interaction.visibleViewport = CGRect(x: 50, y: 60, width: 100, height: 120)
        var requests: [ImagePoint] = []
        interaction.onFocus = { point, _ in requests.append(point) }
        interaction.sensorPoint = { _ in .init(x: 0.5, y: 0.5) }
        for location in [CGPoint(x: 49, y: 100), .init(x: 100, y: 181), .init(x: CGFloat.nan, y: 100)] {
            interaction.focus(at: location)
        }
        interaction.sensorPoint = { _ in nil }
        interaction.focus(at: CGPoint(x: 100, y: 100))
        interaction.sensorPoint = { _ in .init(x: .nan, y: 0.5) }
        interaction.focus(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(requests.isEmpty)
        interaction.sensorPoint = { _ in .init(x: 0.5, y: 0.5) }
        interaction.focus(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(requests, [.init(x: 0.5, y: 0.5)])
    }

    func testMarkerTracksRequestedPointWithoutExposureAccessibilityActions() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let renderer = CameraFocusIndicatorRenderer(containerView: view)
        defer { renderer.tearDown() }
        renderer.update(point: CGPoint(x: 50, y: 100), requestID: UUID(), reduceMotion: true)
        let marker = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "cameraFocusIndicator" })
        XCTAssertFalse(marker.isHidden)
        XCTAssertEqual(marker.frame, CGRect(x: 18, y: 68, width: 64, height: 64))
        XCTAssertEqual(marker.accessibilityValue, "초점 조절 요청")
        XCTAssertFalse(marker.accessibilityTraits.contains(.adjustable))
        XCTAssertFalse(marker.isUserInteractionEnabled)
        let exposure = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "cameraExposureControl" })
        XCTAssertTrue(exposure.isHidden, "Unsupported exposure must not show an adjustable control.")
        renderer.update(point: CGPoint(x: 150, y: 200), requestID: UUID(), reduceMotion: true)
        XCTAssertEqual(marker.frame, CGRect(x: 118, y: 168, width: 64, height: 64))
        renderer.clear()
        XCTAssertTrue(marker.isHidden)
    }

    func testMarkerOutsideVisibleCropIsCleared() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let renderer = CameraFocusIndicatorRenderer(containerView: view)
        defer { renderer.tearDown() }
        let crop = CGRect(x: 50, y: 60, width: 100, height: 120)
        renderer.update(point: CGPoint(x: 100, y: 100), requestID: UUID(), visibleViewport: crop, reduceMotion: true)
        let marker = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "cameraFocusIndicator" })
        XCTAssertFalse(marker.isHidden)
        renderer.update(point: CGPoint(x: 20, y: 100), requestID: UUID(), visibleViewport: crop, reduceMotion: true)
        XCTAssertTrue(marker.isHidden)
    }

    func testDragDrawsImmediatelyAndFinalValuePrecedesEndWithoutAnotherFocusTap() throws {
        let (view, renderer, interaction, state) = makeExposureFixture()
        defer { withExtendedLifetime(view) { interaction.tearDown(); renderer.tearDown() } }
        let marker = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "cameraExposureControl" })
        var values: [Double] = []
        var events: [String] = []
        var focusRequests = 0
        interaction.onFocus = { _, _ in focusRequests += 1 }
        interaction.onExposure = { value in values.append(value); events.append("value") }
        interaction.onExposureAdjustmentActive = { events.append($0 ? "begin" : "end") }
        XCTAssertTrue(interaction.beginExposure(at: .init(x: 40, y: 450)), "The drag may begin far from the focus box.")
        interaction.changeExposure(translationY: -75)
        XCTAssertEqual(interaction.presentationExposureBias, 0.5, accuracy: 1e-9)
        XCTAssertEqual(marker.accessibilityValue, "EV +0.5", "Feedback cannot wait for a SwiftUI state or sensor receipt.")
        interaction.synchronize(state: state, viewportHeight: 600)
        XCTAssertEqual(interaction.presentationExposureBias, 0.5, accuracy: 1e-9, "An unrelated redraw cannot restore old EV.")
        interaction.endExposure(translationY: -90)
        XCTAssertEqual(try XCTUnwrap(values.last), 0.6, accuracy: 1e-9)
        XCTAssertEqual(events, ["begin", "value", "value", "end"])
        XCTAssertFalse(interaction.isAdjustingExposure)
        XCTAssertEqual(focusRequests, 0, "Finishing a drag must not reset focus or EV as a new tap.")
    }

    func testSubsequentDragStartsFromLatestLocalValueAndTapResetsToNeutral() {
        let (view, renderer, interaction, _) = makeExposureFixture()
        defer { withExtendedLifetime(view) { interaction.tearDown(); renderer.tearDown() } }
        XCTAssertTrue(interaction.beginExposure(at: .init(x: 40, y: 450)))
        interaction.endExposure(translationY: -75)
        XCTAssertTrue(interaction.beginExposure(at: .init(x: 340, y: 450)))
        interaction.endExposure(translationY: -75)
        XCTAssertEqual(interaction.presentationExposureBias, 1, accuracy: 1e-9)
        var focuses = 0
        interaction.onFocus = { _, _ in focuses += 1 }
        interaction.focus(at: .init(x: 200, y: 300))
        XCTAssertEqual(focuses, 1)
        XCTAssertEqual(interaction.presentationExposureBias, 0)
    }

    func testViewportAndSessionChangesCancelDragAndRejectLaterChangedEvents() {
        let (view, renderer, interaction, state) = makeExposureFixture()
        defer { withExtendedLifetime(view) { interaction.tearDown(); renderer.tearDown() } }
        var active: [Bool] = []
        var values: [Double] = []
        interaction.onExposureAdjustmentActive = { active.append($0) }
        interaction.onExposure = { values.append($0) }
        XCTAssertTrue(interaction.beginExposure(at: .init(x: 40, y: 450)))
        interaction.changeExposure(translationY: -30)
        interaction.visibleViewport = CGRect(x: 20, y: 20, width: 300, height: 500)
        interaction.changeExposure(translationY: -90)
        XCTAssertEqual(active, [true, false])
        XCTAssertEqual(values.count, 1)
        XCTAssertFalse(interaction.isAdjustingExposure)
        // A geometry change retires its focus feedback. Establish a fresh tap
        // before testing an independent session interruption.
        interaction.onFocus = { point, requestID in
            var fresh = state
            fresh.focusPoint = point
            fresh.focusRequestID = requestID
            interaction.synchronize(state: fresh, viewportHeight: 500)
        }
        interaction.focus(at: .init(x: 100, y: 100))
        XCTAssertTrue(interaction.beginExposure(at: .init(x: 40, y: 450)))
        let replacement = CameraControlState(sessionID: UUID())
        interaction.synchronize(state: replacement, viewportHeight: 500)
        interaction.changeExposure(translationY: -150)
        XCTAssertEqual(active, [true, false, true, false])
        XCTAssertEqual(values.count, 1)
    }

    func testExposureAccessibilityHas44PointTargetAndUsesSameRequestLifecycle() throws {
        let (view, renderer, interaction, _) = makeExposureFixture()
        defer { withExtendedLifetime(view) { interaction.tearDown(); renderer.tearDown() } }
        let marker = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "cameraExposureControl" })
        XCTAssertFalse(marker.isHidden)
        XCTAssertEqual(marker.frame.width, 44)
        XCTAssertEqual(marker.frame.height, 44)
        XCTAssertTrue(marker.accessibilityTraits.contains(.adjustable))
        XCTAssertFalse(marker.isUserInteractionEnabled, "The marker cannot intercept preview taps.")
        var active: [Bool] = []
        var values: [Double] = []
        interaction.onExposureAdjustmentActive = { active.append($0) }
        interaction.onExposure = { values.append($0) }
        marker.accessibilityIncrement()
        marker.accessibilityIncrement()
        XCTAssertEqual(active, [true, false, true, false])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(try XCTUnwrap(values.last), 0.2, accuracy: 1e-9)
        XCTAssertEqual(marker.accessibilityValue, "EV +0.2")
    }

    func testCoalescedFailureRollbackReconcilesEvenWhenPublishedBiasReturnsToItsOriginalValue() throws {
        let (view, renderer, interaction, state) = makeExposureFixture()
        defer { withExtendedLifetime(view) { interaction.tearDown(); renderer.tearDown() } }
        XCTAssertTrue(interaction.beginExposure(at: .init(x: 40, y: 450)))
        interaction.endExposure(translationY: -150)
        XCTAssertEqual(interaction.presentationExposureBias, 1, accuracy: 1e-9)
        // SwiftUI can combine end's requested EV 1 and its immediate failure
        // rollback EV 0 into one update. EV equality alone misses that event.
        var rollback = state
        rollback.requestedExposureRevision = state.requestedExposureRevision + 1
        XCTAssertEqual(rollback.requestedExposureBias, state.requestedExposureBias)
        interaction.synchronize(state: rollback, viewportHeight: 600)
        XCTAssertEqual(interaction.presentationExposureBias, 0)
        renderer.update(point: .init(x: 200, y: 300), requestID: rollback.focusRequestID!,
            exposureBias: interaction.presentationExposureBias, exposureRange: interaction.capabilities.exposureRange,
            onExposure: { [weak interaction] in interaction?.requestAccessibleExposure($0) }, reduceMotion: true)
        let marker = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "cameraExposureControl" })
        XCTAssertEqual(marker.accessibilityValue, "EV +0.0")
    }

    func testFocusFeedbackExistsBeforeProviderCallbackAndCanStartExposureBeforeItsRender() throws {
        let (view, renderer, interaction, _) = makeExposureFixture()
        defer { withExtendedLifetime(view) { interaction.tearDown(); renderer.tearDown() } }
        var submittedID: UUID?
        interaction.onFocus = { point, requestID in
            let marker = view.subviews.first { $0.accessibilityIdentifier == "cameraFocusIndicator" }
            XCTAssertTrue(renderer.isVisible, "UIKit must draw without waiting for the provider or SwiftUI.")
            XCTAssertEqual(marker?.center, CGPoint(x: 100, y: 180))
            XCTAssertEqual(interaction.focusFeedback()?.requestID, requestID)
            XCTAssertEqual(point, .init(x: 0.25, y: 0.3))
            submittedID = requestID
        }
        interaction.focus(at: .init(x: 100, y: 180))
        XCTAssertNotNil(submittedID)
        XCTAssertTrue(interaction.beginExposure(at: .init(x: 340, y: 450)),
            "Exposure must not wait for the first focus-state render either.")
        interaction.endExposure(translationY: -30)
        XCTAssertEqual(interaction.presentationExposureBias, 0.2, accuracy: 1e-9)
    }

    func testFastTapsKeepLatestImmediateFeedbackAcrossOldAndAcknowledgingRenders() throws {
        let (view, renderer, interaction, initial) = makeExposureFixture()
        defer { withExtendedLifetime(view) { interaction.tearDown(); renderer.tearDown() } }
        var requests: [(ImagePoint, UUID)] = []
        interaction.onFocus = { requests.append(($0, $1)) }
        interaction.focus(at: .init(x: 80, y: 150))
        interaction.focus(at: .init(x: 300, y: 420))
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].1, requests[1].1)
        let shape = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let entered = try XCTUnwrap(shape.animation(forKey: "focusEntrance"))
        var old = initial
        old.focusPoint = requests[0].0; old.focusRequestID = requests[0].1
        interaction.synchronize(state: old, viewportHeight: 600)
        XCTAssertEqual(interaction.focusFeedback()?.requestID, requests[1].1)
        XCTAssertEqual(shape.position, CGPoint(x: 300, y: 420))
        var latest = initial
        latest.focusPoint = requests[1].0; latest.focusRequestID = requests[1].1
        latest.focusStatus = .requested
        interaction.synchronize(state: latest, viewportHeight: 600)
        latest.focusStatus = .accepted
        interaction.synchronize(state: latest, viewportHeight: 600)
        let feedback = try XCTUnwrap(interaction.focusFeedback())
        renderer.update(point: .init(x: 300, y: 420), requestID: feedback.requestID, reduceMotion: false)
        XCTAssertEqual(shape.animation(forKey: "focusEntrance")?.beginTime, entered.beginTime,
            "Provider acknowledgement must not replay the already-started entrance.")
        XCTAssertEqual(shape.position, CGPoint(x: 300, y: 420))
    }

    func testOldNilRedrawCannotErasePendingTapAndFailureCannotBeResurrected() throws {
        let (view, renderer, interaction, initial) = makeExposureFixture()
        defer { withExtendedLifetime(view) { interaction.tearDown(); renderer.tearDown() } }
        var requestID: UUID?
        interaction.onFocus = { _, id in requestID = id }
        interaction.focus(at: .init(x: 100, y: 180))
        var nilRedraw = initial
        nilRedraw.focusPoint = nil; nilRedraw.focusRequestID = nil; nilRedraw.focusStatus = .idle
        interaction.synchronize(state: nilRedraw, viewportHeight: 600)
        XCTAssertTrue(renderer.isVisible)
        XCTAssertEqual(interaction.focusFeedback()?.requestID, requestID)
        var failed = initial
        failed.focusRequestID = try XCTUnwrap(requestID)
        failed.focusStatus = .failed
        interaction.synchronize(state: failed, viewportHeight: 600)
        XCTAssertFalse(renderer.isVisible)
        XCTAssertNil(interaction.focusFeedback())
        failed.focusStatus = .accepted
        interaction.synchronize(state: failed, viewportHeight: 600)
        XCTAssertNil(interaction.focusFeedback(), "An older completion cannot revive a failed tap.")
    }

    func testCancelledLocalTapCannotReturnFromLateProviderState() throws {
        let (view, renderer, interaction, initial) = makeExposureFixture()
        defer { withExtendedLifetime(view) { interaction.tearDown(); renderer.tearDown() } }
        var requestID: UUID?
        interaction.onFocus = { _, id in requestID = id }
        interaction.focus(at: .init(x: 100, y: 180))
        interaction.invalidateFocusFeedback()
        var late = initial
        late.focusRequestID = try XCTUnwrap(requestID)
        late.focusStatus = .accepted
        interaction.synchronize(state: late, viewportHeight: 600)
        XCTAssertNil(interaction.focusFeedback())
        XCTAssertFalse(renderer.isVisible)
    }

    func testFocusEntranceScalesAroundTapAndReduceMotionKeepsStableTargets() throws {
        let view = UIView(frame: .init(x: 0, y: 0, width: 400, height: 600))
        let renderer = CameraFocusIndicatorRenderer(containerView: view)
        defer { renderer.tearDown() }
        renderer.update(point: .init(x: 300, y: 420), requestID: UUID(), reduceMotion: false)
        let shape = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        XCTAssertEqual(shape.bounds, CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(shape.position, CGPoint(x: 300, y: 420))
        let entrance = try XCTUnwrap(shape.animation(forKey: "focusEntrance") as? CABasicAnimation)
        XCTAssertEqual(entrance.keyPath, "transform.scale")
        XCTAssertGreaterThan(try XCTUnwrap(entrance.fromValue as? NSNumber).doubleValue, 1)
        XCTAssertEqual(try XCTUnwrap(entrance.toValue as? NSNumber).doubleValue, 1)
        let marker = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == "cameraFocusIndicator" })
        XCTAssertEqual(marker.frame, CGRect(x: 268, y: 388, width: 64, height: 64))
        renderer.update(point: .init(x: 100, y: 180), requestID: UUID(), reduceMotion: true)
        XCTAssertNil(shape.animation(forKey: "focusEntrance"))
        XCTAssertEqual(marker.frame, CGRect(x: 68, y: 148, width: 64, height: 64))
    }

    private func makeExposureFixture() -> (UIView, CameraFocusIndicatorRenderer, CameraPreviewInteraction, CameraControlState) {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let renderer = CameraFocusIndicatorRenderer(containerView: view)
        let interaction = CameraPreviewInteraction(view: view)
        let range = CameraExposureRange(minimum: -2, maximum: 2)!
        let state = CameraControlState(focusPoint: .init(x: 0.5, y: 0.5), focusRequestID: UUID(),
            focusStatus: .accepted, sessionID: UUID())
        interaction.enabled = true
        interaction.renderer = renderer
        interaction.capabilities = .init(focusSupported: true, exposureRange: range)
        interaction.visibleViewport = view.bounds
        interaction.sensorPoint = { .init(x: Double($0.x / 400), y: Double($0.y / 600)) }
        interaction.onExposure = { _ in }
        interaction.synchronize(state: state, viewportHeight: 600)
        renderer.update(point: CGPoint(x: 200, y: 300), requestID: state.focusRequestID!,
            exposureRange: range, onExposure: { [weak interaction] in interaction?.requestAccessibleExposure($0) },
            reduceMotion: true)
        return (view, renderer, interaction, state)
    }
}

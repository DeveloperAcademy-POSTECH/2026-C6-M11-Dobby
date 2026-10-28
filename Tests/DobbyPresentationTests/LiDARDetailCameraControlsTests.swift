import XCTest
@testable import Dobby

/// Shared-panel integration with a test-owned receipt source. These tests do
/// not establish physical exposure settling, camera brightness or accuracy.
@MainActor
final class LiDARDetailCameraControlsTests: XCTestCase {
    func testExposureCapabilitiesAndAcceptedReceiptReuseTheExistingCamera() async throws {
        let camera = ReceiptCamera()
        camera.returnedExposure = 0.75
        let controls = LiDARDetailCameraControls(camera: camera)
        let capabilities = try await controls.capabilities()
        XCTAssertEqual(capabilities.exposure, .init(minimum: -2, maximum: 2))
        XCTAssertEqual(capabilities.exposureBias, 0)
        XCTAssertNil(capabilities.zoom)
        XCTAssertNil(capabilities.zoomFactor)
        let accepted = try await controls.apply(.exposure(1))
        XCTAssertEqual(camera.received, [1])
        XCTAssertEqual(accepted, 0.75, "Return the accepted receipt, not the menu's requested 1 EV")
    }

    func testUnsupportedZoomAndInvalidInputNeverSubmitAnExposure() async {
        let camera = ReceiptCamera()
        let controls = LiDARDetailCameraControls(camera: camera)
        for request in [DetailCameraControlRequest.zoom(2), .exposure(.nan), .exposure(.infinity)] {
            do {
                _ = try await controls.apply(request)
                XCTFail("Unsupported/invalid control must fail")
            } catch let error as DetailCameraControlFailure {
                if case .zoom = request { XCTAssertEqual(error, .unsupported) }
                else { XCTAssertEqual(error, .invalidValue) }
            } catch { XCTFail("Unexpected failure: \(error)") }
        }
        XCTAssertTrue(camera.received.isEmpty)
    }

    func testClampsRequestAndRejectsInvalidAcceptedValues() async throws {
        let camera = ReceiptCamera()
        let controls = LiDARDetailCameraControls(camera: camera)
        camera.returnedExposure = 1.9
        let accepted = try await controls.apply(.exposure(5))
        XCTAssertEqual(camera.received, [2])
        XCTAssertEqual(accepted, 1.9)
        for invalid in [Double.nan, .infinity, 2.1] {
            camera.returnedExposure = invalid
            do {
                _ = try await controls.apply(.exposure(1))
                XCTFail("A malformed hardware receipt must not populate the shared menu")
            } catch let error as DetailCameraControlFailure { XCTAssertEqual(error, .deviceFailure) }
            catch { XCTFail("Unexpected failure: \(error)") }
        }
    }

    func testSessionChangeRejectsAnOtherwiseSuccessfulLateReceipt() async {
        let started = expectation(description: "menu request submitted")
        let camera = ReceiptCamera()
        camera.suspendNext = true
        camera.started = started
        let controls = LiDARDetailCameraControls(camera: camera)
        let pending = Task { try await controls.apply(.exposure(0.5)) }
        await fulfillment(of: [started], timeout: 2)
        camera.snapshot.sessionID = UUID()
        camera.finish(0.5)
        do {
            _ = try await pending.value
            XCTFail("A stopped/replaced camera cannot accept the preceding session's receipt")
        } catch let error as DetailCameraControlFailure { XCTAssertEqual(error, .unavailable) }
        catch { XCTFail("Unexpected failure: \(error)") }
    }

    func testNewPreviewIntentRejectsLateMenuReceiptInTheSameSession() async {
        let started = expectation(description: "menu request submitted")
        let camera = ReceiptCamera()
        camera.suspendNext = true
        camera.started = started
        let controls = LiDARDetailCameraControls(camera: camera)
        let pending = Task { try await controls.apply(.exposure(1)) }
        await fulfillment(of: [started], timeout: 2)
        // A short tap resets EV or a vertical drag establishes a newer target.
        camera.snapshot.externalRevision += 1
        camera.snapshot.capabilities.exposureBias = 0
        camera.finish(1)
        do {
            _ = try await pending.value
            XCTFail("The newer preview intent must win over the old menu")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected failure: \(error)") }
    }

    func testCancellationDoesNotTurnAReceiptIntoSuccessfulMenuState() async {
        let started = expectation(description: "menu request submitted")
        let camera = ReceiptCamera()
        camera.suspendNext = true
        camera.started = started
        let controls = LiDARDetailCameraControls(camera: camera)
        let pending = Task { try await controls.apply(.exposure(0.5)) }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        camera.finish(0.5)
        do {
            _ = try await pending.value
            XCTFail("Cancellation must remain cancellation even after hardware accepted the request")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected failure: \(error)") }
    }

    func testExternalTapClearsQueuedMenuValuesAndPreservesRatioSelection() async {
        let started = expectation(description: "first menu request submitted")
        let camera = ReceiptCamera()
        camera.suspendNext = true
        camera.started = started
        let options = DetailCameraOptions(controller: LiDARDetailCameraControls(camera: camera))
        options.photoAspectRatio = .sixteenNine
        options.synchronizeExternalState(capabilities: camera.snapshot.capabilities)
        options.requestExposure(0.5)
        await fulfillment(of: [started], timeout: 2)
        options.requestExposure(1)
        XCTAssertTrue(options.isApplying)
        camera.snapshot.externalRevision += 1
        camera.snapshot.capabilities.exposureBias = 0
        options.synchronizeExternalState(capabilities: camera.snapshot.capabilities, invalidatePendingRequests: true)
        camera.finish(0.5)
        // A queued Task must observe cancellation before it can submit 1 EV.
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(camera.received, [0.5])
        XCTAssertEqual(options.appliedExposure, 0)
        XCTAssertNil(options.requested)
        XCTAssertNil(options.failure)
        XCTAssertFalse(options.isApplying)
        XCTAssertEqual(options.photoAspectRatio, .sixteenNine)
    }

    func testPassiveReceiptSynchronizationDoesNotCancelTheCurrentMenuRequest() async {
        let started = expectation(description: "menu request submitted")
        let camera = ReceiptCamera()
        camera.suspendNext = true
        camera.started = started
        let options = DetailCameraOptions(controller: LiDARDetailCameraControls(camera: camera))
        options.synchronizeExternalState(capabilities: camera.snapshot.capabilities)
        let pending = Task { await options.apply(.exposure(0.8)) }
        await fulfillment(of: [started], timeout: 2)
        camera.snapshot.capabilities.exposureBias = 0.2
        options.synchronizeExternalState(capabilities: camera.snapshot.capabilities)
        XCTAssertTrue(options.isApplying)
        XCTAssertEqual(options.appliedExposure, 0.2)
        camera.finish(0.75)
        await pending.value
        XCTAssertEqual(options.appliedExposure, 0.75)
        XCTAssertNil(options.failure)
        XCTAssertFalse(options.isApplying)
    }

    func testExternalIntentHookCancelsQueueBeforeDeferredStateSynchronization() async {
        let started = expectation(description: "first menu EV is awaiting its receipt")
        let resubmitted = expectation(description: "an obsolete queued menu EV must never be submitted")
        resubmitted.isInverted = true
        let camera = ReceiptCamera()
        camera.snapshot.capabilities.exposureBias = 0.25
        camera.suspendNext = true
        camera.started = started
        camera.subsequentSubmission = resubmitted
        let options = DetailCameraOptions(controller: LiDARDetailCameraControls(camera: camera))
        options.photoAspectRatio = .square
        options.synchronizeExternalState(capabilities: camera.snapshot.capabilities)
        options.requestExposure(0.5)
        await fulfillment(of: [started], timeout: 2)
        options.requestExposure(1.5)

        // The production hook runs synchronously BEFORE the new tap/pan's
        // external revision and hardware command. No Combine sync has run yet.
        options.invalidatePendingRequestsForExternalIntent()
        XCTAssertFalse(options.isApplying)
        XCTAssertNil(options.requested)
        XCTAssertEqual(options.appliedExposure, 0.25)
        XCTAssertEqual(options.capabilities, camera.snapshot.capabilities)
        XCTAssertEqual(options.photoAspectRatio, .square)
        camera.snapshot.externalRevision += 1
        camera.snapshot.capabilities.exposureBias = 0
        camera.finish(0.5)
        await fulfillment(of: [resubmitted], timeout: 0.1)
        XCTAssertEqual(camera.received, [0.5])
        XCTAssertEqual(options.appliedExposure, 0.25, "A late menu receipt cannot restore its value")
        XCTAssertNil(options.failure)

        // The existing deferred receipt sync remains responsible for showing
        // the newly accepted preview value after the synchronous cancellation.
        options.synchronizeExternalState(capabilities: camera.snapshot.capabilities)
        XCTAssertEqual(options.appliedExposure, 0)
    }

    func testIdleExternalIntentHookPreservesStateWithoutInvalidatingTheModel() async {
        let camera = ReceiptCamera()
        let options = DetailCameraOptions(controller: LiDARDetailCameraControls(camera: camera))
        options.synchronizeExternalState(capabilities: camera.snapshot.capabilities)
        options.photoAspectRatio = .sixteenNine
        await options.apply(.exposure(.nan))
        XCTAssertEqual(options.failure, .invalidValue)
        options.invalidatePendingRequestsForExternalIntent()
        options.invalidatePendingRequestsForExternalIntent()
        XCTAssertEqual(options.failure, .invalidValue)
        XCTAssertEqual(options.capabilities, camera.snapshot.capabilities)
        XCTAssertEqual(options.appliedExposure, 0)
        XCTAssertEqual(options.photoAspectRatio, .sixteenNine)
        XCTAssertFalse(options.isApplying)
        XCTAssertTrue(camera.received.isEmpty)
    }

    func testUnavailableCameraClearsAppliedValuesWithoutLosingTheChosenRatio() async throws {
        let camera = ReceiptCamera()
        let options = DetailCameraOptions(controller: LiDARDetailCameraControls(camera: camera))
        options.synchronizeExternalState(capabilities: camera.snapshot.capabilities)
        options.photoAspectRatio = .square
        camera.snapshot = .unavailable
        options.synchronizeExternalState(capabilities: camera.snapshot.capabilities, invalidatePendingRequests: true)
        XCTAssertNil(options.capabilities.exposure)
        XCTAssertNil(options.appliedExposure)
        XCTAssertNil(options.appliedZoom)
        XCTAssertFalse(options.isApplying)
        XCTAssertEqual(options.photoAspectRatio, .square)
        await options.apply(.exposure(1))
        XCTAssertEqual(options.failure, .unsupported)
        XCTAssertTrue(camera.received.isEmpty)
    }

    func testReleasedCameraCannotBeKeptAliveByTheOptionsAdapter() async throws {
        var camera: ReceiptCamera? = ReceiptCamera()
        weak var released = camera
        let controls = LiDARDetailCameraControls(camera: try XCTUnwrap(camera))
        camera = nil
        XCTAssertNil(released)
        let capabilities = try await controls.capabilities()
        XCTAssertNil(capabilities.exposure)
        do {
            _ = try await controls.apply(.exposure(1))
            XCTFail("A released camera must not receive an exposure")
        } catch let error as DetailCameraControlFailure { XCTAssertEqual(error, .unavailable) }
    }
}

@MainActor
private final class ReceiptCamera: LiDARDetailCameraSource {
    var snapshot = LiDARDetailCameraSnapshot(sessionID: UUID(), externalRevision: 0,
        capabilities: .init(exposure: .init(minimum: -2, maximum: 2), exposureBias: 0))
    var detailCameraSnapshot: LiDARDetailCameraSnapshot { snapshot }
    private(set) var received: [Double] = []
    var returnedExposure = 0.0
    var suspendNext = false
    var started: XCTestExpectation?
    var subsequentSubmission: XCTestExpectation?
    private var continuation: CheckedContinuation<Double, Error>?

    func applyDetailExposureBias(_ bias: Double) async throws -> Double {
        received.append(bias)
        if received.count > 1 { subsequentSubmission?.fulfill() }
        if suspendNext {
            suspendNext = false
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started?.fulfill()
            }
        }
        return returnedExposure
    }

    func finish(_ accepted: Double) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: accepted)
    }
}

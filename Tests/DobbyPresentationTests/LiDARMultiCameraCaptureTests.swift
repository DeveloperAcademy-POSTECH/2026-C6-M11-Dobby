import XCTest
@testable import Dobby

/// Hardware capabilities and performance are still verified on an iPhone.
/// These cases protect the format contract before opening any camera device.
final class LiDARMultiCameraCaptureTests: XCTestCase {
    func testDiagnosticsAdmitTheAtomicRGBDepthCollection() {
        var diagnostics = LiDARMultiCameraDeliveryDiagnostics()
        diagnostics.observe(wide: 0, depth: 0)
        XCTAssertEqual(diagnostics.callbacks, 1)
        XCTAssertEqual(diagnostics.wide.received, 1)
        XCTAssertEqual(diagnostics.depth.received, 1)
        XCTAssertEqual(diagnostics.completeCollections, 1)
    }

    func testDiagnosticsStillRequireRealDepthAndTheSameCollection() {
        var diagnostics = LiDARMultiCameraDeliveryDiagnostics()
        diagnostics.observe(wide: 0, depth: nil)
        XCTAssertEqual(diagnostics.completeCollections, 0)
        XCTAssertTrue(diagnostics.failureDescription.contains("LiDAR 깊이"))
        diagnostics.observe(wide: nil, depth: 0)
        XCTAssertEqual(diagnostics.completeCollections, 0,
            "Independent callback counts cannot manufacture an atomic RGB/depth collection")
    }

    func testDeliveryDiagnosticsDistinguishNoCallbacksFromAnAbsentDepthStream() {
        var diagnostics = LiDARMultiCameraDeliveryDiagnostics()
        XCTAssertTrue(diagnostics.failureDescription.contains("콜백이 한 번도"))
        diagnostics.observe(wide: 0, depth: nil)
        XCTAssertEqual(diagnostics.callbacks, 1)
        XCTAssertEqual(diagnostics.wide.received, 1)
        XCTAssertEqual(diagnostics.depth.received, 0)
        XCTAssertEqual(diagnostics.completeCollections, 0)
        XCTAssertTrue(diagnostics.failureDescription.contains("LiDAR 깊이"))
        XCTAssertTrue(diagnostics.summary.contains("깊이0(드롭0)"))
    }

    func testDeliveryDiagnosticsCountPartialCollectionsAndEachDroppedReasonBeforeValidation() {
        var diagnostics = LiDARMultiCameraDeliveryDiagnostics()
        diagnostics.observe(wide: 0, depth: nil)
        diagnostics.observe(wide: nil, depth: 0)
        XCTAssertEqual(diagnostics.completeCollections, 0,
            "Separate callbacks must not count as a complete RGB/depth pair")
        XCTAssertTrue(diagnostics.failureDescription.contains("서로 다른 묶음"))
        diagnostics.observe(wide: 1, depth: 3)
        XCTAssertEqual(diagnostics.wide.dropped, 1)
        XCTAssertEqual(diagnostics.depth.dropped, 1)
        XCTAssertTrue(diagnostics.summary.contains("드롭1:1:1"))
        XCTAssertTrue(diagnostics.summary.contains("드롭1:3:1"))
        diagnostics.observe(wide: 0, depth: 0)
        XCTAssertEqual(diagnostics.callbacks, 4)
        XCTAssertEqual(diagnostics.completeCollections, 1)
        let nextGeneration = LiDARMultiCameraDeliveryDiagnostics()
        XCTAssertEqual(nextGeneration.callbacks, 0, "A new RunState must reset all old delivery counters")
    }

    func testFirstValidFrameBeforeWaitIsRetainedUntilStartupCommits() async throws {
        let gate = MultiCameraFirstFrameGate<Int>()
        XCTAssertTrue(gate.acceptFirstFrame(42))
        let value = try await gate.waitForFirstFrame()
        XCTAssertEqual(value, 42)
        try gate.commitStart()
        XCTAssertFalse(gate.acceptFirstFrame(99), "Later packets must not resume startup twice")
        XCTAssertFalse(gate.fail(GateFailure.calibration), "Only failure after startup commits belongs to the runtime handler")
    }

    func testCalibrationFailureBeforeFirstPacketThrowsWithoutRuntimeNotification() async {
        let gate = MultiCameraFirstFrameGate<Int>()
        let waiting = Task { try await gate.waitForFirstFrame() }
        XCTAssertTrue(gate.fail(GateFailure.calibration), "The caller must take its sequential fallback rather than a runtime failure callback")
        do { _ = try await waiting.value; XCTFail("Uncalibrated camera must not start") }
        catch let error as GateFailure { XCTAssertEqual(error, .calibration) }
        catch { XCTFail("Wrong startup cause: \(error)") }
        XCTAssertTrue(gate.fail(GateFailure.timeout), "Repeated failure is already retired")
        XCTAssertFalse(gate.acceptFirstFrame(1))
    }

    func testCancellationRetiresWaitingGateAndRejectsLateFirstPacket() async {
        let gate = MultiCameraFirstFrameGate<Int>()
        let waiting = Task { try await gate.waitForFirstFrame() }
        XCTAssertTrue(gate.fail(CancellationError()))
        XCTAssertFalse(gate.acceptFirstFrame(1))
        do { _ = try await waiting.value; XCTFail("Stopped generation must not complete startup") }
        catch is CancellationError { }
        catch { XCTFail("Wrong cancellation cause: \(error)") }
    }

    func testFailureAfterReadyButBeforeReturnStillBelongsToStartup() async throws {
        let gate = MultiCameraFirstFrameGate<Int>()
        gate.acceptFirstFrame(1)
        _ = try await gate.waitForFirstFrame()
        XCTAssertTrue(gate.fail(GateFailure.timeout))
        XCTAssertThrowsError(try gate.commitStart()) { error in
            XCTAssertEqual(error as? GateFailure, .timeout)
        }
    }

    func testLateOldGenerationCannotCompleteOrFailANewStartupGate() async throws {
        let old = MultiCameraFirstFrameGate<Int>()
        let new = MultiCameraFirstFrameGate<Int>()
        old.fail(CancellationError())
        XCTAssertFalse(old.acceptFirstFrame(1))
        XCTAssertTrue(new.acceptFirstFrame(2))
        let accepted = try await new.waitForFirstFrame()
        XCTAssertEqual(accepted, 2)
        old.fail(GateFailure.timeout)
        try new.commitStart()
        XCTAssertFalse(new.fail(GateFailure.calibration))
    }

    func testLateOldStopCannotClearTheNewPreviewMailbox() {
        let store = MultiCameraFrameStore()
        let previous = UUID(), current = UUID()
        store.begin(sessionID: previous)
        store.begin(sessionID: current)
        XCTAssertFalse(store.clear(sessionID: previous), "An asynchronously completed old pause must not blank the new preview")
        XCTAssertTrue(store.clear(sessionID: current))
    }

    func testRepeatedStopIsIdempotentAndANewStartGetsANewMailboxOwner() {
        let store = MultiCameraFrameStore()
        let previous = UUID(), current = UUID()
        store.begin(sessionID: previous)
        XCTAssertTrue(store.clear(sessionID: previous))
        XCTAssertFalse(store.clear(sessionID: previous))
        store.begin(sessionID: current)
        XCTAssertFalse(store.clear(sessionID: previous))
        XCTAssertTrue(store.clear(sessionID: current))
    }

    func testFullSensorMeasurementFormatsPreserveTheOneTimesFieldOfView() {
        XCTAssertTrue(eligible(width: 1_920, height: 1_440, minimum: 1_280, depth: true))
        XCTAssertTrue(eligible(width: 1_280, height: 960, minimum: 1_280, depth: true))
        XCTAssertFalse(eligible(width: 1_920, height: 1_080, minimum: 1_280, depth: true),
            "A cropped 16:9 sensor format cannot silently replace the full 1x composition")
    }

    func testInsufficientResolutionAndVeryLargeUnsustainableFormatsAreExcluded() {
        XCTAssertFalse(eligible(width: 960, height: 720, minimum: 1_280, depth: true))
        XCTAssertFalse(eligible(width: 4_608, height: 3_456, minimum: 1_280, depth: true))
        XCTAssertFalse(eligible(width: 1_280, height: 0, minimum: 1_280, depth: true))
    }

    func testMeasurementFormatMustHaveRealDepthAndSupportThirtyFPS() {
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.isEligible(width: 1_280, height: 960,
            supportsFrameRate: true, minimumWidth: 1_280, hasDepth: false))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.isEligible(width: 1_280, height: 960,
            supportsFrameRate: false, minimumWidth: 1_280, hasDepth: true))
        XCTAssertTrue(LiDARMultiCameraFormatPolicy.isEligible(width: 1_280, height: 960,
            supportsFrameRate: true, minimumWidth: 1_280, hasDepth: true))
    }

    func testFormatRejectionDetailsIdentifyTheCameraAndSeparateCandidatePixelAndZoomFailures() {
        var diagnostics = LiDARMultiCameraFormatDiagnostics(total: 7)
        diagnostics.eligible = 2
        diagnostics.reject(.aspect, count: 2)
        diagnostics.reject(.depth)
        diagnostics.reject(.resolution, count: 2)
        XCTAssertTrue(diagnostics.summary.contains("전체 7 / 유효 2"))
        XCTAssertTrue(diagnostics.summary.contains("비율2"))
        XCTAssertTrue(diagnostics.summary.contains("깊이1"))
        XCTAssertTrue(diagnostics.summary.contains("해상도2"))
        let candidates = LiDARMultiCameraCaptureError.noEligibleFormats(camera: "일반·LiDAR", diagnostics: diagnostics.summary).localizedDescription
        XCTAssertTrue(candidates.contains("일반·LiDAR"))
        XCTAssertTrue(candidates.contains(diagnostics.summary))
        let pixels = LiDARMultiCameraCaptureError.unsupportedPixelFormats(camera: "일반·LiDAR", supported: "0x34323066").localizedDescription
        XCTAssertTrue(pixels.contains("일반·LiDAR"))
        XCTAssertTrue(pixels.contains("픽셀 형식"))
        XCTAssertTrue(pixels.contains("0x34323066"))
        let zoom = LiDARMultiCameraCaptureError.unsupportedPhysicalZoom(camera: "일반·LiDAR", minimum: 2, maximum: 8, actual: 2).localizedDescription
        XCTAssertTrue(zoom.contains("일반·LiDAR"))
        XCTAssertTrue(zoom.contains("배율"))
        XCTAssertTrue(zoom.contains("1x"))
        XCTAssertNotEqual(candidates, pixels)
        XCTAssertNotEqual(pixels, zoom)
    }

    func testPhysicalOneTimesIsValidatedBeforeWritingTheCameraZoom() {
        XCTAssertTrue(LiDARMultiCameraFormatPolicy.permitsPhysicalOneTimes(minimum: 1, maximum: 8))
        XCTAssertTrue(LiDARMultiCameraFormatPolicy.permitsPhysicalOneTimes(minimum: 0.5, maximum: 2))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.permitsPhysicalOneTimes(minimum: 2, maximum: 8))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.permitsPhysicalOneTimes(minimum: 0.5, maximum: 0.9))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.permitsPhysicalOneTimes(minimum: .nan, maximum: 8))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.permitsPhysicalOneTimes(minimum: 1, maximum: .infinity))
    }

    func testFallbackChoosesLowerBandwidthBeforeOversizedCaptureFormats() {
        let widths = [4_032, 2_560, 1_280, 1_920, 1_440]
        let ranked = widths.sorted {
            LiDARMultiCameraFormatPolicy.preferredWidthPenalty(width: $0, preferred: 1_920)
                < LiDARMultiCameraFormatPolicy.preferredWidthPenalty(width: $1, preferred: 1_920)
        }
        XCTAssertEqual(ranked, [1_920, 1_440, 1_280, 2_560, 4_032])
    }

    func testFullNativeHighResolutionFallbackStillRequiresFullFieldDepthAndFrameRate() {
        XCTAssertTrue(eligible(width: 4_032, height: 3_024, minimum: 1_280, depth: true),
            "A valid full-field format must reach the actual hardware-cost check")
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.isEligible(width: 4_032, height: 3_024,
            supportsFrameRate: false, minimumWidth: 1_280, hasDepth: true))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.isEligible(width: 4_032, height: 3_024,
            supportsFrameRate: true, minimumWidth: 1_280, hasDepth: false))
        XCTAssertFalse(eligible(width: 4_032, height: 2_268, minimum: 1_280, depth: true))
    }

    func testMeasurementFieldOfViewCannotUseACroppedReference() {
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.acceptsFieldOfView(68, nativeReference: 74))
        XCTAssertTrue(LiDARMultiCameraFormatPolicy.acceptsFieldOfView(73.9, nativeReference: 74))
        for invalid: Float in [.nan, .infinity, 0, 180] {
            XCTAssertFalse(LiDARMultiCameraFormatPolicy.acceptsFieldOfView(invalid, nativeReference: 74))
        }
    }

    func testFourByThreeAspectAloneDoesNotPermitACroppedOneTimesFormat() {
        // Both candidates could be 1920x1440, but only the one retaining the
        // physical wide camera's full angular field can keep the 1x label.
        XCTAssertTrue(LiDARMultiCameraFormatPolicy.preservesFieldOfView(74, widestCompatible: 74))
        XCTAssertTrue(LiDARMultiCameraFormatPolicy.preservesFieldOfView(73.9, widestCompatible: 74))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.preservesFieldOfView(68, widestCompatible: 74))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.preservesFieldOfView(72, widestCompatible: 74),
            "Bandwidth fallback must fail explicitly instead of narrowing the 1x camera")
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.preservesFieldOfView(.nan, widestCompatible: 74))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.preservesFieldOfView(74, widestCompatible: .infinity))
        XCTAssertFalse(LiDARMultiCameraFormatPolicy.preservesFieldOfView(0, widestCompatible: 74))
    }

    func testNativeReferenceIncludesWiderFormatsBeforePreviewFiltering() throws {
        // The widest sensor format may be a high-resolution, single-camera or
        // lower-frame-rate native format. It still defines full wide 1x.
        let nativeReference = try XCTUnwrap(LiDARMultiCameraFormatPolicy.widestNativeFieldOfView([74, 68, 68, .nan, 180]))
        XCTAssertEqual(nativeReference, 74)
        let croppedCandidates = [Float(68), 68]
        XCTAssertFalse(croppedCandidates.contains {
            LiDARMultiCameraFormatPolicy.preservesFieldOfView($0, widestCompatible: nativeReference)
        }, "A consistently cropped candidate set must not redefine 1x")
        XCTAssertNil(LiDARMultiCameraFormatPolicy.widestNativeFieldOfView([.nan, .infinity, 0, 180]))
        XCTAssertTrue(LiDARMultiCameraFormatPolicy.isFullAspect(width: 4_032, height: 3_024),
            "Reference selection precedes the preview bandwidth/resolution ceiling")
    }

    private func eligible(width: Int, height: Int, minimum: Int, depth: Bool) -> Bool {
        LiDARMultiCameraFormatPolicy.isEligible(width: width, height: height,
            supportsFrameRate: true, minimumWidth: minimum, hasDepth: depth)
    }

    nonisolated private enum GateFailure: Error, Equatable { case calibration, timeout }
}

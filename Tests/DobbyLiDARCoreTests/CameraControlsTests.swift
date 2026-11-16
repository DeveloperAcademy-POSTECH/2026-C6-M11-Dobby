import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Pure request/range contracts, not evidence of hardware focus or exposure behavior.
final class CameraControlsTests: XCTestCase {
    func testCaptureRangeIntersectsTwoStopLimitWithDeviceSupport() throws {
        for (minimum, maximum, lower, upper) in [(-8.0, 8.0, -2.0, 2.0),
                                                (-1.5, 1.0, -1.5, 1.0),
                                                (-1.0, 4.0, -1.0, 2.0),
                                                (0.0, 0.0, 0.0, 0.0)] {
            let range = try XCTUnwrap(CameraExposureRange.captureRange(minimum: minimum, maximum: maximum))
            XCTAssertEqual(range.minimum, lower)
            XCTAssertEqual(range.maximum, upper)
            XCTAssertEqual(range.clamp(-100), lower)
            XCTAssertEqual(range.clamp(100), upper)
            XCTAssertEqual(range.clamp(0), 0)
        }
        for (minimum, maximum) in [(3.0, 4.0), (-4.0, -3.0), (2.0, -2.0),
                                   (Double.nan, 2), (-2, Double.infinity)] {
            XCTAssertNil(CameraExposureRange.captureRange(minimum: minimum, maximum: maximum))
        }
    }

    func testCaptureDragKeepsSensitivityAndCannotEscapeTwoStopsAcrossRepeatedDrags() throws {
        let deviceRange = try XCTUnwrap(CameraExposureRange(minimum: -8, maximum: 8))
        let captureRange = try XCTUnwrap(CameraExposureRange.captureRange(minimum: -8, maximum: 8))
        XCTAssertEqual(CameraExposureGesture.bias(start: 0, translationY: -100, viewportHeight: 400, range: captureRange),
                       CameraExposureGesture.bias(start: 0, translationY: -100, viewportHeight: 400, range: deviceRange))
        for (translation, expected) in [(-400.0, 2.0), (400.0, -2.0)] {
            var bias = 0.0
            for _ in 0..<5 {
                bias = try XCTUnwrap(CameraExposureGesture.bias(start: bias, translationY: translation,
                                                                viewportHeight: 400, range: captureRange))
                XCTAssertEqual(bias, expected)
            }
        }
    }

    func testExposureLimitsClampFiniteRequestsWithoutInventingADeviceRange() throws {
        let range = try XCTUnwrap(CameraExposureRange(minimum: -1.5, maximum: 2.25))
        XCTAssertEqual(range.clamp(-2), -1.5)
        XCTAssertEqual(range.clamp(3), 2.25)
        XCTAssertEqual(range.clamp(0.4), 0.4)
        XCTAssertEqual(range.clamp(-1.5), -1.5)
        XCTAssertEqual(range.clamp(2.25), 2.25)
        XCTAssertEqual(range.clamp(-Double.greatestFiniteMagnitude), -1.5)
        XCTAssertEqual(range.clamp(Double.greatestFiniteMagnitude), 2.25)
        for value in [Double.nan, .infinity, -.infinity] { XCTAssertNil(range.clamp(value)) }
    }

    func testInvalidExposureLimitsAreRejectedAndFixedExposureRangeIsValid() throws {
        for (minimum, maximum) in [(2.0, -2.0), (Double.nan, 1), (0, Double.nan),
                                   (-Double.infinity, 1), (0, Double.infinity)] {
            XCTAssertNil(CameraExposureRange(minimum: minimum, maximum: maximum))
        }
        let fixed = try XCTUnwrap(CameraExposureRange(minimum: 0, maximum: 0))
        XCTAssertEqual(fixed.clamp(-1), 0)
        XCTAssertEqual(fixed.clamp(1), 0)
    }

    func testExposureRangeDecodingCannotBypassFiniteOrderedLimits() throws {
        let valid = try XCTUnwrap(CameraExposureRange(minimum: -2, maximum: 1.5))
        XCTAssertEqual(try JSONDecoder().decode(CameraExposureRange.self,
            from: JSONEncoder().encode(valid)), valid)
        XCTAssertThrowsError(try JSONDecoder().decode(CameraExposureRange.self,
            from: Data(#"{"minimum":2,"maximum":-2}"#.utf8)))
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for json in [#"{"minimum":"NaN","maximum":1}"#,
                     #"{"minimum":0,"maximum":"Infinity"}"#] {
            XCTAssertThrowsError(try decoder.decode(CameraExposureRange.self, from: Data(json.utf8)))
        }
    }

    func testUnavailableCapabilitiesDoNotAdvertiseUnsupportedLensesOrFocus() {
        XCTAssertFalse(CameraControlCapabilities.unavailable.focusSupported)
        XCTAssertNil(CameraControlCapabilities.unavailable.exposureRange)
        XCTAssertTrue(CameraControlCapabilities.unavailable.availableZooms.isEmpty)
        XCTAssertEqual(CameraControlCapabilities().availableZooms, [.standard])
        XCTAssertEqual(CameraZoom.allCases.map(\.label), ["0.5×", "1×", "2×"])
        XCTAssertEqual(CameraZoom.allCases.map(\.id), [0.5, 1, 2])
    }

    func testControlCompletionRequiresLiveSessionLatestRequestAndExactRevision() {
        let session = UUID(), request = UUID()
        let receipt = CameraControlRequest(sessionID: session, requestID: request, revision: 7)
        XCTAssertTrue(receipt.matches(sessionID: session, requestID: request, revision: 7))
        XCTAssertFalse(receipt.matches(sessionID: UUID(), requestID: request, revision: 7),
                       "A restarted camera must reject the old completion.")
        XCTAssertFalse(receipt.matches(sessionID: session, requestID: UUID(), revision: 7),
                       "A newer focus/exposure request must supersede the old one.")
        XCTAssertFalse(receipt.matches(sessionID: session, requestID: request, revision: 8))
        XCTAssertFalse(receipt.matches(sessionID: session, requestID: request, revision: 6))
        XCTAssertFalse(receipt.matches(sessionID: nil, requestID: request, revision: 7))
        XCTAssertFalse(receipt.matches(sessionID: session, requestID: nil, revision: 7))
    }

    func testExposureDragBrightensUpDarkensDownAndClampsToActualDeviceRange() throws {
        let range = try XCTUnwrap(CameraExposureRange(minimum: -2, maximum: 2))
        XCTAssertEqual(CameraExposureGesture.bias(start: 0, translationY: -100, viewportHeight: 400, range: range), 1)
        XCTAssertEqual(CameraExposureGesture.bias(start: 0, translationY: 100, viewportHeight: 400, range: range), -1)
        XCTAssertEqual(CameraExposureGesture.bias(start: 1.5, translationY: -300, viewportHeight: 400, range: range), 2)
        XCTAssertEqual(CameraExposureGesture.bias(start: -1.5, translationY: 300, viewportHeight: 400, range: range), -2)
        XCTAssertNil(CameraExposureGesture.bias(start: 0, translationY: .nan, viewportHeight: 400, range: range))
        XCTAssertNil(CameraExposureGesture.bias(start: 0, translationY: 10, viewportHeight: 0, range: range))
        XCTAssertNil(CameraExposureGesture.bias(start: .infinity, translationY: 10, viewportHeight: 400, range: range))
    }

    func testLockConfirmationRequiresBothObservedLockedModesAndSettledFlags() {
        var observation = CameraHardwareObservation(observedAtUptime: 10, focusMode: .locked,
            exposureMode: .locked, isAdjustingFocus: false, isAdjustingExposure: false,
            lensPosition: 0.5, exposureDurationSeconds: 0.01, iso: 100, exposureTargetBias: 0)
        XCTAssertTrue(observation.hasObservedAEAFLock)
        observation.focusMode = .single
        XCTAssertFalse(observation.hasObservedAEAFLock)
        observation.focusMode = .locked
        observation.exposureMode = .continuous
        XCTAssertFalse(observation.hasObservedAEAFLock)
        observation.exposureMode = .locked
        observation.isAdjustingExposure = true
        XCTAssertFalse(observation.hasObservedAEAFLock)
        observation.isAdjustingExposure = false
        observation.isAdjustingFocus = true
        XCTAssertFalse(observation.hasObservedAEAFLock)
    }

    func testWideRangeCameraKeepsFineDragSensitivityAndStillReachesItsLimits() throws {
        let wide = try XCTUnwrap(CameraExposureRange(minimum: -8, maximum: 8))
        let standard = try XCTUnwrap(CameraExposureRange(minimum: -2, maximum: 2))
        let wideStep = try XCTUnwrap(CameraExposureGesture.bias(start: 0, translationY: -100, viewportHeight: 400, range: wide))
        XCTAssertEqual(wideStep, CameraExposureGesture.bias(start: 0, translationY: -100, viewportHeight: 400, range: standard),
            "The same finger movement must not be four times stronger on a wide-range camera.")
        XCTAssertEqual(wideStep, 1)
        XCTAssertEqual(CameraExposureGesture.bias(start: 7, translationY: -200, viewportHeight: 400, range: wide), 8)
        XCTAssertEqual(CameraExposureGesture.bias(start: -7, translationY: 200, viewportHeight: 400, range: wide), -8)
        let narrow = try XCTUnwrap(CameraExposureRange(minimum: -1, maximum: 1))
        XCTAssertEqual(CameraExposureGesture.bias(start: 0, translationY: -100, viewportHeight: 400, range: narrow), 0.5)
    }
}

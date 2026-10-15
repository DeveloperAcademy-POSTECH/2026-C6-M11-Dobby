import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Pure request/range contracts, not evidence of hardware focus or exposure behavior.
final class CameraControlsTests: XCTestCase {
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
}

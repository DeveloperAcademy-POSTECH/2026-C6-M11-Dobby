import XCTest
@testable import DobbyLiDARCore

final class MultiCameraCaptureEvidenceTests: XCTestCase {
    func testCalibratedSynchronizedLiDARDoesNotPretendToHaveARTrackingOrMotion() throws {
        var quality = CaptureFrameQuality.evaluate(depth: .init(size: .init(width: 8, height: 6),
            values: Array(repeating: 1, count: 48), confidence: nil), timestamp: 10,
            trackingNormal: false, translationSpeedMetersPerSecond: nil, angularSpeedRadiansPerSecond: nil)
        XCTAssertFalse(quality.isEligible)
        quality.captureEvidence = .synchronizedCalibratedLiDAR
        XCTAssertTrue(quality.isEligible)
        XCTAssertFalse(quality.trackingNormal)
        XCTAssertFalse(quality.motionKnown)
        XCTAssertNil(quality.highConfidenceCoverage)
        XCTAssertNil(quality.translationSpeedMetersPerSecond)
        XCTAssertEqual(quality.score, 0.55 * 0.75, accuracy: 0.0001)
        let decoded = try JSONDecoder().decode(CaptureFrameQuality.self, from: JSONEncoder().encode(quality))
        XCTAssertEqual(decoded, quality)
    }

    func testCalibrationEvidenceCannotAdmitMissingDepthOrAnInvalidTimestamp() {
        for depth: DepthMap? in [nil, .init(size: .init(width: 8, height: 6),
            values: Array(repeating: 0, count: 48), confidence: nil)] {
            var quality = CaptureFrameQuality.evaluate(depth: depth, timestamp: 10,
                trackingNormal: false, translationSpeedMetersPerSecond: nil, angularSpeedRadiansPerSecond: nil)
            quality.captureEvidence = .synchronizedCalibratedLiDAR
            XCTAssertFalse(quality.isEligible)
        }
        var invalid = CaptureFrameQuality.evaluate(depth: .init(size: .init(width: 8, height: 6),
            values: Array(repeating: 1, count: 48), confidence: nil), timestamp: .nan,
            trackingNormal: false, translationSpeedMetersPerSecond: nil, angularSpeedRadiansPerSecond: nil)
        invalid.captureEvidence = .synchronizedCalibratedLiDAR
        XCTAssertFalse(invalid.isEligible)
    }

    func testOldARKitQualityDecodesWithNoNewEvidence() throws {
        let original = CaptureFrameQuality.evaluate(depth: .init(size: .init(width: 8, height: 6),
            values: Array(repeating: 1, count: 48), confidence: nil), timestamp: 10,
            trackingNormal: true, translationSpeedMetersPerSecond: 0.01, angularSpeedRadiansPerSecond: 0.01)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "captureEvidence")
        let decoded = try JSONDecoder().decode(CaptureFrameQuality.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.captureEvidence)
        XCTAssertTrue(decoded.isEligible)
        XCTAssertEqual(decoded, original)
    }

    func testAVFoundationSourceSurvivesArchivesWithoutBeingReportedAsSceneDepth() throws {
        let data = try JSONEncoder().encode(DepthSource.avFoundationLiDAR)
        XCTAssertEqual(try JSONDecoder().decode(DepthSource.self, from: data), .avFoundationLiDAR)
        XCTAssertNotEqual(DepthSource.avFoundationLiDAR, .sceneDepth)
    }
}

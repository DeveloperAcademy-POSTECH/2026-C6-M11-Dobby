import Foundation
import XCTest
@testable import Dobby

/// Snapshot persistence/provenance checks using synthetic buffers. These do not
/// establish physical autofocus, exposure settling or real-device accuracy.
@MainActor
final class CameraCaptureMetadataTests: XCTestCase {
    private func snapshot(includeSettings: Bool) throws -> CaptureSnapshot {
        let imageSize = PixelSize(width: 64, height: 48)
        let depthSize = PixelSize(width: 16, height: 12)
        let depth = DepthMap(size: depthSize, values: .init(repeating: 1.2, count: 16 * 12),
                             confidence: .init(repeating: 2, count: 16 * 12))
        let intrinsics = CameraIntrinsics(fx: 80, fy: 82, cx: 30, cy: 22, referenceSize: imageSize)
        var frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 123,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), imageSize: imageSize,
            intrinsics: intrinsics, depth: depth, source: .synthetic, orientation: .right)
        guard includeSettings else { return .init(frame: frame, imageJPEG: Data([0xFA, 0xCE])) }
        let crop = try XCTUnwrap(RegisteredCameraCrop.make(imageSize: imageSize, depthSize: depthSize, zoomFactor: 2))
        frame.imageSize = crop.imageSize
        frame.depth = try XCTUnwrap(crop.applying(to: depth))
        frame.intrinsics = try XCTUnwrap(crop.applying(to: intrinsics))
        let settings = CameraCaptureSettings(settingsRevision: 7, focusSensorPoint: .init(x: 0.4, y: 0.45),
            requestedExposureBias: 0.25, acceptedExposureBias: 0.2, requestedZoomFactor: 2, crop: crop,
            frameExposureDurationSeconds: 0.004, frameExposureOffsetEV: 0.1)
        return .init(frame: frame, imageJPEG: Data([0xFA, 0xCE]), cameraSettings: settings)
    }

    func testCroppedSnapshotRetainsFrameIdentityCalibrationAndDistinctControlFacts() throws {
        let original = try snapshot(includeSettings: true)
        let decoded = try JSONDecoder().decode(CaptureSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.frame.sessionID, original.frame.sessionID)
        XCTAssertEqual(decoded.frame.frameID, original.frame.frameID)
        XCTAssertEqual(decoded.frame.timestamp, original.frame.timestamp)
        XCTAssertEqual(decoded.frame.orientation, original.frame.orientation)
        XCTAssertEqual(decoded.frame.imageSize, original.frame.imageSize)
        XCTAssertEqual(decoded.frame.depth.size, original.frame.depth.size)
        XCTAssertEqual(decoded.frame.depth.values, original.frame.depth.values)
        XCTAssertEqual(decoded.frame.depth.confidence, original.frame.depth.confidence)
        XCTAssertEqual(decoded.frame.intrinsics, original.frame.intrinsics)
        XCTAssertEqual(decoded.imageJPEG, original.imageJPEG)
        XCTAssertEqual(decoded.cameraSettings, original.cameraSettings)
        let settings = try XCTUnwrap(decoded.cameraSettings)
        XCTAssertEqual(settings.requestedExposureBias, 0.25)
        XCTAssertEqual(settings.acceptedExposureBias, 0.2)
        XCTAssertEqual(settings.frameExposureDurationSeconds, 0.004)
        XCTAssertEqual(settings.frameExposureOffsetEV, 0.1)
        XCTAssertEqual(settings.crop?.imageSize, decoded.frame.imageSize)
        XCTAssertEqual(settings.crop?.depthSize, decoded.frame.depth.size)
    }

    func testLegacySnapshotWithoutControlMetadataDecodesWithoutInventedSettings() throws {
        let original = try snapshot(includeSettings: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "cameraSettings")
        object.removeValue(forKey: "smoothedFrame")
        object.removeValue(forKey: "selectionSummary")
        let decoded = try JSONDecoder().decode(CaptureSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.cameraSettings)
        XCTAssertNil(decoded.smoothedFrame)
        XCTAssertNil(decoded.selectionSummary)
        XCTAssertEqual(decoded.frame.intrinsics, original.frame.intrinsics)
        XCTAssertEqual(decoded.frame.depth.values, original.frame.depth.values)
        XCTAssertEqual(decoded.imageJPEG, original.imageJPEG)
    }

    func testTamperedRegisteredCropInsideSnapshotIsRejected() throws {
        let original = try snapshot(includeSettings: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var settings = try XCTUnwrap(object["cameraSettings"] as? [String: Any])
        var crop = try XCTUnwrap(settings["crop"] as? [String: Any])
        crop["depthOriginY"] = 99
        settings["crop"] = crop
        object["cameraSettings"] = settings
        let altered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureSnapshot.self, from: altered))
    }
}

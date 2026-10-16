import Foundation
import XCTest
@testable import DobbyLiDARCore

final class RegisteredCameraCropTests: XCTestCase {
    private let imageSize = PixelSize(width: 1920, height: 1440)
    private let depthSize = PixelSize(width: 256, height: 192)

    private func crop(_ zoom: Double = 2) throws -> RegisteredCameraCrop {
        try XCTUnwrap(RegisteredCameraCrop.make(imageSize: imageSize, depthSize: depthSize, zoomFactor: zoom))
    }

    func testTwoTimesCropUsesExactlyMatchingCenteredIntegerRegions() throws {
        let value = try crop()
        XCTAssertEqual(value.sourceImageSize, imageSize)
        XCTAssertEqual(value.sourceDepthSize, depthSize)
        XCTAssertEqual(value.imageOriginX, 480)
        XCTAssertEqual(value.imageOriginY, 360)
        XCTAssertEqual(value.imageSize, .init(width: 960, height: 720))
        XCTAssertEqual(value.depthOriginX, 64)
        XCTAssertEqual(value.depthOriginY, 48)
        XCTAssertEqual(value.depthSize, .init(width: 128, height: 96))
        XCTAssertEqual(value.requestedZoomFactor, 2)
        XCTAssertEqual(value.effectiveZoomFactor, 2)
    }

    func testOneTimesIsIdentityIncludingOddSourceSizes() throws {
        let size = PixelSize(width: 101, height: 79)
        let value = try XCTUnwrap(RegisteredCameraCrop.make(imageSize: size, depthSize: size, zoomFactor: 1))
        XCTAssertEqual(value.imageOriginX, 0)
        XCTAssertEqual(value.imageOriginY, 0)
        XCTAssertEqual(value.depthOriginX, 0)
        XCTAssertEqual(value.depthOriginY, 0)
        XCTAssertEqual(value.imageSize, size)
        XCTAssertEqual(value.depthSize, size)
        let point = ImagePoint(x: 0.35, y: 0.8)
        let restored = try XCTUnwrap(value.normalizedSourcePoint(fromCropped: point))
        XCTAssertEqual(restored.x, point.x, accuracy: 1e-14)
        XCTAssertEqual(restored.y, point.y, accuracy: 1e-14)
    }

    func testSixteenByNineCropRetainsRegisteredFieldOfView() throws {
        let value = try XCTUnwrap(RegisteredCameraCrop.make(imageSize: .init(width: 1920, height: 1080),
            depthSize: .init(width: 256, height: 144), zoomFactor: 2))
        XCTAssertEqual(value.imageOriginX, 480)
        XCTAssertEqual(value.imageOriginY, 270)
        XCTAssertEqual(value.imageSize, .init(width: 960, height: 540))
        XCTAssertEqual(value.depthOriginX, 64)
        XCTAssertEqual(value.depthOriginY, 36)
        XCTAssertEqual(value.depthSize, .init(width: 128, height: 72))
    }

    func testUnsupportedExactGeometryNeverRoundsToApproximateZoom() {
        let cases: [(PixelSize, PixelSize, Double)] = [
            (.init(width: 400, height: 533), .init(width: 400, height: 533), 2),
            // RGB can be centered at integers, but the depth origin would be 12.5.
            (.init(width: 100, height: 80), .init(width: 50, height: 40), 2),
            (imageSize, depthSize, 3),
            (imageSize, depthSize, 1.00000000001),
            (imageSize, .init(width: 256, height: 144), 2)
        ]
        for (image, depth, zoom) in cases {
            XCTAssertNil(RegisteredCameraCrop.make(imageSize: image, depthSize: depth, zoomFactor: zoom))
        }
    }

    func testInvalidZoomAndSourceDimensionsAreRejectedBeforeIntegerConversion() {
        for zoom in [Double.nan, .infinity, -.infinity, -1, 0, 0.5, Double.greatestFiniteMagnitude] {
            XCTAssertNil(RegisteredCameraCrop.make(imageSize: imageSize, depthSize: depthSize, zoomFactor: zoom))
        }
        for size in [PixelSize(width: 0, height: 1), .init(width: -1, height: 1),
                     .init(width: Int.max, height: Int.max), .init(width: 16_385, height: 16_385)] {
            XCTAssertNil(RegisteredCameraCrop.make(imageSize: size, depthSize: depthSize, zoomFactor: 2))
            XCTAssertNil(RegisteredCameraCrop.make(imageSize: imageSize, depthSize: size, zoomFactor: 2))
        }
    }

    func testDepthAndConfidenceAreCopiedExactlyWithoutFillingInvalidSamples() throws {
        let value = try crop()
        var source = DepthMap(size: depthSize,
            values: (0..<(depthSize.width * depthSize.height)).map { Float($0) / 1000 },
            confidence: (0..<(depthSize.width * depthSize.height)).map { UInt8($0 % 3) })
        let first = value.depthOriginY * depthSize.width + value.depthOriginX
        source.values[first] = 0
        source.values[first + 1] = .nan
        source.values[first + 2] = .infinity
        let originalBits = source.values.map(\.bitPattern)
        let originalConfidence = source.confidence
        var cropped = try XCTUnwrap(value.applying(to: source))
        XCTAssertEqual(cropped.size, value.depthSize)
        XCTAssertEqual(cropped.values.count, 128 * 96)
        for row in 0..<value.depthSize.height {
            for column in 0..<value.depthSize.width {
                let original = (value.depthOriginY + row) * depthSize.width + value.depthOriginX + column
                let destination = row * value.depthSize.width + column
                XCTAssertEqual(cropped.values[destination].bitPattern, source.values[original].bitPattern)
                XCTAssertEqual(cropped.confidence?[destination], source.confidence?[original])
            }
        }
        XCTAssertEqual(cropped.values[0], 0)
        XCTAssertTrue(cropped.values[1].isNaN)
        cropped.values[0] = 999
        cropped.confidence?[0] = 2
        XCTAssertEqual(source.values.map(\.bitPattern), originalBits)
        XCTAssertEqual(source.confidence, originalConfidence)
    }

    func testMissingConfidenceRemainsUnknownAndMalformedDepthIsRejected() throws {
        let value = try crop()
        let source = DepthMap(size: depthSize, values: .init(repeating: 1.2, count: 256 * 192), confidence: nil)
        XCTAssertNil(try XCTUnwrap(value.applying(to: source)).confidence)
        var truncated = source
        truncated.values.removeLast()
        XCTAssertNil(value.applying(to: truncated))
        var wrongSize = source
        wrongSize.size = .init(width: 192, height: 256)
        XCTAssertNil(value.applying(to: wrongSize))
        var shortConfidence = source
        shortConfidence.confidence = [2]
        XCTAssertNil(value.applying(to: shortConfidence))
        var invalidConfidence = source
        invalidConfidence.confidence = .init(repeating: 2, count: source.values.count)
        invalidConfidence.confidence?[0] = 3
        XCTAssertNil(value.applying(to: invalidConfidence))
    }

    func testDepthOutsideCropCannotQualifyOrWinShutterSelection() throws {
        let value = try crop()
        var goodOutside = DepthMap(size: depthSize,
            values: .init(repeating: 1.2, count: depthSize.width * depthSize.height),
            confidence: .init(repeating: 2, count: depthSize.width * depthSize.height))
        var goodInside = goodOutside
        goodInside.values = .init(repeating: 0, count: goodInside.values.count)
        for row in value.depthOriginY..<(value.depthOriginY + value.depthSize.height) {
            for column in value.depthOriginX..<(value.depthOriginX + value.depthSize.width) {
                let index = row * depthSize.width + column
                goodOutside.values[index] = 0
                goodInside.values[index] = 1.2
            }
        }
        func quality(_ depth: DepthMap, timestamp: Double) -> CaptureFrameQuality {
            .evaluate(depth: depth, timestamp: timestamp, trackingNormal: true,
                translationSpeedMetersPerSecond: 0, angularSpeedRadiansPerSecond: 0)
        }
        let fullOutside = quality(goodOutside, timestamp: 1)
        let fullInside = quality(goodInside, timestamp: 1.1)
        XCTAssertTrue(fullOutside.isEligible)
        XCTAssertTrue(fullInside.isEligible)
        XCTAssertGreaterThan(fullOutside.score, fullInside.score,
            "The uncropped background would otherwise make the unusable center look preferable")
        let croppedOutside = quality(try XCTUnwrap(value.applying(to: goodOutside)), timestamp: 1)
        let croppedInside = quality(try XCTUnwrap(value.applying(to: goodInside)), timestamp: 1.1)
        XCTAssertFalse(croppedOutside.isEligible)
        XCTAssertEqual(croppedOutside.validDepthSampleCount, 0)
        XCTAssertTrue(croppedInside.isEligible)

        let requestID = UUID()
        var selector = CaptureFrameSelector(requestID: requestID, startedAt: 100)
        XCTAssertFalse(selector.consider(croppedOutside, requestID: requestID, now: 100))
        XCTAssertNil(selector.windowEndsAt, "An unusable photographed ROI must not start the selection window")
        XCTAssertTrue(selector.consider(croppedInside, requestID: requestID, now: 100.1))
        XCTAssertNil(selector.finish(requestID: requestID, now: 100.4))
        let summary = try XCTUnwrap(selector.finish(requestID: requestID, now: 100.45))
        XCTAssertEqual(summary.selectedFrameTimestamp, 1.1)
        XCTAssertEqual(summary.observedFrameCount, 2)
        XCTAssertEqual(summary.eligibleCandidateCount, 1)
        XCTAssertEqual(summary.selectedQuality.validDepthSampleCount, value.depthSize.width * value.depthSize.height)
        XCTAssertEqual(summary.selectedQuality.validDepthCoverage, 1)
        XCTAssertEqual(summary.selectedQuality.highConfidenceCoverage, 1)
        XCTAssertEqual(summary.selectionWindowSeconds, 0.35)
        XCTAssertEqual(summary.waitingDurationSeconds, 0.45, accuracy: 1e-8)
    }

    func testIntrinsicsTranslatePrincipalPointWithoutScalingFocalLengths() throws {
        let value = try crop()
        let original = CameraIntrinsics(fx: 1512, fy: 1508, cx: 905, cy: 681, referenceSize: imageSize)
        let cropped = try XCTUnwrap(value.applying(to: original))
        XCTAssertEqual(cropped.fx, original.fx)
        XCTAssertEqual(cropped.fy, original.fy)
        XCTAssertEqual(cropped.cx, 425)
        XCTAssertEqual(cropped.cy, 321)
        XCTAssertEqual(cropped.referenceSize, value.imageSize)
        XCTAssertEqual(original.cx, 905)
        XCTAssertEqual(original.referenceSize, imageSize)
    }

    func testInvalidOrMismatchedIntrinsicsDoNotEnterCroppedCapture() throws {
        let value = try crop()
        let original = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720, referenceSize: imageSize)
        var wrongSize = original
        wrongSize.referenceSize = value.imageSize
        XCTAssertNil(value.applying(to: wrongSize))
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            var x = original, y = original
            x.fx = invalid
            y.fy = invalid
            XCTAssertNil(value.applying(to: x))
            XCTAssertNil(value.applying(to: y))
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            var x = original, y = original
            x.cx = invalid
            y.cy = invalid
            XCTAssertNil(value.applying(to: x))
            XCTAssertNil(value.applying(to: y))
        }
    }

    func testNormalizedCoordinatesCoverCenterEdgesAndRejectOutsideCrop() throws {
        let value = try crop()
        XCTAssertEqual(value.normalizedSourcePoint(fromCropped: .init(x: 0, y: 0)), .init(x: 0.25, y: 0.25))
        XCTAssertEqual(value.normalizedSourcePoint(fromCropped: .init(x: 0.5, y: 0.5)), .init(x: 0.5, y: 0.5))
        XCTAssertEqual(value.croppedPoint(fromSource: .init(x: 0.25, y: 0.25)), .init(x: 0, y: 0))
        XCTAssertEqual(value.croppedPoint(fromSource: .init(x: 0.5, y: 0.5)), .init(x: 0.5, y: 0.5))
        for outside in [ImagePoint(x: 0.24, y: 0.5), .init(x: 0.5, y: 0.24),
                        .init(x: 0.75, y: 0.5), .init(x: 0.5, y: 0.75)] {
            XCTAssertNil(value.croppedPoint(fromSource: outside))
        }
        let inside = ImagePoint(x: 0.749_999_999, y: 0.749_999_999)
        let cropped = try XCTUnwrap(value.croppedPoint(fromSource: inside))
        let restored = try XCTUnwrap(value.normalizedSourcePoint(fromCropped: cropped))
        XCTAssertEqual(restored.x, inside.x, accuracy: 1e-14)
        XCTAssertEqual(restored.y, inside.y, accuracy: 1e-14)
        for invalid in [ImagePoint(x: .nan, y: 0.5), .init(x: 0.5, y: .infinity),
                        .init(x: -0.1, y: 0.5), .init(x: 1, y: 0.5), .init(x: 0.5, y: 1)] {
            XCTAssertNil(value.croppedPoint(fromSource: invalid))
            XCTAssertNil(value.normalizedSourcePoint(fromCropped: invalid))
        }
    }

    func testCroppedUnprojectionPreservesDistanceAndPointsInEveryImageOrientation() throws {
        let value = try crop()
        let frameID = UUID(), sessionID = UUID()
        let intrinsics = CameraIntrinsics(fx: 1500, fy: 1480, cx: 905, cy: 681, referenceSize: imageSize)
        let sourcePoints = [ImagePoint(x: 0.35, y: 0.4), .init(x: 0.65, y: 0.6)]
        for tilted in [false, true] {
            var depths = [Float](repeating: 1.5, count: depthSize.width * depthSize.height)
            if tilted {
                for row in 0..<depthSize.height { for column in 0..<depthSize.width {
                    let u = (Double(column) + 0.5) * Double(imageSize.width) / Double(depthSize.width)
                    let v = (Double(row) + 0.5) * Double(imageSize.height) / Double(depthSize.height)
                    let denominator = 1 + 0.3 * (u - intrinsics.cx) / intrinsics.fx
                        + 0.15 * (v - intrinsics.cy) / intrinsics.fy
                    depths[row * depthSize.width + column] = Float(1.5 / denominator)
                } }
            }
            let originalDepth = DepthMap(size: depthSize, values: depths,
                confidence: .init(repeating: 2, count: depths.count))
            for orientation in ImageOrientation.allCases {
                let original = MeasurementFrame(sessionID: sessionID, frameID: frameID, timestamp: 1,
                    capturedAt: .now, imageSize: imageSize, intrinsics: intrinsics,
                    depth: originalDepth, source: .synthetic, orientation: orientation)
                var cropped = original
                cropped.imageSize = value.imageSize
                cropped.intrinsics = try XCTUnwrap(value.applying(to: intrinsics))
                cropped.depth = try XCTUnwrap(value.applying(to: originalDepth))
                let mapped = try sourcePoints.map { point -> ImagePoint in
                    // Real presentation rotates only after cropping raw sensor pixels.
                    let local = try XCTUnwrap(value.croppedPoint(fromSource: point))
                    let display = ImageCoordinateTransform.originalToDisplay(local, orientation: orientation)
                    let restored = ImageCoordinateTransform.displayToOriginal(display, orientation: orientation)
                    let source = try XCTUnwrap(value.normalizedSourcePoint(fromCropped: restored))
                    XCTAssertEqual(source.x, point.x, accuracy: 1e-14)
                    XCTAssertEqual(source.y, point.y, accuracy: 1e-14)
                    return restored
                }
                let full = try measure(original, points: sourcePoints)
                let zoomed = try measure(cropped, points: mapped)
                XCTAssertEqual(full.status, .valid)
                XCTAssertEqual(zoomed.status, .valid)
                XCTAssertEqual(try XCTUnwrap(zoomed.meters), try XCTUnwrap(full.meters), accuracy: 1e-8)
                XCTAssertEqual(full.points.count, 2)
                XCTAssertEqual(zoomed.points.count, 2)
                for (before, after) in zip(full.points, zoomed.points) {
                    XCTAssertEqual(after.position.x, before.position.x, accuracy: 1e-8)
                    XCTAssertEqual(after.position.y, before.position.y, accuracy: 1e-8)
                    XCTAssertEqual(after.position.z, before.position.z, accuracy: 1e-8)
                }
                if !tilted {
                    let dx = 0.3 * Double(imageSize.width) * 1.5 / intrinsics.fx
                    let dy = 0.2 * Double(imageSize.height) * 1.5 / intrinsics.fy
                    XCTAssertEqual(try XCTUnwrap(zoomed.meters), hypot(dx, dy), accuracy: 1e-8)
                }
            }
        }
    }

    private func measure(_ frame: MeasurementFrame, points: [ImagePoint]) throws -> MeasurementValue {
        let landmarks = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID, origin: .manual,
            points: [.init(id: "A", point: points[0]), .init(id: "B", point: points[1])])
        return try XCTUnwrap(LiDARMeasurementEngine().measure(frame: frame, landmarks: landmarks,
            definitions: [.testDistance]).values.first)
    }

    func testEncodedCropRoundTripsAndRejectsTamperedGeometry() throws {
        let value = try crop()
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(RegisteredCameraCrop.self, from: data), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, replacement) in [("imageOriginX", -1), ("depthOriginX", 65),
                                   ("effectiveZoomFactor", 3), ("requestedZoomFactor", 3)] {
            var altered = object
            altered[key] = replacement
            let alteredData = try JSONSerialization.data(withJSONObject: altered)
            XCTAssertThrowsError(try JSONDecoder().decode(RegisteredCameraCrop.self, from: alteredData))
        }
    }
}

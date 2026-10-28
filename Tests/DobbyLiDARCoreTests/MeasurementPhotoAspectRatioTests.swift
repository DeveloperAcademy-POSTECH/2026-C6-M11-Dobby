import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Pure layout/crop and synthetic calibration contracts. No photo is resized
/// or assigned a different sensor calibration by selecting a display ratio.
final class MeasurementPhotoAspectRatioTests: XCTestCase {
    private let nativeImageSize = PixelSize(width: 1920, height: 1440)

    func testSupportedChoicesAndNominalRatiosMatchTheThreeAvailableOptions() {
        XCTAssertEqual(MeasurementPhotoAspectRatio.allCases.map(\.rawValue), ["4:3", "16:9", "1:1"])
        XCTAssertNil(MeasurementPhotoAspectRatio(rawValue: "3:2"))
        XCTAssertNil(MeasurementPhotoAspectRatio(rawValue: "16x9"))
        XCTAssertEqual(MeasurementPhotoAspectRatio.fourThree.displayRatio(isLandscape: false), 0.75)
        XCTAssertEqual(MeasurementPhotoAspectRatio.fourThree.displayRatio(isLandscape: true), 4.0 / 3)
        XCTAssertEqual(MeasurementPhotoAspectRatio.sixteenNine.displayRatio(isLandscape: false), 9.0 / 16)
        XCTAssertEqual(MeasurementPhotoAspectRatio.sixteenNine.displayRatio(isLandscape: true), 16.0 / 9)
        XCTAssertEqual(MeasurementPhotoAspectRatio.square.displayRatio(isLandscape: false), 1)
        XCTAssertEqual(MeasurementPhotoAspectRatio.square.displayRatio(isLandscape: true), 1)
    }

    func testDefaultRetainsFullNativeAndLegacyFixtureRastersInEveryOrientation() {
        for size in [nativeImageSize, .init(width: 800, height: 1000), .init(width: 804, height: 1120)] {
            for orientation in ImageOrientation.allCases {
                XCTAssertEqual(MeasurementPhotoAspectRatio.fourThree.displayCrop(imageSize: size,
                    orientation: orientation), .full)
            }
        }
    }

    func testSixteenNineUsesTheExactCenteredCropForAllFourOrientations() throws {
        for orientation in ImageOrientation.allCases {
            let quarterTurn = orientation == .left || orientation == .right
            let expected = quarterTurn
                ? PhotoDisplayCrop(x: 0.125, y: 0, width: 0.75, height: 1)
                : PhotoDisplayCrop(x: 0, y: 0.125, width: 1, height: 0.75)
            let actual = try XCTUnwrap(MeasurementPhotoAspectRatio.sixteenNine.displayCrop(
                imageSize: nativeImageSize, orientation: orientation))
            assertCrop(actual, expected)
            let sourceAspect = quarterTurn ? 0.75 : 4.0 / 3
            let targetAspect = MeasurementPhotoAspectRatio.sixteenNine.displayRatio(isLandscape: !quarterTurn)
            XCTAssertEqual(sourceAspect * actual.width / actual.height, targetAspect, accuracy: 1e-12)
        }
    }

    func testSquareUsesTheExactCenteredCropForAllFourOrientations() throws {
        for orientation in ImageOrientation.allCases {
            let quarterTurn = orientation == .left || orientation == .right
            let expected = quarterTurn
                ? PhotoDisplayCrop(x: 0, y: 0.125, width: 1, height: 0.75)
                : PhotoDisplayCrop(x: 0.125, y: 0, width: 0.75, height: 1)
            let actual = try XCTUnwrap(MeasurementPhotoAspectRatio.square.displayCrop(
                imageSize: nativeImageSize, orientation: orientation))
            assertCrop(actual, expected)
            XCTAssertEqual((quarterTurn ? 0.75 : 4.0 / 3) * actual.width / actual.height, 1, accuracy: 1e-12)
        }
    }

    func testNonNativePortraitFixtureChoosesItsActualDirectionInsteadOfTreatingUpAsLandscape() throws {
        let size = PixelSize(width: 800, height: 1000)
        let portrait = try XCTUnwrap(MeasurementPhotoAspectRatio.sixteenNine.displayCrop(imageSize: size, orientation: .up))
        assertCrop(portrait, .init(x: 0.1484375, y: 0, width: 0.703125, height: 1))
        let landscape = try XCTUnwrap(MeasurementPhotoAspectRatio.sixteenNine.displayCrop(imageSize: size, orientation: .right))
        assertCrop(landscape, .init(x: 0, y: 0.1484375, width: 1, height: 0.703125))
        let neutral = try XCTUnwrap(MeasurementPhotoAspectRatio.sixteenNine.displayCrop(
            imageSize: .init(width: 600, height: 600), orientation: .up))
        assertCrop(neutral, .init(x: 0.21875, y: 0, width: 0.5625, height: 1))
    }

    func testRegisteredOneAndTwoXImagesReceiveTheSameSingleRatioCrop() throws {
        let registered = try XCTUnwrap(RegisteredCameraCrop.make(imageSize: nativeImageSize,
            depthSize: .init(width: 256, height: 192), zoomFactor: 2))
        for orientation in ImageOrientation.allCases {
            for ratio in MeasurementPhotoAspectRatio.allCases {
                let one = try XCTUnwrap(ratio.displayCrop(imageSize: nativeImageSize, orientation: orientation))
                let two = try XCTUnwrap(ratio.displayCrop(imageSize: registered.imageSize, orientation: orientation))
                assertCrop(two, one)
                if ratio != .fourThree {
                    XCTAssertEqual(min(two.width, two.height), 0.75, accuracy: 1e-12,
                                   "An already registered 2x image must not receive another half-size zoom crop")
                }
            }
        }
    }

    func testRatioAndOrientationInverseRestoresOriginalSourceCoordinatesAfterRegisteredZoom() throws {
        let source = ImagePoint(x: 0.4, y: 0.45)
        for zoom in [1.0, 2.0] {
            let registered = try XCTUnwrap(RegisteredCameraCrop.make(imageSize: nativeImageSize,
                depthSize: .init(width: 256, height: 192), zoomFactor: zoom))
            let localSensor = try XCTUnwrap(registered.croppedPoint(fromSource: source))
            for orientation in ImageOrientation.allCases {
                let oriented = ImageCoordinateTransform.originalToDisplay(localSensor, orientation: orientation)
                for ratio in MeasurementPhotoAspectRatio.allCases {
                    let crop = try XCTUnwrap(ratio.displayCrop(imageSize: registered.imageSize, orientation: orientation))
                    let selected = ImagePoint(x: (oriented.x - crop.x) / crop.width,
                        y: (oriented.y - crop.y) / crop.height)
                    XCTAssertGreaterThan(selected.x, 0)
                    XCTAssertLessThan(selected.x, 1)
                    XCTAssertGreaterThan(selected.y, 0)
                    XCTAssertLessThan(selected.y, 1)
                    let restoredDisplay = ImagePoint(x: selected.x * crop.width + crop.x,
                        y: selected.y * crop.height + crop.y)
                    let restoredLocal = ImageCoordinateTransform.displayToOriginal(restoredDisplay, orientation: orientation)
                    let restoredSource = try XCTUnwrap(registered.normalizedSourcePoint(fromCropped: restoredLocal))
                    XCTAssertEqual(restoredSource.x, source.x, accuracy: 1e-12)
                    XCTAssertEqual(restoredSource.y, source.y, accuracy: 1e-12)
                }
            }
        }
    }

    func testPortraitSelectedCropsAgreeWithIndependentFocusTransforms() throws {
        let source = ImagePoint(x: 0.37, y: 0.61)
        let transforms: [(MeasurementPhotoAspectRatio, CameraAffineTransform)] = [
            (.fourThree, .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)),
            (.sixteenNine, .init(a: 0, b: 1, c: -4.0 / 3, d: 0, tx: 7.0 / 6, ty: 0)),
            (.square, .init(a: 0, b: 4.0 / 3, c: -1, d: 0, tx: 1, ty: -1.0 / 6))
        ]
        for (ratio, transform) in transforms {
            let crop = try XCTUnwrap(ratio.displayCrop(imageSize: nativeImageSize, orientation: .right))
            let viewport = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 402,
                containerHeight: 874, photoAspectRatio: ratio.displayRatio(isLandscape: false)))
            // Raw(.37,.61) independently rotates right to display(.39,.37).
            let shown = ImagePoint(x: (0.39 - crop.x) / crop.width * viewport.width,
                y: (0.37 - crop.y) / crop.height * viewport.height)
            let restored = try XCTUnwrap(CameraPreviewGeometry.sensorPoint(viewPoint: shown,
                viewportWidth: viewport.width, viewportHeight: viewport.height, displayTransform: transform))
            XCTAssertEqual(restored.x, source.x, accuracy: 1e-12)
            XCTAssertEqual(restored.y, source.y, accuracy: 1e-12)
            let forward = try XCTUnwrap(CameraPreviewGeometry.displayPoint(sensorPoint: source,
                viewportWidth: viewport.width, viewportHeight: viewport.height, displayTransform: transform))
            XCTAssertEqual(forward.x, shown.x, accuracy: 1e-10)
            XCTAssertEqual(forward.y, shown.y, accuracy: 1e-10)
        }
    }

    func testSelectingAndPersistingARatioPreservesOriginalRGBDepthCalibrationAndZoom() throws {
        for zoom in [1.0, 2.0] {
            let original = try snapshot(zoom: zoom)
            for orientation in ImageOrientation.allCases {
                for ratio in MeasurementPhotoAspectRatio.allCases {
                    var selected = original
                    selected.frame.orientation = orientation
                    selected.presentationCrop = try XCTUnwrap(ratio.displayCrop(imageSize: selected.frame.imageSize,
                        orientation: orientation))
                    let restored = try JSONDecoder().decode(CaptureSnapshot.self, from: JSONEncoder().encode(selected))
                    XCTAssertEqual(restored.presentationCrop, selected.presentationCrop)
                    XCTAssertEqual(restored.imageJPEG, original.imageJPEG)
                    XCTAssertEqual(restored.frame.sessionID, original.frame.sessionID)
                    XCTAssertEqual(restored.frame.frameID, original.frame.frameID)
                    XCTAssertEqual(restored.frame.imageSize, original.frame.imageSize)
                    XCTAssertEqual(restored.frame.intrinsics, original.frame.intrinsics)
                    XCTAssertEqual(restored.frame.depth.size, original.frame.depth.size)
                    XCTAssertEqual(restored.frame.depth.values, original.frame.depth.values)
                    XCTAssertEqual(restored.frame.depth.confidence, original.frame.depth.confidence)
                    XCTAssertEqual(restored.frame.orientation, orientation)
                    XCTAssertEqual(restored.cameraSettings, original.cameraSettings)
                }
            }
        }
    }

    func testSelectedRatiosFitExistingPortraitAndLandscapeControlSpace() throws {
        let portrait: [(MeasurementPhotoAspectRatio, CameraPhotoViewport)] = [
            (.fourThree, .init(x: 0, y: 146, width: 402, height: 536)),
            (.sixteenNine, .init(x: 50.25, y: 146, width: 301.5, height: 536)),
            (.square, .init(x: 0, y: 213, width: 402, height: 402))
        ]
        for (ratio, expected) in portrait {
            XCTAssertEqual(CameraPhotoViewport.layout(containerWidth: 402, containerHeight: 874,
                photoAspectRatio: ratio.displayRatio(isLandscape: false)), expected)
        }
        let landscape: [(MeasurementPhotoAspectRatio, CameraPhotoViewport)] = [
            (.fourThree, .init(x: 79, y: 0, width: 536, height: 402)),
            (.sixteenNine, .init(x: 0, y: 5.8125, width: 694, height: 390.375)),
            (.square, .init(x: 146, y: 0, width: 402, height: 402))
        ]
        for (ratio, expected) in landscape {
            let actual = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 874, containerHeight: 402,
                photoAspectRatio: ratio.displayRatio(isLandscape: true)))
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-12)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-12)
            XCTAssertEqual(actual.width, expected.width, accuracy: 1e-12)
            XCTAssertEqual(actual.height, expected.height, accuracy: 1e-12)
        }
    }

    func testInvalidImageDimensionsCannotProduceAnySelectedCrop() {
        for size in [PixelSize(width: 0, height: 10), .init(width: -1, height: 10),
                     .init(width: 10, height: 0), .init(width: 16_385, height: 10),
                     .init(width: Int.max, height: Int.max)] {
            for orientation in ImageOrientation.allCases {
                for ratio in MeasurementPhotoAspectRatio.allCases {
                    XCTAssertNil(ratio.displayCrop(imageSize: size, orientation: orientation))
                }
            }
        }
    }

    func testStrictCaptureCropAndExpandedResultCropPersistWithoutChangingSensorEvidence() throws {
        let original = try snapshot(zoom: 2)
        var selected = original
        let strict = try XCTUnwrap(MeasurementPhotoAspectRatio.sixteenNine.displayCrop(
            imageSize: original.frame.imageSize, orientation: original.frame.orientation))
        selected.capturePresentationCrop = strict
        selected.presentationCrop = strict.including(displayPoints: [.init(x: 0.02, y: 0.5),
                                                                     .init(x: 0.98, y: 0.5)])
        XCTAssertTrue(selected.hasExpandedPhotoPresentation)
        let restored = try JSONDecoder().decode(CaptureSnapshot.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(restored.capturePresentationCrop, strict)
        XCTAssertEqual(restored.presentationCrop, selected.presentationCrop)
        XCTAssertTrue(restored.hasExpandedPhotoPresentation)
        XCTAssertEqual(restored.imageJPEG, original.imageJPEG)
        XCTAssertEqual(restored.frame.imageSize, original.frame.imageSize)
        XCTAssertEqual(restored.frame.sessionID, original.frame.sessionID)
        XCTAssertEqual(restored.frame.frameID, original.frame.frameID)
        XCTAssertEqual(restored.frame.orientation, original.frame.orientation)
        XCTAssertEqual(restored.frame.intrinsics, original.frame.intrinsics)
        XCTAssertEqual(restored.frame.depth.size, original.frame.depth.size)
        XCTAssertEqual(restored.frame.depth.values, original.frame.depth.values)
        XCTAssertEqual(restored.frame.depth.confidence, original.frame.depth.confidence)
        XCTAssertEqual(restored.cameraSettings, original.cameraSettings)
    }

    func testExpansionNoticeIgnoresIdenticalAndSubToleranceGeometryButChecksEveryComponent() throws {
        var value = try snapshot(zoom: 1)
        let selected = PhotoDisplayCrop(x: 0, y: 0, width: 0.5, height: 0.5)
        value.capturePresentationCrop = selected
        value.presentationCrop = selected
        XCTAssertFalse(value.hasExpandedPhotoPresentation)
        for delta in [0.0, 0.9e-6, 1e-6] {
            value.presentationCrop = .init(x: delta, y: 0, width: 0.5, height: 0.5)
            XCTAssertFalse(value.hasExpandedPhotoPresentation,
                           "A difference no greater than 1e-6 must not produce an informational notice")
        }
        let components: [WritableKeyPath<PhotoDisplayCrop, Double>] = [\.x, \.y, \.width, \.height]
        for component in components {
            var displayed = selected
            displayed[keyPath: component] += 1.1e-6
            value.presentationCrop = displayed
            XCTAssertTrue(value.hasExpandedPhotoPresentation)
        }
    }

    func testMissingOrInvalidCropMetadataCannotInventAnExpandedPhotoNotice() throws {
        var value = try snapshot(zoom: 1)
        value.presentationCrop = .full
        XCTAssertNil(value.capturePresentationCrop)
        XCTAssertFalse(value.hasExpandedPhotoPresentation)
        value.capturePresentationCrop = .full
        value.presentationCrop = nil
        XCTAssertFalse(value.hasExpandedPhotoPresentation)
        let invalid = [PhotoDisplayCrop(x: 0, y: 0, width: 2, height: 1),
                       .init(x: -0.1, y: 0, width: 0.5, height: 0.5),
                       .init(x: .nan, y: 0, width: 0.5, height: 0.5)]
        for crop in invalid {
            value.capturePresentationCrop = crop
            value.presentationCrop = .full
            XCTAssertFalse(value.hasExpandedPhotoPresentation)
            value.capturePresentationCrop = .full
            value.presentationCrop = crop
            XCTAssertFalse(value.hasExpandedPhotoPresentation)
        }
    }

    func testOlderSnapshotWithoutStrictCaptureCropRemainsDecodableAndUnlabelled() throws {
        var value = try snapshot(zoom: 2)
        value.capturePresentationCrop = .init(x: 0.125, y: 0, width: 0.75, height: 1)
        value.presentationCrop = .full
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "capturePresentationCrop")
        let decoded = try JSONDecoder().decode(CaptureSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.capturePresentationCrop)
        XCTAssertEqual(decoded.presentationCrop, .full)
        XCTAssertFalse(decoded.hasExpandedPhotoPresentation)
        XCTAssertEqual(decoded.cameraSettings, value.cameraSettings)
        XCTAssertEqual(decoded.frame.depth.values, value.frame.depth.values)
        XCTAssertEqual(decoded.frame.intrinsics, value.frame.intrinsics)
    }

    private func assertCrop(_ actual: PhotoDisplayCrop, _ expected: PhotoDisplayCrop,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(actual.isValid, file: file, line: line)
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-12, file: file, line: line)
    }

    private func snapshot(zoom: Double) throws -> CaptureSnapshot {
        let imageSize = PixelSize(width: 64, height: 48)
        let depthSize = PixelSize(width: 16, height: 12)
        let registered = try XCTUnwrap(RegisteredCameraCrop.make(imageSize: imageSize,
            depthSize: depthSize, zoomFactor: zoom))
        let depth = DepthMap(size: depthSize, values: (0..<(16 * 12)).map { 1 + Float($0) / 1000 },
            confidence: (0..<(16 * 12)).map { UInt8($0 % 3) })
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 123, capturedAt: .now,
            imageSize: registered.imageSize,
            intrinsics: try XCTUnwrap(registered.applying(to: .init(fx: 80, fy: 82, cx: 30, cy: 22,
                referenceSize: imageSize))), depth: try XCTUnwrap(registered.applying(to: depth)),
            source: .synthetic, orientation: .right)
        return .init(frame: frame, imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            cameraSettings: .init(settingsRevision: 4, focusSensorPoint: .init(x: 0.4, y: 0.45),
                requestedExposureBias: 0.2, acceptedExposureBias: 0.15, requestedZoomFactor: zoom, crop: registered))
    }
}

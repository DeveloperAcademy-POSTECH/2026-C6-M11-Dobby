import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Analytic normalized transforms stand in for ARKit displayTransform. These
/// tests do not establish the physical capture device's focus response.
final class CameraPreviewGeometryTests: XCTestCase {
    private let rotations: [CameraAffineTransform] = [
        .identity,
        .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0),
        .init(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1),
        .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
    ]

    private func assertPoint(_ actual: ImagePoint?, _ expected: ImagePoint,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try XCTUnwrap(actual, file: file, line: line)
        XCTAssertEqual(value.x, expected.x, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(value.y, expected.y, accuracy: 1e-10, file: file, line: line)
    }

    func testAllFourRotationsMapOffCenterTapToTheSameRawSensorPoint() throws {
        let sensor = ImagePoint(x: 0.23, y: 0.71)
        // Independent explicit rotation expectations, rather than values
        // produced by the geometry function under test.
        let normalizedDisplay: [ImagePoint] = [
            sensor, .init(x: 0.29, y: 0.23), .init(x: 0.77, y: 0.29), .init(x: 0.71, y: 0.77)
        ]
        for (transform, display) in zip(rotations, normalizedDisplay) {
            let pixels = ImagePoint(x: display.x * 300, y: display.y * 600)
            try assertPoint(CameraPreviewGeometry.sensorPoint(viewPoint: pixels,
                viewportWidth: 300, viewportHeight: 600, displayTransform: transform), sensor)
            try assertPoint(CameraPreviewGeometry.displayPoint(sensorPoint: sensor,
                viewportWidth: 300, viewportHeight: 600, displayTransform: transform), pixels)
        }
    }

    func testAsymmetricAspectFillCropIsInvertedRatherThanApplyingRotationAlone() throws {
        let crop = CameraAffineTransform(a: 1.8, b: 0, c: 0, d: 1.25, tx: -0.3, ty: -0.1)
        let sensor = ImagePoint(x: 0.37, y: 0.62)
        let pixels = ImagePoint(x: 0.366 * 390, y: 0.675 * 750)
        try assertPoint(CameraPreviewGeometry.sensorPoint(viewPoint: pixels,
            viewportWidth: 390, viewportHeight: 750, displayTransform: crop), sensor)
        try assertPoint(CameraPreviewGeometry.displayPoint(sensorPoint: sensor,
            viewportWidth: 390, viewportHeight: 750, displayTransform: crop), pixels)
    }

    func testRotatedCropUsesActualEnlargedViewCoordinatesWithoutApplyingZoomTwice() throws {
        // Right rotation followed by independently specified x/y aspect-fill.
        let transform = CameraAffineTransform(a: 0, b: 1.2, c: -1.5, d: 0, tx: 1.25, ty: -0.1)
        let expected = ImagePoint(x: 0.2, y: 0.7)
        for scale in [1.0, 2.0] {
            let width = 390 * scale, height = 700 * scale
            try assertPoint(CameraPreviewGeometry.sensorPoint(
                viewPoint: .init(x: 0.2 * width, y: 0.14 * height),
                viewportWidth: width, viewportHeight: height, displayTransform: transform), expected)
        }
    }

    func testMirrorTransformIsAppliedExactlyOnce() throws {
        let mirror = CameraAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
        try assertPoint(CameraPreviewGeometry.sensorPoint(viewPoint: .init(x: 320, y: 130),
            viewportWidth: 400, viewportHeight: 200, displayTransform: mirror), .init(x: 0.2, y: 0.65))
        try assertPoint(CameraPreviewGeometry.displayPoint(sensorPoint: .init(x: 0.2, y: 0.65),
            viewportWidth: 400, viewportHeight: 200, displayTransform: mirror), .init(x: 320, y: 130))
    }

    func testExactViewEdgesRemainSampleableAndRoundTripForEveryRotation() throws {
        let corners: [ImagePoint] = [.init(x: 0, y: 0), .init(x: 400, y: 0),
                                     .init(x: 0, y: 250), .init(x: 400, y: 250)]
        for transform in rotations {
            for corner in corners {
                let sensor = try XCTUnwrap(CameraPreviewGeometry.sensorPoint(viewPoint: corner,
                    viewportWidth: 400, viewportHeight: 250, displayTransform: transform))
                XCTAssertTrue(sensor.isValid)
                try assertPoint(CameraPreviewGeometry.displayPoint(sensorPoint: sensor,
                    viewportWidth: 400, viewportHeight: 250, displayTransform: transform), corner)
            }
        }
        let edge = try XCTUnwrap(CameraPreviewGeometry.sensorPoint(viewPoint: .init(x: 400, y: 250),
            viewportWidth: 400, viewportHeight: 250, displayTransform: .identity))
        XCTAssertEqual(edge, .init(x: 1.0.nextDown, y: 1.0.nextDown))
    }

    func testLetterboxTapAndCroppedOutIndicatorAreRejectedInsteadOfClamped() throws {
        let letterbox = CameraAffineTransform(a: 0.5, b: 0, c: 0, d: 1, tx: 0.25, ty: 0)
        XCTAssertNil(CameraPreviewGeometry.sensorPoint(viewPoint: .init(x: 20, y: 100),
            viewportWidth: 200, viewportHeight: 200, displayTransform: letterbox))
        try assertPoint(CameraPreviewGeometry.sensorPoint(viewPoint: .init(x: 100, y: 100),
            viewportWidth: 200, viewportHeight: 200, displayTransform: letterbox), .init(x: 0.5, y: 0.5))
        let fill = CameraAffineTransform(a: 2, b: 0, c: 0, d: 1, tx: -0.5, ty: 0)
        XCTAssertNil(CameraPreviewGeometry.displayPoint(sensorPoint: .init(x: 0.05, y: 0.5),
            viewportWidth: 200, viewportHeight: 200, displayTransform: fill))
        try assertPoint(CameraPreviewGeometry.sensorPoint(viewPoint: .init(x: 0, y: 100),
            viewportWidth: 200, viewportHeight: 200, displayTransform: fill), .init(x: 0.25, y: 0.5))
    }

    func testInvalidTapViewportAndNonfiniteOrSingularTransformsCannotCreateFocusPoints() {
        for point in [ImagePoint(x: -.infinity, y: 0), .init(x: .nan, y: 100),
                      .init(x: 100, y: .infinity), .init(x: -1, y: 10),
                      .init(x: 401, y: 100), .init(x: 100, y: 251)] {
            XCTAssertNil(CameraPreviewGeometry.sensorPoint(viewPoint: point,
                viewportWidth: 400, viewportHeight: 250, displayTransform: .identity))
        }
        for (width, height) in [(0.0, 250.0), (-1, 250), (400, 0), (Double.nan, 250), (400, Double.infinity)] {
            XCTAssertNil(CameraPreviewGeometry.sensorPoint(viewPoint: .init(x: 10, y: 10),
                viewportWidth: width, viewportHeight: height, displayTransform: .identity))
        }
        let invalid: [CameraAffineTransform] = [
            .init(a: 1, b: 2, c: 2, d: 4, tx: 0, ty: 0),
            .init(a: 1, b: 1, c: 1, d: 1 + 1e-14, tx: 0, ty: 0),
            .init(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0),
            .init(a: 1, b: 0, c: 0, d: 1, tx: .infinity, ty: 0)
        ]
        for transform in invalid {
            XCTAssertNil(CameraPreviewGeometry.sensorPoint(viewPoint: .init(x: 200, y: 125),
                viewportWidth: 400, viewportHeight: 250, displayTransform: transform))
            XCTAssertNil(CameraPreviewGeometry.displayPoint(sensorPoint: .init(x: 0.5, y: 0.5),
                viewportWidth: 400, viewportHeight: 250, displayTransform: transform))
        }
    }
}

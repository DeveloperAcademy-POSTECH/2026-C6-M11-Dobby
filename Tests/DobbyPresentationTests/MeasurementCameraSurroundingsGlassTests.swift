import SwiftUI
import XCTest
@testable import Dobby

@MainActor
final class MeasurementCameraSurroundingsGlassTests: XCTestCase {
    private let canvas = CGRect(x: 0, y: 0, width: 402, height: 874)

    func testNativeGlassRimIsOutsideEveryVisibleCanvasEdge() throws {
        for canvas in [self.canvas, CGRect(x: 0, y: 0, width: 874, height: 402),
                       CGRect(x: 0, y: 0, width: 375, height: 667),
                       CGRect(x: 0, y: 0, width: 1024, height: 1366),
                       CGRect(x: 12, y: 24, width: 402, height: 874)] {
            let pane = try XCTUnwrap(MeasurementCameraSurroundingsSurface.paneFrame(in: canvas))
            XCTAssertTrue(pane.contains(canvas))
            XCTAssertEqual(pane.midX, canvas.midX)
            XCTAssertEqual(pane.midY, canvas.midY)
            // Keep refraction/highlight sampling well off-screen, rather
            // than only clipping an edge drawn exactly on the canvas border.
            XCTAssertGreaterThanOrEqual(canvas.minX - pane.minX, 64)
            XCTAssertGreaterThanOrEqual(canvas.minY - pane.minY, 64)
            XCTAssertGreaterThanOrEqual(pane.maxX - canvas.maxX, 64)
            XCTAssertGreaterThanOrEqual(pane.maxY - canvas.maxY, 64)
        }
    }

    func testInvalidCanvasDoesNotCreateAnOverscannedGlassLayer() {
        XCTAssertNil(MeasurementCameraSurroundingsSurface.paneFrame(in: .zero))
        XCTAssertNil(MeasurementCameraSurroundingsSurface.paneFrame(
            in: .init(x: 0, y: 0, width: CGFloat.nan, height: 874)))
        XCTAssertNil(MeasurementCameraSurroundingsSurface.paneFrame(
            in: .init(x: CGFloat.infinity, y: 0, width: 402, height: 874)))
    }

    func testGlassMaskLeavesEveryPhotoRatioClearAndCoversTheShutterChrome() {
        let photos: [CGRect] = [
            .init(x: 0, y: 146, width: 402, height: 536),
            .init(x: 0, y: 56, width: 402, height: 402 * 16 / 9),
            .init(x: 0, y: 213, width: 402, height: 402)
        ]
        for photo in photos {
            let mask = MeasurementCameraSurroundingsMask(photoRect: photo).path(in: canvas)
            XCTAssertFalse(mask.contains(.init(x: photo.midX, y: photo.midY), eoFill: true))
            XCTAssertFalse(mask.contains(.init(x: photo.minX + 1, y: photo.minY + 1), eoFill: true))
            XCTAssertFalse(mask.contains(.init(x: photo.maxX - 1, y: photo.maxY - 1), eoFill: true))
            XCTAssertTrue(mask.contains(.init(x: canvas.midX, y: 24), eoFill: true))
            XCTAssertTrue(mask.contains(.init(x: canvas.midX, y: canvas.maxY - 24), eoFill: true))
        }
        // Landscape can have both side and bottom controls. The hole follows
        // the actual camera rectangle instead of assuming top/bottom bars.
        let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
        let photo = CGRect(x: 79, y: 0, width: 536, height: 402)
        let mask = MeasurementCameraSurroundingsMask(photoRect: photo).path(in: landscape)
        XCTAssertTrue(mask.contains(.init(x: 20, y: 200), eoFill: true))
        XCTAssertTrue(mask.contains(.init(x: 780, y: 200), eoFill: true))
        XCTAssertFalse(mask.contains(.init(x: 340, y: 200), eoFill: true))
    }

    func testMaskClipsAnOversizedPhotoToTheCanvasWithoutDrawingOutsideIt() {
        let oversized = CGRect(x: -40, y: 100, width: 482, height: 600)
        let mask = MeasurementCameraSurroundingsMask(photoRect: oversized).path(in: canvas)
        XCTAssertFalse(mask.contains(.init(x: 20, y: 200), eoFill: true))
        XCTAssertFalse(mask.contains(.init(x: 400, y: 200), eoFill: true))
        XCTAssertTrue(mask.contains(.init(x: 200, y: 50), eoFill: true))
        XCTAssertTrue(mask.contains(.init(x: 200, y: 850), eoFill: true))
        XCTAssertFalse(mask.contains(.init(x: -1, y: 50), eoFill: true))
        XCTAssertFalse(mask.contains(.init(x: 403, y: 50), eoFill: true))

        let full = MeasurementCameraSurroundingsMask(photoRect: canvas).path(in: canvas)
        XCTAssertFalse(full.contains(.init(x: 201, y: 437), eoFill: true))
        XCTAssertFalse(full.contains(.init(x: 1, y: 1), eoFill: true))
        let emptyCanvas = MeasurementCameraSurroundingsMask(photoRect: oversized).path(in: .zero)
        XCTAssertTrue(emptyCanvas.isEmpty)
    }

    func testRatioAnimationKeepsTheGlassHoleOnEveryIntermediatePhotoRectangle() {
        let from = CGRect(x: 0, y: 146, width: 402, height: 536)
        let to = CGRect(x: 0, y: 213, width: 402, height: 402)
        for fraction: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let expected = CGRect(x: from.minX + (to.minX - from.minX) * fraction,
                y: from.minY + (to.minY - from.minY) * fraction,
                width: from.width + (to.width - from.width) * fraction,
                height: from.height + (to.height - from.height) * fraction)
            var view = MeasurementCameraSurroundingsGlass(photoRect: from)
            view.animatableData = .init(.init(expected.minX, expected.minY), .init(expected.width, expected.height))
            XCTAssertEqual(view.photoRect, expected)
            var shape = MeasurementCameraSurroundingsMask(photoRect: from)
            shape.animatableData = view.animatableData
            let mask = shape.path(in: canvas)
            XCTAssertTrue(mask.contains(.init(x: expected.midX, y: expected.minY - 0.5), eoFill: true))
            XCTAssertFalse(mask.contains(.init(x: expected.midX, y: expected.minY + 0.5), eoFill: true))
            XCTAssertFalse(mask.contains(.init(x: expected.midX, y: expected.maxY - 0.5), eoFill: true))
            XCTAssertTrue(mask.contains(.init(x: expected.midX, y: expected.maxY + 0.5), eoFill: true))
        }
    }
}

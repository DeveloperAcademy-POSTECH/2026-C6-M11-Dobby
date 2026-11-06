import CoreGraphics
import XCTest
@testable import Dobby

/// Display-coordinate regressions only; these do not validate depth or physical measurements.
@MainActor
final class MeasurementPhotoViewportTests: XCTestCase {
    private let size = CGSize(width: 400, height: 300)
    private let crop = PhotoDisplayCrop(x: 0.1, y: 0.2, width: 0.8, height: 0.6)

    func testCroppedRotatedOriginalPointsRoundTripThroughTheZoomedViewport() throws {
        let viewport = MeasurementPhotoViewport(scale: 3, offset: .init(width: -280, height: -210))
        // Independently calculated from the visible crop: each normalized display
        // step of 0.1 spans 50 photo points on either axis, before viewport zoom.
        let examples: [(original: ImagePoint, orientation: ImageOrientation,
                        photo: CGPoint, screen: CGPoint)] = [
            (.init(x: 0.32, y: 0.41), .up, .init(x: 110, y: 105), .init(x: 50, y: 105)),
            (.init(x: 0.32, y: 0.41), .right, .init(x: 245, y: 60), .init(x: 455, y: -30)),
            (.init(x: 0.32, y: 0.41), .down, .init(x: 290, y: 195), .init(x: 590, y: 375)),
            (.init(x: 0.32, y: 0.41), .left, .init(x: 155, y: 240), .init(x: 185, y: 510)),
            (.init(x: 0.63, y: 0.57), .up, .init(x: 265, y: 185), .init(x: 515, y: 345)),
            (.init(x: 0.63, y: 0.57), .right, .init(x: 165, y: 215), .init(x: 215, y: 435)),
            (.init(x: 0.63, y: 0.57), .down, .init(x: 135, y: 115), .init(x: 125, y: 135)),
            (.init(x: 0.63, y: 0.57), .left, .init(x: 235, y: 85), .init(x: 425, y: 45))
        ]
        for example in examples {
            let photo = GarmentPhotoGeometry.screenPoint(example.original, photoSize: size,
                orientation: example.orientation, displayCrop: crop)
            assertPoint(photo, example.photo)
            let screen = viewport.screenPoint(for: photo)
            assertPoint(screen, example.screen)
            let recoveredPhoto = viewport.photoPoint(for: screen)
            assertPoint(recoveredPhoto, example.photo)
            let recoveredOriginal = try XCTUnwrap(GarmentPhotoGeometry.originalPoint(at: recoveredPhoto,
                photoSize: size, orientation: example.orientation, displayCrop: crop))
            assertOriginal(recoveredOriginal, example.original)
            XCTAssertTrue(recoveredOriginal.isValid)
        }
    }

    func testThirtyPointScreenDragBecomesTenPhotoPointsAtThreeTimesZoomInEveryOrientation() throws {
        let original = ImagePoint(x: 0.32, y: 0.41)
        // These offsets place the same original pixel at (200, 150) in each
        // rotation, safely inside the screen so edge clamping cannot hide errors.
        let examples: [(orientation: ImageOrientation, offset: CGSize, photo: CGPoint,
                        zoomedOriginal: ImagePoint, unzoomedOriginal: ImagePoint)] = [
            (.up, .init(width: -130, height: -165), .init(x: 110, y: 105),
             .init(x: 0.34, y: 0.398), .init(x: 0.38, y: 0.374)),
            (.right, .init(width: -535, height: -30), .init(x: 245, y: 60),
             .init(x: 0.308, y: 0.39), .init(x: 0.284, y: 0.35)),
            (.down, .init(width: -670, height: -435), .init(x: 290, y: 195),
             .init(x: 0.30, y: 0.422), .init(x: 0.26, y: 0.446)),
            (.left, .init(width: -265, height: -570), .init(x: 155, y: 240),
             .init(x: 0.332, y: 0.43), .init(x: 0.356, y: 0.47))
        ]
        for example in examples {
            let viewport = MeasurementPhotoViewport(scale: 3, offset: example.offset).clamped(to: size)
            let startPhoto = GarmentPhotoGeometry.screenPoint(original, photoSize: size,
                orientation: example.orientation, displayCrop: crop)
            assertPoint(viewport.screenPoint(for: startPhoto), .init(x: 200, y: 150))
            let draggedPhoto = viewport.photoPoint(for: .init(x: 230, y: 132))
            assertPoint(draggedPhoto, .init(x: example.photo.x + 10, y: example.photo.y - 6))
            let zoomedOriginal = try XCTUnwrap(GarmentPhotoGeometry.originalPoint(at: draggedPhoto,
                photoSize: size, orientation: example.orientation, displayCrop: crop))
            assertOriginal(zoomedOriginal, example.zoomedOriginal)

            let unzoomedOriginal = try XCTUnwrap(GarmentPhotoGeometry.originalPoint(
                at: .init(x: startPhoto.x + 30, y: startPhoto.y - 18), photoSize: size,
                orientation: example.orientation, displayCrop: crop))
            assertOriginal(unzoomedOriginal, example.unzoomedOriginal)
            XCTAssertEqual(zoomedOriginal.x - original.x,
                (unzoomedOriginal.x - original.x) / 3, accuracy: 1e-12)
            XCTAssertEqual(zoomedOriginal.y - original.y,
                (unzoomedOriginal.y - original.y) / 3, accuracy: 1e-12)
        }
    }

    func testCroppedImageAndOverlayRectanglesShareTheSameTransform() {
        let viewport = MeasurementPhotoViewport(scale: 3, offset: .init(width: -280, height: -210))
        let photoRect = GarmentPhotoGeometry.photoRect(photoSize: size, displayCrop: crop)
        assertRect(photoRect, .init(x: -50, y: -100, width: 500, height: 500))
        let screenRect = viewport.screenRect(for: photoRect)
        assertRect(screenRect, .init(x: -430, y: -510, width: 1500, height: 1500))
        assertRect(viewport.photoRect(for: screenRect), photoRect)

        let overlayRect = CGRect(x: 110, y: 105, width: 40, height: 24)
        let screenOverlay = viewport.screenRect(for: overlayRect)
        assertRect(screenOverlay, .init(x: 50, y: 105, width: 120, height: 72))
        assertRect(viewport.photoRect(for: screenOverlay), overlayRect)
        assertPoint(screenOverlay.origin, viewport.screenPoint(for: overlayRect.origin))
    }

    func testMovingPinchCentroidKeepsItsOriginalPhotoAnchorAwayFromEdges() {
        let start = MeasurementPhotoViewport(scale: 2, offset: .init(width: -100, height: -60))
        let pinched = start.applyingPinch(magnification: 1.5, from: .init(x: 160, y: 120),
            to: .init(x: 185, y: 150), in: size)
        XCTAssertEqual(pinched.scale, 3)
        XCTAssertEqual(pinched.offset, .init(width: -205, height: -120))
        assertPoint(start.photoPoint(for: .init(x: 160, y: 120)), .init(x: 130, y: 90))
        assertPoint(pinched.screenPoint(for: .init(x: 130, y: 90)), .init(x: 185, y: 150))
        assertPoint(pinched.photoPoint(for: .init(x: 185, y: 150)), .init(x: 130, y: 90))
    }

    func testPanAndPinchStopAtOneAndFourTimesWithoutExposingAnEmptyEdge() {
        let identity = MeasurementPhotoViewport()
        XCTAssertFalse(identity.isZoomed)
        XCTAssertEqual(identity.applyingPan(.init(width: 80, height: -60), in: size), identity)
        let zoomed = identity.applyingPinch(magnification: 10, from: .init(x: 100, y: 75),
            to: .init(x: 100, y: 75), in: size)
        XCTAssertEqual(zoomed.scale, 4)
        XCTAssertEqual(MeasurementPhotoViewport.maximumScale, 4)
        XCTAssertEqual(zoomed.offset, .init(width: -300, height: -225))
        XCTAssertTrue(zoomed.isZoomed)

        let farEdge = zoomed.applyingPan(.init(width: -10_000, height: -10_000), in: size)
        XCTAssertEqual(farEdge.offset, .init(width: -1200, height: -900))
        let farImage = farEdge.screenRect(for: .init(origin: .zero, size: size))
        XCTAssertEqual(farImage.maxX, 400, accuracy: 1e-9)
        XCTAssertEqual(farImage.maxY, 300, accuracy: 1e-9)
        let nearEdge = farEdge.applyingPan(.init(width: 10_000, height: 10_000), in: size)
        XCTAssertEqual(nearEdge.offset, .zero)
        assertPoint(nearEdge.screenRect(for: .init(origin: .zero, size: size)).origin, .zero)

        let reset = farEdge.applyingPinch(magnification: 0.01, from: .init(x: 100, y: 75),
            to: .init(x: 130, y: 90), in: size)
        XCTAssertEqual(reset, identity)
        XCTAssertEqual(MeasurementPhotoViewport(scale: 0.5, offset: .init(width: -80, height: 20))
            .clamped(to: size), identity)
        XCTAssertEqual(MeasurementPhotoViewport(scale: 9, offset: .init(width: -5000, height: 20))
            .clamped(to: size), .init(scale: 4, offset: .init(width: -1200, height: 0)))
    }

    func testInvalidGestureValuesPreserveTheCurrentClampedViewport() {
        let viewport = MeasurementPhotoViewport(scale: 3, offset: .init(width: -280, height: -210))
        for translation in [CGSize(width: .nan, height: 0), CGSize(width: 0, height: .infinity)] {
            XCTAssertEqual(viewport.applyingPan(translation, in: size), viewport)
        }
        for magnification: CGFloat in [.nan, .infinity, 0, -1] {
            XCTAssertEqual(viewport.applyingPinch(magnification: magnification,
                from: .init(x: 160, y: 120), to: .init(x: 185, y: 150), in: size), viewport)
        }
        for point in [CGPoint(x: .nan, y: 100), CGPoint(x: 100, y: .infinity)] {
            XCTAssertEqual(viewport.applyingPinch(magnification: 1.2,
                from: point, to: .init(x: 185, y: 150), in: size), viewport)
            XCTAssertEqual(viewport.applyingPinch(magnification: 1.2,
                from: .init(x: 160, y: 120), to: point, in: size), viewport)
            assertPoint(viewport.screenPoint(for: point), .zero)
            assertPoint(viewport.photoPoint(for: point), .zero)
        }
    }

    func testInvalidStateOrLayoutRecoversToFiniteIdentityGeometry() {
        let identity = MeasurementPhotoViewport()
        let invalidStates = [
            MeasurementPhotoViewport(scale: .nan), MeasurementPhotoViewport(scale: .infinity),
            MeasurementPhotoViewport(scale: 3, offset: .init(width: .nan, height: -30)),
            MeasurementPhotoViewport(scale: 3, offset: .init(width: -30, height: .infinity))
        ]
        for viewport in invalidStates {
            XCTAssertEqual(viewport.clamped(to: size), identity)
            assertPoint(viewport.screenPoint(for: .init(x: 25, y: 45)), .init(x: 25, y: 45))
            assertPoint(viewport.photoPoint(for: .init(x: 25, y: 45)), .init(x: 25, y: 45))
        }
        let viewport = MeasurementPhotoViewport(scale: 3, offset: .init(width: -280, height: -210))
        let invalidSizes: [CGSize] = [.zero, .init(width: -1, height: 300),
            .init(width: .nan, height: 300), .init(width: 400, height: .infinity)]
        for invalidSize in invalidSizes {
            XCTAssertEqual(viewport.clamped(to: invalidSize), identity)
            XCTAssertEqual(viewport.applyingPan(.init(width: 20, height: -10), in: invalidSize), identity)
            XCTAssertEqual(viewport.applyingPinch(magnification: 2, from: .init(x: 100, y: 80),
                to: .init(x: 110, y: 90), in: invalidSize), identity)
        }
        for rect in [CGRect.null, CGRect(x: 0, y: 0, width: .infinity, height: 10)] {
            assertRect(viewport.screenRect(for: rect), .zero)
            assertRect(viewport.photoRect(for: rect), .zero)
        }
    }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, file: file, line: line)
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        assertPoint(actual.origin, expected.origin, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1e-9, file: file, line: line)
    }

    private func assertOriginal(_ actual: ImagePoint, _ expected: ImagePoint,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-12, file: file, line: line)
    }
}

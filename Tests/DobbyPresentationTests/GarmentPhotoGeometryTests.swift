import CoreGraphics
import XCTest
@testable import Dobby

/// Display-only geometry checks. These do not validate garment detection,
/// depth quality or physical measurement accuracy.
@MainActor
final class GarmentPhotoGeometryTests: XCTestCase {
    func testProcessingPhotoFillsPortraitAndLandscapeWithoutRevealingTheFullFrame() {
        let portrait = GarmentPhotoGeometry.aspectFillRect(photoAspectRatio: 3.0 / 4,
            viewportSize: .init(width: 402, height: 874))
        XCTAssertEqual(portrait.minX, -126.75, accuracy: 0.001)
        XCTAssertEqual(portrait.minY, 0, accuracy: 0.001)
        XCTAssertEqual(portrait.width, 655.5, accuracy: 0.001)
        XCTAssertEqual(portrait.height, 874, accuracy: 0.001)
        let landscape = GarmentPhotoGeometry.aspectFillRect(photoAspectRatio: 4.0 / 3,
            viewportSize: .init(width: 874, height: 402))
        XCTAssertEqual(landscape.minX, 0, accuracy: 0.001)
        XCTAssertEqual(landscape.minY, -126.75, accuracy: 0.001)
        XCTAssertEqual(landscape.width, 874, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 655.5, accuracy: 0.001)
    }

    func testProcessingPhotoDoesNotApplyTwoXAgainToAnAlreadyRegisteredSnapshot() {
        let size = CGSize(width: 402, height: 874)
        let original = GarmentPhotoGeometry.aspectFillRect(photoAspectRatio: 1440.0 / 1920, viewportSize: size)
        let registeredTwoX = GarmentPhotoGeometry.aspectFillRect(photoAspectRatio: 720.0 / 960, viewportSize: size)
        XCTAssertEqual(original, registeredTwoX)
        XCTAssertEqual(GarmentPhotoGeometry.aspectFillRect(photoAspectRatio: .nan, viewportSize: size), .zero)
        XCTAssertEqual(GarmentPhotoGeometry.aspectFillRect(photoAspectRatio: 0.75, viewportSize: .zero), .zero)
    }

    func testProcessingPhotoPreservesTheCapturedWindowWhenThePhoneRotates() {
        let captured = CGSize(width: 402, height: 874)
        let original = GarmentPhotoGeometry.processingPhotoLayout(photoAspectRatio: 0.75,
            capturedViewportSize: captured, viewportSize: captured)
        let rotated = GarmentPhotoGeometry.processingPhotoLayout(photoAspectRatio: 0.75,
            capturedViewportSize: captured, viewportSize: .init(width: 874, height: 402))
        XCTAssertEqual(original.viewportRect, CGRect(origin: .zero, size: captured))
        XCTAssertEqual(rotated.viewportRect.midX, 437, accuracy: 0.001)
        XCTAssertEqual(rotated.viewportRect.height, 402, accuracy: 0.001)
        // The normalized source visible through the clip remains identical,
        // rather than widening to include the original photograph's sides.
        for layout in [original, rotated] {
            XCTAssertEqual((layout.viewportRect.minX - layout.photoRect.minX) / layout.photoRect.width,
                126.75 / 655.5, accuracy: 0.00001)
            XCTAssertEqual(layout.viewportRect.width / layout.photoRect.width, 402 / 655.5, accuracy: 0.00001)
        }
    }

    private let photoSizes = [CGSize(width: 390, height: 520), CGSize(width: 640, height: 360)]

    private func expectedDisplay(_ point: ImagePoint, orientation: ImageOrientation) -> CGPoint {
        switch orientation {
        case .up: .init(x: point.x, y: point.y)
        case .right: .init(x: 1 - point.y, y: point.x)
        case .down: .init(x: 1 - point.x, y: 1 - point.y)
        case .left: .init(x: point.y, y: 1 - point.x)
        }
    }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, accuracy: CGFloat = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }

    func testPortraitAndLandscapeScreenPointsFollowOriginalSensorOrientation() {
        let original = ImagePoint(x: 0.19, y: 0.73)
        for size in photoSizes {
            for orientation in ImageOrientation.allCases {
                let display = expectedDisplay(original, orientation: orientation)
                let screen = GarmentPhotoGeometry.screenPoint(original, photoSize: size, orientation: orientation)
                assertPoint(screen, .init(x: display.x * size.width, y: display.y * size.height))
            }
        }
    }

    func testScreenToOriginalRoundTripsOffCentreAndNearEdgePointsInEveryOrientation() throws {
        let points: [ImagePoint] = [
            .init(x: 0.19, y: 0.73), .init(x: 0.000001, y: 0.999999),
            .init(x: 0.999999, y: 0.000001), .init(x: 0, y: 0)
        ]
        for size in photoSizes {
            for orientation in ImageOrientation.allCases {
                for original in points {
                    let screen = GarmentPhotoGeometry.screenPoint(original, photoSize: size, orientation: orientation)
                    let recovered = try XCTUnwrap(GarmentPhotoGeometry.originalPoint(at: screen,
                        photoSize: size, orientation: orientation))
                    XCTAssertEqual(recovered.x, original.x, accuracy: 1e-12)
                    XCTAssertEqual(recovered.y, original.y, accuracy: 1e-12)
                    XCTAssertTrue(recovered.isValid)
                }
            }
        }
    }

    func testCroppedPhotoAndOverlaysReferToTheSameOriginalImagePixel() {
        let crop = PhotoDisplayCrop(x: 0.12, y: 0.18, width: 0.72, height: 0.64)
        for size in photoSizes {
            let imageRect = GarmentPhotoGeometry.photoRect(photoSize: size, displayCrop: crop)
            XCTAssertEqual(imageRect.width, size.width / crop.width, accuracy: 1e-9)
            XCTAssertEqual(imageRect.height, size.height / crop.height, accuracy: 1e-9)
            for fraction in [CGPoint.zero, CGPoint(x: 0.23, y: 0.71), CGPoint(x: 1, y: 1)] {
                let display = ImagePoint(x: crop.x + fraction.x * crop.width,
                    y: crop.y + fraction.y * crop.height)
                let renderedPixel = CGPoint(x: imageRect.minX + display.x * imageRect.width,
                    y: imageRect.minY + display.y * imageRect.height)
                assertPoint(renderedPixel, .init(x: fraction.x * size.width, y: fraction.y * size.height))
                let overlay = GarmentPhotoGeometry.screenPoint(display, photoSize: size,
                    orientation: .up, displayCrop: crop)
                assertPoint(overlay, renderedPixel)
            }
        }
    }

    func testCroppedScreenCoordinatesRoundTripWithoutChangingRawPointsInEveryOrientation() throws {
        let crop = PhotoDisplayCrop(x: 0.12, y: 0.18, width: 0.72, height: 0.64)
        let originals = [ImagePoint(x: 0.3, y: 0.4), ImagePoint(x: 0.7, y: 0.6)]
        for size in photoSizes {
            for orientation in ImageOrientation.allCases {
                for original in originals {
                    let display = expectedDisplay(original, orientation: orientation)
                    let screen = GarmentPhotoGeometry.screenPoint(original, photoSize: size,
                        orientation: orientation, displayCrop: crop)
                    assertPoint(screen, .init(x: (display.x - crop.x) / crop.width * size.width,
                        y: (display.y - crop.y) / crop.height * size.height))
                    let recovered = try XCTUnwrap(GarmentPhotoGeometry.originalPoint(at: screen,
                        photoSize: size, orientation: orientation, displayCrop: crop))
                    XCTAssertEqual(recovered.x, original.x, accuracy: 1e-12)
                    XCTAssertEqual(recovered.y, original.y, accuracy: 1e-12)
                    XCTAssertTrue(recovered.isValid)
                }
            }
        }
    }

    func testCroppedOutsideDragsClampToVisibleEdgesBeforeUndoingEveryRotation() throws {
        let crop = PhotoDisplayCrop(x: 0.16, y: 0.19, width: 0.68, height: 0.62)
        let displayCorners = [CGPoint(x: crop.x, y: crop.y), CGPoint(x: crop.x + crop.width, y: crop.y),
            CGPoint(x: crop.x + crop.width, y: crop.y + crop.height), CGPoint(x: crop.x, y: crop.y + crop.height)]
        for size in photoSizes {
            let outside = [CGPoint(x: -100, y: -100), CGPoint(x: size.width + 100, y: -100),
                CGPoint(x: size.width + 100, y: size.height + 100), CGPoint(x: -100, y: size.height + 100)]
            let visibleCorners = [CGPoint.zero, CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
            for orientation in ImageOrientation.allCases {
                for (index, location) in outside.enumerated() {
                    let raw = try XCTUnwrap(GarmentPhotoGeometry.originalPoint(at: location,
                        photoSize: size, orientation: orientation, displayCrop: crop))
                    assertPoint(expectedDisplay(raw, orientation: orientation), displayCorners[index])
                    assertPoint(GarmentPhotoGeometry.screenPoint(raw, photoSize: size,
                        orientation: orientation, displayCrop: crop), visibleCorners[index])
                    XCTAssertTrue(raw.isValid)
                }
            }
        }
    }

    func testCroppedMagnifierKeepsThreeTimesVisibleScaleAndCrosshairOnTheOriginalPixel() {
        let crop = PhotoDisplayCrop(x: 0.14, y: 0.21, width: 0.72, height: 0.58)
        for size in photoSizes {
            let loupe = GarmentPhotoGeometry.magnifierRect(photoSize: size).size
            for orientation in ImageOrientation.allCases {
                for original in [ImagePoint(x: 0.3, y: 0.4), ImagePoint(x: 0.7, y: 0.6)] {
                    let display = expectedDisplay(original, orientation: orientation)
                    let layout = GarmentPhotoGeometry.magnifier(displayPoint: .init(x: display.x, y: display.y),
                        photoSize: size, loupeSize: loupe, displayCrop: crop)
                    XCTAssertEqual(layout.imageSize.width, size.width / crop.width * 3, accuracy: 1e-9)
                    XCTAssertEqual(layout.imageSize.height, size.height / crop.height * 3, accuracy: 1e-9)
                    assertPoint(.init(x: (layout.crosshair.x - layout.imageOrigin.x) / layout.imageSize.width,
                        y: (layout.crosshair.y - layout.imageOrigin.y) / layout.imageSize.height),
                        display, accuracy: 1e-12)
                    assertPoint(layout.crosshair, .init(x: loupe.width / 2, y: loupe.height / 2))
                }
            }
        }
    }

    func testExplicitFullCropMatchesLegacyPhotoGeometryAndInvalidCropsCannotMovePoints() throws {
        let point = ImagePoint(x: 0.31, y: 0.67)
        let size = photoSizes[0]
        XCTAssertEqual(GarmentPhotoGeometry.photoRect(photoSize: size), CGRect(origin: .zero, size: size))
        for orientation in ImageOrientation.allCases {
            let legacy = GarmentPhotoGeometry.screenPoint(point, photoSize: size, orientation: orientation)
            XCTAssertEqual(legacy, GarmentPhotoGeometry.screenPoint(point, photoSize: size,
                orientation: orientation, displayCrop: .full))
            XCTAssertEqual(GarmentPhotoGeometry.originalPoint(at: legacy, photoSize: size, orientation: orientation),
                GarmentPhotoGeometry.originalPoint(at: legacy, photoSize: size, orientation: orientation, displayCrop: .full))
            for crop in [PhotoDisplayCrop(x: 0, y: 0, width: 0, height: 1),
                         PhotoDisplayCrop(x: .nan, y: 0, width: 1, height: 1),
                         PhotoDisplayCrop(x: 0.5, y: 0, width: 1, height: 1)] {
                XCTAssertNil(GarmentPhotoGeometry.originalPoint(at: .init(x: 50, y: 80),
                    photoSize: size, orientation: orientation, displayCrop: crop))
            }
        }
    }

    func testOutsideDragsClampInOriginalCoordinatesAfterEveryRotation() throws {
        let upper = Double(1).nextDown
        let expected: [ImageOrientation: [ImagePoint]] = [
            .up: [.init(x: 0, y: 0), .init(x: upper, y: 0), .init(x: upper, y: upper), .init(x: 0, y: upper)],
            .right: [.init(x: 0, y: upper), .init(x: 0, y: 0), .init(x: upper, y: 0), .init(x: upper, y: upper)],
            .down: [.init(x: upper, y: upper), .init(x: 0, y: upper), .init(x: 0, y: 0), .init(x: upper, y: 0)],
            .left: [.init(x: upper, y: 0), .init(x: upper, y: upper), .init(x: 0, y: upper), .init(x: 0, y: 0)]
        ]
        for size in photoSizes {
            let outside = [CGPoint(x: -100, y: -100), CGPoint(x: size.width + 100, y: -100),
                CGPoint(x: size.width + 100, y: size.height + 100), CGPoint(x: -100, y: size.height + 100)]
            let exactEdges = [CGPoint.zero, CGPoint(x: size.width, y: 0),
                CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
            for orientation in ImageOrientation.allCases {
                for locations in [outside, exactEdges] {
                    for (index, location) in locations.enumerated() {
                        let original = try XCTUnwrap(GarmentPhotoGeometry.originalPoint(at: location,
                            photoSize: size, orientation: orientation))
                        let corner = try XCTUnwrap(expected[orientation]?[index])
                        XCTAssertEqual(original.x, corner.x)
                        XCTAssertEqual(original.y, corner.y)
                        XCTAssertTrue(original.isValid, "Rotation must never leave an exact 1 for depth sampling")
                    }
                }
            }
        }
    }

    func testInvalidPhotoOrDragGeometryDoesNotProduceMeasurementCoordinates() {
        let invalidSizes: [CGSize] = [
            .zero, .init(width: -1, height: 520), .init(width: 390, height: 0),
            .init(width: CGFloat.infinity, height: 520), .init(width: 390, height: CGFloat.nan)
        ]
        for orientation in ImageOrientation.allCases {
            for size in invalidSizes {
                XCTAssertNil(GarmentPhotoGeometry.originalPoint(at: .init(x: 40, y: 60),
                    photoSize: size, orientation: orientation))
            }
            for location in [CGPoint(x: CGFloat.nan, y: 10), CGPoint(x: 10, y: CGFloat.infinity)] {
                XCTAssertNil(GarmentPhotoGeometry.originalPoint(at: location,
                    photoSize: photoSizes[0], orientation: orientation))
            }
        }
    }

    private func assertMagnifier(_ layout: GarmentPhotoGeometry.MagnifierLayout,
                                 display: CGPoint, photoSize: CGSize, loupeSize: CGSize,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let coordinates = [layout.imageSize.width, layout.imageSize.height, layout.imageOrigin.x,
            layout.imageOrigin.y, layout.crosshair.x, layout.crosshair.y]
        XCTAssertTrue(coordinates.allSatisfy(\.isFinite), file: file, line: line)
        XCTAssertEqual(layout.imageSize.width, photoSize.width * 3, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(layout.imageSize.height, photoSize.height * 3, accuracy: 1e-9, file: file, line: line)

        // The enlarged image covers the complete loupe, including near edges.
        XCTAssertLessThanOrEqual(layout.imageOrigin.x, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.imageOrigin.y, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.imageOrigin.x + layout.imageSize.width + 1e-9, loupeSize.width,
            file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.imageOrigin.y + layout.imageSize.height + 1e-9, loupeSize.height,
            file: file, line: line)
        // Edge subtraction on sub-point viewports can differ by one floating
        // representation step; allow no visually meaningful overflow.
        XCTAssertGreaterThanOrEqual(layout.crosshair.x, -1e-9, file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.crosshair.y, -1e-9, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.crosshair.x, loupeSize.width + 1e-9, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.crosshair.y, loupeSize.height + 1e-9, file: file, line: line)

        // Recover the selected image pixel from the crosshair. Clamping a crop
        // must move the crosshair with the pixel rather than silently recenter it.
        assertPoint(.init(x: (layout.crosshair.x - layout.imageOrigin.x) / layout.imageSize.width,
                          y: (layout.crosshair.y - layout.imageOrigin.y) / layout.imageSize.height),
            display, accuracy: 1e-12, file: file, line: line)
    }

    func testHiFiMagnifierUsesSeventySixByOneHundredSevenInsetForNormalPhotos() {
        for size in photoSizes + [CGSize(width: 120, height: 150), CGSize(width: 402, height: 560)] {
            XCTAssertEqual(GarmentPhotoGeometry.magnifierRect(photoSize: size),
                CGRect(x: 20, y: 19, width: 76, height: 107))
        }
    }

    func testCompactMagnifierFitsSmallPortraitAndLandscapePhotosWithoutDistortion() {
        let cases: [(photo: CGSize, expected: CGRect)] = [
            (.init(width: 90, height: 220), .init(x: 20, y: 19, width: 50, height: 107.0 * 50 / 76)),
            (.init(width: 220, height: 100), .init(x: 20, y: 19, width: 76.0 * 62 / 107, height: 62)),
            (.init(width: 20, height: 30), .init(x: 9.5, y: 14.5, width: 76.0 / 107, height: 1)),
            (.init(width: 1, height: 1), .init(x: 0, y: 0, width: 76.0 / 107, height: 1))
        ]
        for item in cases {
            let rect = GarmentPhotoGeometry.magnifierRect(photoSize: item.photo)
            XCTAssertEqual(rect.minX, item.expected.minX, accuracy: 1e-9)
            XCTAssertEqual(rect.minY, item.expected.minY, accuracy: 1e-9)
            XCTAssertEqual(rect.width, item.expected.width, accuracy: 1e-9)
            XCTAssertEqual(rect.height, item.expected.height, accuracy: 1e-9)
        }
        for size in cases.map(\.photo) + [CGSize(width: 60, height: 60), CGSize(width: 0.25, height: 0.5)] {
            let rect = GarmentPhotoGeometry.magnifierRect(photoSize: size)
            XCTAssertTrue([rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite))
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertLessThanOrEqual(rect.width, 76)
            XCTAssertLessThanOrEqual(rect.height, 107)
            XCTAssertEqual(rect.width / rect.height, 76.0 / 107, accuracy: 1e-12)
            XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -1e-9, dy: -1e-9).contains(rect),
                "The viewport must stay inside even a photo smaller than its usual inset.")
        }
    }

    func testInvalidPhotoSizeDoesNotProduceAnOffscreenMagnifierRect() {
        for size in [CGSize.zero, CGSize(width: -1, height: 520), CGSize(width: 390, height: 0),
                     CGSize(width: CGFloat.infinity, height: 520), CGSize(width: 390, height: CGFloat.nan)] {
            XCTAssertEqual(GarmentPhotoGeometry.magnifierRect(photoSize: size), .zero)
        }
    }

    func testInteriorMagnifierCentresSelectedPixelWithoutDistortingPhoto() {
        for size in photoSizes {
            let loupe = GarmentPhotoGeometry.magnifierRect(photoSize: size).size
            let selected = ImagePoint(x: 0.37, y: 0.62)
            let layout = GarmentPhotoGeometry.magnifier(displayPoint: selected, photoSize: size, loupeSize: loupe)
            assertMagnifier(layout, display: .init(x: selected.x, y: selected.y), photoSize: size, loupeSize: loupe)
            assertPoint(layout.crosshair, .init(x: loupe.width / 2, y: loupe.height / 2))
            XCTAssertEqual(layout.imageSize.width / layout.imageSize.height,
                size.width / size.height, accuracy: 1e-12)
        }
    }

    func testMagnifierCornersAndEdgesKeepCrosshairOnTheSamePixelForEveryOrientation() {
        let upper = Double(1).nextDown
        let originals: [ImagePoint] = [
            .init(x: 0, y: 0), .init(x: upper, y: 0), .init(x: upper, y: upper), .init(x: 0, y: upper),
            .init(x: 0, y: 0.45), .init(x: upper, y: 0.55), .init(x: 0.35, y: 0), .init(x: 0.65, y: upper)
        ]
        for size in photoSizes + [CGSize(width: 90, height: 220), CGSize(width: 220, height: 100),
                                  CGSize(width: 20, height: 30), CGSize(width: 1, height: 1)] {
            let loupe = GarmentPhotoGeometry.magnifierRect(photoSize: size).size
            for orientation in ImageOrientation.allCases {
                for original in originals {
                    let display = expectedDisplay(original, orientation: orientation)
                    let layout = GarmentPhotoGeometry.magnifier(displayPoint: .init(x: display.x, y: display.y),
                        photoSize: size, loupeSize: loupe)
                    assertMagnifier(layout, display: display, photoSize: size, loupeSize: loupe)
                    if display.x == 0 { XCTAssertEqual(layout.crosshair.x, 0, accuracy: 1e-9) }
                    if display.y == 0 { XCTAssertEqual(layout.crosshair.y, 0, accuracy: 1e-9) }
                    if display.x == 1 { XCTAssertEqual(layout.crosshair.x, loupe.width, accuracy: 1e-9) }
                    if display.y == 1 { XCTAssertEqual(layout.crosshair.y, loupe.height, accuracy: 1e-9) }
                }
            }
        }
    }

    func testCaptionAvoidsTheCompactMagnifierRectangleUsedByRendering() throws {
        let size = photoSizes[0], label = CGSize(width: 80, height: 24)
        let loupe = GarmentPhotoGeometry.magnifierRect(photoSize: size)
        XCTAssertEqual(loupe.size, CGSize(width: 76, height: 107))
        let occupied = [loupe.insetBy(dx: -4, dy: -4)]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(
            start: .init(x: 35, y: 70), end: .init(x: 205, y: 70), labelSize: label,
            imageSize: size, occupied: occupied))
        XCTAssertFalse(placement.rect.intersects(occupied[0].insetBy(dx: -3, dy: -3)),
            "A capsule's complete touch area must avoid the actual compact viewport while it is visible.")
        XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4).contains(placement.rect))
    }

    func testLabelTouchRectAvoidsPointHandlesMagnifierAndOtherLabels() throws {
        let size = CGSize(width: 390, height: 520), label = CGSize(width: 112, height: 44)
        let handles = [CGPoint(x: 185, y: 200), CGPoint(x: 265, y: 320)].map {
            CGRect(x: $0.x - 22, y: $0.y - 22, width: 44, height: 44)
        }
        let loupe = CGRect(x: 8, y: 8, width: 116, height: 157)
        var occupied = handles + [loupe, CGRect(x: size.width - 56, y: 8, width: 48, height: 48)]
        for middle in [CGPoint(x: 185, y: 200), CGPoint(x: 50, y: 60), CGPoint(x: 265, y: 320)] {
            let placed = try XCTUnwrap(GarmentPhotoGeometry.labelPlacement(near: middle, labelSize: label,
                imageSize: size, occupied: occupied))
            XCTAssertEqual(placed.height, 44, "Reserve the complete touch area, not only its visible capsule")
            XCTAssertEqual(placed.width, label.width)
            XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4).contains(placed))
            XCTAssertTrue([placed.minX, placed.minY, placed.width, placed.height].allSatisfy(\.isFinite))
            for obstacle in occupied {
                XCTAssertFalse(obstacle.insetBy(dx: -3, dy: -3).intersects(placed))
            }
            occupied.append(placed)
        }
    }

    func testLabelUsesFiniteInBoundsHitRectNearAllPhotoEdges() throws {
        for size in photoSizes {
            for label in [CGSize(width: 112, height: 44), CGSize(width: 142, height: 80)] {
                for middle in [CGPoint(x: -100, y: -100), CGPoint(x: size.width + 100, y: -100),
                    CGPoint(x: size.width + 100, y: size.height + 100), CGPoint(x: -100, y: size.height + 100)] {
                    let placed = try XCTUnwrap(GarmentPhotoGeometry.labelPlacement(near: middle, labelSize: label,
                        imageSize: size, occupied: []))
                    XCTAssertEqual(placed.size, label)
                    XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4).contains(placed))
                    XCTAssertTrue([placed.minX, placed.minY, placed.width, placed.height].allSatisfy(\.isFinite))
                }
            }
        }
    }

    func testCrowdedOrTooSmallPhotoOmitsLabelInsteadOfCoveringControls() {
        let size = photoSizes[0], label = CGSize(width: 112, height: 44)
        XCTAssertNil(GarmentPhotoGeometry.labelPlacement(near: .init(x: 100, y: 200), labelSize: label,
            imageSize: size, occupied: [CGRect(origin: .zero, size: size)]))
        XCTAssertNil(GarmentPhotoGeometry.labelPlacement(near: .zero, labelSize: label,
            imageSize: .init(width: 110, height: 50), occupied: []))
    }

    private func markerRect(_ point: CGPoint) -> CGRect {
        .init(x: point.x - 14, y: point.y - 14, width: 28, height: 28)
    }

    private func assertPlacement(_ placement: GarmentPhotoGeometry.SegmentLabelPlacement,
                                 visibleLabel: CGSize, imageSize: CGSize, occupied: [CGRect],
                                 file: StaticString = #filePath, line: UInt = #line) {
        let rect = placement.rect
        XCTAssertEqual(rect.width, visibleLabel.width, file: file, line: line)
        XCTAssertEqual(rect.height, max(44, visibleLabel.height), file: file, line: line)
        XCTAssertTrue([rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), file: file, line: line)
        XCTAssertTrue(CGRect(origin: .zero, size: imageSize).insetBy(dx: 4, dy: 4).contains(rect),
            file: file, line: line)
        for obstacle in occupied {
            XCTAssertFalse(obstacle.insetBy(dx: -3, dy: -3).intersects(rect), file: file, line: line)
        }
    }

    func testLongHorizontalSegmentPlacesVisibleCaptionImmediatelyAboveItsMidpoint() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        let start = CGPoint(x: 50, y: 240), end = CGPoint(x: 340, y: 240)
        let occupied = [markerRect(start), markerRect(end)]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: occupied))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: occupied)
        XCTAssertFalse(placement.isCallout)
        XCTAssertEqual(placement.rect.midX, (start.x + end.x) / 2, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.midY + label.height / 2, start.y - 4, accuracy: 1e-9,
            "The small visible capsule sits above its segment while its touch area stays 44 points high")
        XCTAssertGreaterThan(placement.rect.minX, start.x)
        XCTAssertLessThan(placement.rect.maxX, end.x)
    }

    func testSegmentCaptionIsStableWhenEndpointOrderIsReversed() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        let segments: [(CGPoint, CGPoint)] = [
            (.init(x: 50, y: 240), .init(x: 340, y: 240)),
            (.init(x: 120, y: 80), .init(x: 120, y: 400)),
            (.init(x: 270, y: 80), .init(x: 270, y: 400)),
            (.init(x: 60, y: 70), .init(x: 330, y: 340)),
            (.init(x: 60, y: 340), .init(x: 330, y: 70)),
            (.init(x: 175, y: 240), .init(x: 215, y: 240))
        ]
        for (start, end) in segments {
            let occupied = [markerRect(start), markerRect(end), CGRect(x: 8, y: 8, width: 86, height: 153)]
            let forward = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
                labelSize: label, imageSize: size, occupied: occupied))
            let reversed = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: end, end: start,
                labelSize: label, imageSize: size, occupied: occupied))
            XCTAssertEqual(forward.rect, reversed.rect)
            XCTAssertEqual(forward.isCallout, reversed.isCallout)
        }
    }

    func testLongVerticalSegmentKeepsCaptionNearTheLineOnItsOuterSide() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        for x: CGFloat in [120, 270] {
            let start = CGPoint(x: x, y: 80), end = CGPoint(x: x, y: 400)
            let occupied = [markerRect(start), markerRect(end)]
            let placement = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
                labelSize: label, imageSize: size, occupied: occupied))
            assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: occupied)
            XCTAssertFalse(placement.isCallout)
            XCTAssertEqual(placement.rect.midY, (start.y + end.y) / 2, accuracy: 1e-9)
            if x < size.width / 2 {
                XCTAssertEqual(placement.rect.maxX, x - 4, accuracy: 1e-9)
            } else {
                XCTAssertEqual(placement.rect.minX, x + 4, accuracy: 1e-9)
            }
        }
    }

    func testLongDiagonalSegmentsKeepCaptionCloseAndPerpendicularToTheMidpoint() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        for (start, end) in [(CGPoint(x: 60, y: 70), CGPoint(x: 330, y: 340)),
                            (CGPoint(x: 60, y: 340), CGPoint(x: 330, y: 70))] {
            let occupied = [markerRect(start), markerRect(end)]
            let placement = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
                labelSize: label, imageSize: size, occupied: occupied))
            assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: occupied)
            XCTAssertFalse(placement.isCallout)
            let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
            let offsetX = placement.rect.midX - (start.x + end.x) / 2
            let offsetY = placement.rect.midY - (start.y + end.y) / 2
            let along = (offsetX * dx + offsetY * dy) / length
            let perpendicular = abs((offsetX * dy - offsetY * dx) / length)
            XCTAssertEqual(along, 0, accuracy: 1e-9)
            XCTAssertGreaterThan(perpendicular, label.height / 2)
            XCTAssertLessThan(perpendicular, 80, "An unobstructed caption should stay beside its own line")
        }
    }

    func testShortSegmentUsesNearbyCalloutWithoutCoveringEitherEndpoint() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        let start = CGPoint(x: 175, y: 240), end = CGPoint(x: 215, y: 240)
        let occupied = [markerRect(start), markerRect(end)]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: occupied))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: occupied)
        XCTAssertTrue(placement.isCallout)
        XCTAssertLessThan(hypot(placement.rect.midX - 195, placement.rect.midY - 240), 100)
    }

    func testBlockedPreferredSideKeepsLongSegmentCaptionOnItsOtherSide() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        let start = CGPoint(x: 50, y: 240), end = CGPoint(x: 340, y: 240)
        let blocker = CGRect(x: 25, y: 175, width: 340, height: 55)
        let occupied = [markerRect(start), markerRect(end), blocker]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: occupied))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: occupied)
        XCTAssertFalse(placement.isCallout)
        XCTAssertEqual(placement.rect.midX, 195, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.midY - label.height / 2, 244, accuracy: 1e-9)
    }

    func testSegmentCalloutAvoidsMagnifierAndOtherCaptionTouchAreas() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        let start = CGPoint(x: 90, y: 100), end = CGPoint(x: 120, y: 100)
        let loupe = CGRect(x: 8, y: 8, width: 116, height: 157)
        let existingCaption = CGRect(x: 135, y: 65, width: 112, height: 44)
        let occupied = [markerRect(start), markerRect(end), loupe, existingCaption]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: occupied))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: occupied)
        XCTAssertTrue(placement.isCallout)
        XCTAssertLessThan(hypot(placement.rect.midX - 105, placement.rect.midY - 100), 180)
    }

    func testSegmentCaptionNearPhotoEdgeStaysInBoundsAndNoRoomOrInvalidInputReturnsNil() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        let start = CGPoint(x: 50, y: 8), end = CGPoint(x: 340, y: 8)
        let occupied = [markerRect(start), markerRect(end)]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: occupied))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: occupied)
        XCTAssertFalse(placement.isCallout)
        XCTAssertGreaterThan(placement.rect.midY, start.y)
        XCTAssertNil(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end, labelSize: label,
            imageSize: size, occupied: [CGRect(origin: .zero, size: size)]))
        XCTAssertNil(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end, labelSize: label,
            imageSize: .init(width: 110, height: 50), occupied: []))
        XCTAssertNil(GarmentPhotoGeometry.segmentLabelPlacement(start: .init(x: CGFloat.nan, y: 50), end: end,
            labelSize: label, imageSize: size, occupied: []))
        XCTAssertNil(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
            labelSize: .init(width: 0, height: 28), imageSize: size, occupied: []))
    }

    func testOverlayLabelsSitDirectlyOnHorizontalVerticalAndDiagonalSegmentMidpoints() throws {
        let size = photoSizes[0], label = CGSize(width: 94, height: 24)
        let segments: [(CGPoint, CGPoint)] = [
            (.init(x: 40, y: 260), .init(x: 350, y: 260)),
            (.init(x: 195, y: 80), .init(x: 195, y: 440)),
            (.init(x: 50, y: 90), .init(x: 340, y: 430)),
            (.init(x: 50, y: 430), .init(x: 340, y: 90))
        ]
        for (start, end) in segments {
            let markers = [markerRect(start), markerRect(end)]
            let placement = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: end,
                labelSize: label, imageSize: size, occupied: [], markers: markers))
            assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: [])
            XCTAssertFalse(placement.isCallout)
            assertPoint(.init(x: placement.rect.midX, y: placement.rect.midY),
                        .init(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
            let visible = CGRect(x: placement.rect.minX, y: placement.rect.midY - label.height / 2,
                                 width: label.width, height: label.height)
            for marker in markers { XCTAssertFalse(visible.intersects(marker.insetBy(dx: -3, dy: -3))) }
            let reversed = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: end, end: start,
                labelSize: label, imageSize: size, occupied: [], markers: markers))
            XCTAssertEqual(placement.rect, reversed.rect)
            XCTAssertEqual(placement.isCallout, reversed.isCallout)
        }
    }

    func testObstructedOverlayMidpointSlidesPreciselyAlongItsOwnLineBeforeUsingCallout() throws {
        let size = photoSizes[0], label = CGSize(width: 70, height: 24)
        let start = CGPoint(x: 25, y: 260), end = CGPoint(x: 365, y: 260)
        let blocker = CGRect(x: 153, y: 238, width: 85, height: 44)
        let markers = [markerRect(start), markerRect(end)]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: [blocker], markers: markers))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: [blocker])
        XCTAssertFalse(placement.isCallout)
        XCTAssertEqual(placement.rect.midY, 260, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.maxX, blocker.minX - 4, accuracy: 1e-9,
            "Find the nearest clear span rather than moving off the measurement line")
        let reversed = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: end, end: start,
            labelSize: label, imageSize: size, occupied: [blocker], markers: markers))
        XCTAssertEqual(placement.rect, reversed.rect)
    }

    func testOverlaySlidingAvoidsLoupeAndPhysicalMarkerAtTheMidpoint() throws {
        let size = photoSizes[0], label = CGSize(width: 94, height: 24)
        let start = CGPoint(x: 90, y: 30), end = CGPoint(x: 90, y: 260)
        let loupe = CGRect(x: 8, y: 8, width: 116, height: 157)
        let markers = [markerRect(start), markerRect(end)]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: [loupe], markers: markers))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: [loupe])
        XCTAssertFalse(placement.isCallout)
        XCTAssertEqual(placement.rect.midX, start.x, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.minY, loupe.maxY + 4, accuracy: 1e-9)

        let horizontalStart = CGPoint(x: 40, y: 350), horizontalEnd = CGPoint(x: 350, y: 350)
        let crossingMarker = markerRect(.init(x: 195, y: 350))
        let allMarkers = [markerRect(horizontalStart), markerRect(horizontalEnd), crossingMarker]
        let shifted = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(
            start: horizontalStart, end: horizontalEnd, labelSize: label, imageSize: size,
            occupied: [], markers: allMarkers))
        XCTAssertFalse(shifted.isCallout)
        XCTAssertEqual(shifted.rect.midY, 350, accuracy: 1e-9)
        let visible = CGRect(x: shifted.rect.minX, y: shifted.rect.midY - label.height / 2,
                             width: label.width, height: label.height)
        for marker in allMarkers { XCTAssertFalse(visible.intersects(marker.insetBy(dx: -3, dy: -3))) }
    }

    func testShortOverlayUsesNearbyCalloutAndAlwaysProtectsBothEndpoints() throws {
        let size = photoSizes[0], label = CGSize(width: 94, height: 24)
        let start = CGPoint(x: 175, y: 240), end = CGPoint(x: 215, y: 240)
        let placement = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: []))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: [])
        XCTAssertTrue(placement.isCallout)
        XCTAssertLessThan(hypot(placement.rect.midX - 195, placement.rect.midY - 240), 100)
        let visible = CGRect(x: placement.rect.minX, y: placement.rect.midY - label.height / 2,
                             width: label.width, height: label.height)
        for point in [start, end] {
            let endpoint = CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
            XCTAssertFalse(visible.intersects(endpoint.insetBy(dx: -3, dy: -3)),
                "Endpoint protection remains even if the caller omits its marker list")
        }
    }

    func testDraggedEndpointShorteningSegmentRepositionsCachedSizeIntoSafeCallout() throws {
        let size = photoSizes[0], cachedLabelSize = CGSize(width: 94, height: 24)
        let start = CGPoint(x: 50, y: 240), initialEnd = CGPoint(x: 340, y: 240)
        let initial = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: initialEnd,
            labelSize: cachedLabelSize, imageSize: size, occupied: [],
            markers: [markerRect(start), markerRect(initialEnd)]))
        XCTAssertFalse(initial.isCallout)
        let currentEnd = CGPoint(x: 80, y: 240)
        let currentMarkers = [markerRect(start), markerRect(currentEnd)]
        let moved = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: currentEnd,
            labelSize: cachedLabelSize, imageSize: size, occupied: [], markers: currentMarkers))
        assertPlacement(moved, visibleLabel: cachedLabelSize, imageSize: size, occupied: [])
        XCTAssertTrue(moved.isCallout, "A formerly inline caption must change placement when the dragged line becomes short")
        let visible = CGRect(x: moved.rect.minX, y: moved.rect.midY - cachedLabelSize.height / 2,
                             width: cachedLabelSize.width, height: cachedLabelSize.height)
        for marker in currentMarkers {
            XCTAssertFalse(visible.intersects(marker.insetBy(dx: -3, dy: -3)))
        }
        XCTAssertEqual(moved.rect.width, initial.rect.width, "Reuse cached string sizing during a drag")
        XCTAssertLessThan(hypot(moved.rect.midX - 65, moved.rect.midY - 240), 100)
    }

    func testDraggedEndpointMovingLineBehindLoupeRepositionsWithoutCoveringLoupeOrCurrentPoints() throws {
        let size = photoSizes[0], cachedLabelSize = CGSize(width: 94, height: 24)
        let start = CGPoint(x: 50, y: 300), initialEnd = CGPoint(x: 340, y: 300)
        let loupe = CGRect(x: 8, y: 8, width: 116, height: 157)
        let initial = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: initialEnd,
            labelSize: cachedLabelSize, imageSize: size, occupied: [loupe],
            markers: [markerRect(start), markerRect(initialEnd)]))
        XCTAssertFalse(initial.isCallout)
        let currentEnd = CGPoint(x: 120, y: 20)
        let currentMiddle = CGPoint(x: (start.x + currentEnd.x) / 2, y: (start.y + currentEnd.y) / 2)
        XCTAssertTrue(loupe.contains(currentMiddle), "The stale midpoint-following strategy would put the caption behind the loupe")
        let currentMarkers = [markerRect(start), markerRect(currentEnd)]
        let moved = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: currentEnd,
            labelSize: cachedLabelSize, imageSize: size, occupied: [loupe], markers: currentMarkers))
        assertPlacement(moved, visibleLabel: cachedLabelSize, imageSize: size, occupied: [loupe])
        let visible = CGRect(x: moved.rect.minX, y: moved.rect.midY - cachedLabelSize.height / 2,
                             width: cachedLabelSize.width, height: cachedLabelSize.height)
        for marker in currentMarkers {
            XCTAssertFalse(visible.intersects(marker.insetBy(dx: -3, dy: -3)))
        }
        XCTAssertEqual(moved.rect.width, initial.rect.width)
        XCTAssertNotEqual(moved.rect.midY, currentMiddle.y)
    }

    func testCrowdedOverlayCalloutAvoidsPreviouslyPlacedLabelAndLoupe() throws {
        let size = photoSizes[0], label = CGSize(width: 104, height: 24)
        let firstStart = CGPoint(x: 40, y: 240), firstEnd = CGPoint(x: 350, y: 240)
        let secondStart = CGPoint(x: 40, y: 248), secondEnd = CGPoint(x: 350, y: 248)
        let markers = [firstStart, firstEnd, secondStart, secondEnd].map(markerRect)
        let loupe = CGRect(x: 8, y: 8, width: 116, height: 157)
        let first = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: firstStart, end: firstEnd,
            labelSize: label, imageSize: size, occupied: [loupe], markers: markers))
        let second = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: secondStart, end: secondEnd,
            labelSize: label, imageSize: size, occupied: [loupe, first.rect], markers: markers))
        assertPlacement(second, visibleLabel: label, imageSize: size, occupied: [loupe, first.rect])
        XCTAssertTrue(second.isCallout)
        XCTAssertLessThan(hypot(second.rect.midX - 195, second.rect.midY - 248), 100)
    }

    func testOverlayTransparentTouchPaddingCanOverlapMarkerWhileVisibleCapsuleCannot() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 22)
        let start = CGPoint(x: 40, y: 240), end = CGPoint(x: 350, y: 240)
        let marker = CGRect(x: 186, y: 257, width: 18, height: 18)
        let placement = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: [], markers: [marker]))
        XCTAssertFalse(placement.isCallout)
        XCTAssertEqual(placement.rect.midX, 195, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.midY, 240, accuracy: 1e-9)
        XCTAssertTrue(placement.rect.intersects(marker))
        let visible = CGRect(x: placement.rect.minX, y: placement.rect.midY - label.height / 2,
                             width: label.width, height: label.height)
        XCTAssertFalse(visible.intersects(marker.insetBy(dx: -3, dy: -3)))
    }

    func testOverlayEdgesCrowdingDegenerateSegmentsAndInvalidInputRemainSafe() throws {
        let size = photoSizes[0], label = CGSize(width: 94, height: 24)
        let start = CGPoint(x: 40, y: 8), end = CGPoint(x: 350, y: 8)
        let edge = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: []))
        assertPlacement(edge, visibleLabel: label, imageSize: size, occupied: [])
        XCTAssertTrue(edge.isCallout, "A line at the photo edge cannot contain a complete caption touch area")
        let coincident = try XCTUnwrap(GarmentPhotoGeometry.overlaySegmentLabelPlacement(
            start: .init(x: 195, y: 260), end: .init(x: 195, y: 260),
            labelSize: label, imageSize: size, occupied: []))
        XCTAssertTrue(coincident.isCallout)
        assertPlacement(coincident, visibleLabel: label, imageSize: size, occupied: [])
        XCTAssertNil(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: [CGRect(origin: .zero, size: size)]))
        XCTAssertNil(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: .init(width: 80, height: 40), occupied: []))
        XCTAssertNil(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: .init(x: CGFloat.nan, y: 10), end: end,
            labelSize: label, imageSize: size, occupied: []))
        XCTAssertNil(GarmentPhotoGeometry.overlaySegmentLabelPlacement(start: start, end: end,
            labelSize: .init(width: 0, height: 24), imageSize: size, occupied: []))
        XCTAssertNil(GarmentPhotoGeometry.overlaySegmentLabelPlacement(
            start: .init(x: -CGFloat.greatestFiniteMagnitude, y: 10),
            end: .init(x: CGFloat.greatestFiniteMagnitude, y: 20),
            labelSize: label, imageSize: size, occupied: []))
    }

    private func hitPath(_ vertices: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        if let first = vertices.first {
            path.move(to: first)
            for point in vertices.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        return path
    }

    func testNearbyPointHitAreaStopsAtBisectorAndProtectsBothMarkerCentres() throws {
        let size = CGSize(width: 56, height: 56), center = CGPoint(x: 28, y: 28)
        let vertices = GarmentPhotoGeometry.pointHitPolygon(size: size, neighborOffsets: [.init(x: 24, y: 0)])
        XCTAssertGreaterThan(vertices.count, 3)
        XCTAssertEqual(try XCTUnwrap(vertices.map(\.x).max()), 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(vertices.map(\.x).min()), 0, accuracy: 1e-9)
        let path = hitPath(vertices)
        XCTAssertTrue(path.contains(center))
        XCTAssertTrue(path.contains(.init(x: center.x + 8, y: center.y)),
            "The visible marker remains inside its own enlarged touch area")
        XCTAssertTrue(path.contains(.init(x: center.x + 11, y: center.y)))
        XCTAssertFalse(path.contains(.init(x: center.x + 13, y: center.y)))
        XCTAssertFalse(path.contains(.init(x: center.x + 24, y: center.y)),
            "This point cannot steal a touch at the neighbouring marker's centre")
    }

    func testSeveralNearbyAndDiagonalPointsConstrainEveryHitPolygonVertexToItsNearestMarker() {
        let size = CGSize(width: 56, height: 56), center = CGPoint(x: 28, y: 28)
        let offsets = [CGPoint(x: 24, y: 0), CGPoint(x: -20, y: 10),
            CGPoint(x: 8, y: -18), CGPoint(x: 18, y: 18)]
        let vertices = GarmentPhotoGeometry.pointHitPolygon(size: size, neighborOffsets: offsets)
        XCTAssertGreaterThan(vertices.count, 3)
        let path = hitPath(vertices)
        XCTAssertTrue(path.contains(center))
        for vertex in vertices {
            XCTAssertTrue(vertex.x.isFinite && vertex.y.isFinite)
            let x = vertex.x - center.x, y = vertex.y - center.y
            let ownSquaredDistance = x * x + y * y
            XCTAssertLessThanOrEqual(ownSquaredDistance, 28 * 28 + 1e-7)
            for neighbor in offsets {
                let otherSquaredDistance = pow(x - neighbor.x, 2) + pow(y - neighbor.y, 2)
                XCTAssertLessThanOrEqual(ownSquaredDistance, otherSquaredDistance + 1e-7,
                    "Every retained vertex must belong to this marker's nearest-point region")
            }
        }
        for neighbor in offsets {
            XCTAssertFalse(path.contains(.init(x: center.x + neighbor.x, y: center.y + neighbor.y)))
        }
    }

    func testFarCoincidentAndInvalidNeighboursLeaveFullHitCircleAndInvalidSizeProducesNoPath() throws {
        let size = CGSize(width: 56, height: 56)
        let circle = GarmentPhotoGeometry.pointHitPolygon(size: size, neighborOffsets: [])
        let unchanged = GarmentPhotoGeometry.pointHitPolygon(size: size, neighborOffsets: [
            .init(x: 56, y: 0), .init(x: 0, y: -90), .zero,
            .init(x: CGFloat.nan, y: 1), .init(x: 1, y: CGFloat.infinity)
        ])
        XCTAssertEqual(unchanged, circle)
        XCTAssertEqual(circle.count, 72)
        let bounds = hitPath(circle).boundingBoxOfPath
        XCTAssertEqual(bounds.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds.width, 56, accuracy: 1e-9)
        XCTAssertEqual(bounds.height, 56, accuracy: 1e-9)
        for invalid in [CGSize.zero, CGSize(width: -1, height: 56),
                        CGSize(width: CGFloat.infinity, height: 56), CGSize(width: 56, height: CGFloat.nan)] {
            XCTAssertTrue(GarmentPhotoGeometry.pointHitPolygon(size: invalid, neighborOffsets: []).isEmpty)
        }
    }

    func testTransparentCaptionTouchPaddingMayOverlapIndicatorWhileVisibleCapsuleStaysBesideLine() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        let start = CGPoint(x: 100, y: 240), end = CGPoint(x: 290, y: 240)
        let indicator = CGRect(x: 186, y: 241, width: 18, height: 18)
        let markers = [CGRect(x: 91, y: 231, width: 18, height: 18),
            CGRect(x: 281, y: 231, width: 18, height: 18), indicator]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: [], markers: markers))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: [])
        let visible = CGRect(x: placement.rect.minX, y: placement.rect.midY - label.height / 2,
            width: label.width, height: label.height)
        XCTAssertFalse(placement.isCallout)
        XCTAssertEqual(placement.rect.midX, 195, accuracy: 1e-9)
        XCTAssertEqual(visible.maxY, 236, accuracy: 1e-9)
        XCTAssertEqual(placement.rect.maxY, 244, accuracy: 1e-9)
        XCTAssertTrue(placement.rect.intersects(indicator),
            "Transparent touch padding should not push an otherwise clear capsule away from its segment")
        for marker in markers {
            XCTAssertFalse(visible.intersects(marker.insetBy(dx: -3, dy: -3)))
        }
    }

    func testMarkerInsideVisibleCaptionMovesItToClearAdjacentOrCalloutPosition() throws {
        let size = photoSizes[0], label = CGSize(width: 112, height: 28)
        let start = CGPoint(x: 100, y: 240), end = CGPoint(x: 290, y: 240)
        let markers = [CGRect(x: 91, y: 231, width: 18, height: 18),
            CGRect(x: 281, y: 231, width: 18, height: 18),
            CGRect(x: 186, y: 213, width: 18, height: 18)]
        let placement = try XCTUnwrap(GarmentPhotoGeometry.segmentLabelPlacement(start: start, end: end,
            labelSize: label, imageSize: size, occupied: [], markers: markers))
        assertPlacement(placement, visibleLabel: label, imageSize: size, occupied: [])
        let visible = CGRect(x: placement.rect.minX, y: placement.rect.midY - label.height / 2,
            width: label.width, height: label.height)
        XCTAssertNotEqual(placement.rect.midY, 222,
            "A real marker under the visible capsule must block the preferred position")
        XCTAssertFalse(placement.isCallout, "This fixture has a clear adjacent position on the opposite side")
        XCTAssertEqual(visible.minY, 244, accuracy: 1e-9)
        for marker in markers {
            XCTAssertFalse(visible.intersects(marker.insetBy(dx: -3, dy: -3)))
        }
    }
}

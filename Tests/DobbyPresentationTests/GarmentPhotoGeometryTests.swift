import CoreGraphics
import XCTest
@testable import Dobby

/// Display-only geometry checks. These do not validate garment detection,
/// depth quality or physical measurement accuracy.
@MainActor
final class GarmentPhotoGeometryTests: XCTestCase {
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
        XCTAssertGreaterThanOrEqual(layout.imageOrigin.x + layout.imageSize.width, loupeSize.width,
            file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.imageOrigin.y + layout.imageSize.height, loupeSize.height,
            file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.crosshair.x, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.crosshair.y, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.crosshair.x, loupeSize.width, file: file, line: line)
        XCTAssertLessThanOrEqual(layout.crosshair.y, loupeSize.height, file: file, line: line)

        // Recover the selected image pixel from the crosshair. Clamping a crop
        // must move the crosshair with the pixel rather than silently recenter it.
        assertPoint(.init(x: (layout.crosshair.x - layout.imageOrigin.x) / layout.imageSize.width,
                          y: (layout.crosshair.y - layout.imageOrigin.y) / layout.imageSize.height),
            display, accuracy: 1e-12, file: file, line: line)
    }

    func testInteriorMagnifierCentresSelectedPixelWithoutDistortingPhoto() {
        let loupe = CGSize(width: 108, height: 124)
        for size in photoSizes {
            let selected = ImagePoint(x: 0.37, y: 0.62)
            let layout = GarmentPhotoGeometry.magnifier(displayPoint: selected, photoSize: size, loupeSize: loupe)
            assertMagnifier(layout, display: .init(x: selected.x, y: selected.y), photoSize: size, loupeSize: loupe)
            assertPoint(layout.crosshair, .init(x: loupe.width / 2, y: loupe.height / 2))
            XCTAssertEqual(layout.imageSize.width / layout.imageSize.height,
                size.width / size.height, accuracy: 1e-12)
        }
    }

    func testMagnifierCornersAndEdgesKeepCrosshairOnTheSamePixelForEveryOrientation() {
        let loupe = CGSize(width: 108, height: 124)
        let upper = Double(1).nextDown
        let originals: [ImagePoint] = [
            .init(x: 0, y: 0), .init(x: upper, y: 0), .init(x: upper, y: upper), .init(x: 0, y: upper),
            .init(x: 0, y: 0.45), .init(x: upper, y: 0.55), .init(x: 0.35, y: 0), .init(x: 0.65, y: upper)
        ]
        for size in photoSizes {
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

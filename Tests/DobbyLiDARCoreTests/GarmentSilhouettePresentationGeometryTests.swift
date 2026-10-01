import XCTest
@testable import DobbyLiDARCore

final class GarmentSilhouettePresentationGeometryTests: XCTestCase {
    private func mask(width: Int = 96, height: Int = 96,
                      foreground: (Int, Int) -> Bool) -> GarmentMask {
        .init(size: .init(width: width, height: height), values: (0..<(width * height)).map {
            foreground($0 % width, $0 / width) ? 1 : 0
        })
    }

    private func shirt() -> GarmentMask {
        mask { x, y in
            let body = (27..<69).contains(x) && (18..<85).contains(y)
            let sleeves = (8..<88).contains(x) && (18..<43).contains(y)
            let neck = (41..<55).contains(x) && y < 30
            return (body || sleeves) && !neck
        }
    }

    func testMalformedAndEmptyMasksKeepExistingContract() throws {
        XCTAssertNil(GarmentSilhouettePresentationGeometry.contours(from:
            .init(size: .init(width: 2, height: 2), values: [0, 1])))
        XCTAssertEqual(try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from:
            mask { _, _ in false })), [])
    }

    func testFixedSamplesRetainNeckArmpitSleevesAndDoNotModifyMeasurementMask() throws {
        let original = shirt()
        let exact = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: original))
        let smooth = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: original))
        XCTAssertEqual(smooth.count, 1)
        XCTAssertEqual(smooth[0].count, 128)
        XCTAssertFalse(contains(.init(x: 48.0 / 96, y: 24.0 / 96), in: smooth[0]), "Neck notch must remain open")
        XCTAssertFalse(contains(.init(x: 20.0 / 96, y: 50.0 / 96), in: smooth[0]), "Armpit concavity must remain outside")
        XCTAssertTrue(contains(.init(x: 15.0 / 96, y: 30.0 / 96), in: smooth[0]), "Sleeve must remain present")
        XCTAssertTrue(contains(.init(x: 48.0 / 96, y: 70.0 / 96), in: smooth[0]))
        XCTAssertEqual(GarmentSilhouetteGeometry.contours(from: original), exact)
        XCTAssertEqual(original, shirt())
        XCTAssertLessThanOrEqual(maximumDeviation(smooth[0], exact[0], size: original.size), 2.001)
    }

    func testHoleAndSeparateComponentRetainTheirWindingAndContainment() throws {
        let original = mask { x, y in
            let ring = (8..<60).contains(x) && (8..<80).contains(y)
                && !((20..<40).contains(x) && (25..<55).contains(y))
            let separate = (75..<88).contains(x) && (50..<75).contains(y)
            return ring || separate
        }
        let exact = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: original))
        let smooth = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: original))
        XCTAssertEqual(smooth.count, 3)
        XCTAssertEqual(smooth.map(\.count), [128, 128, 128])
        XCTAssertEqual(smooth.map { area($0) > 0 }, exact.map { area($0) > 0 })
        let holeIndex = try XCTUnwrap(exact.firstIndex { area($0) < 0 })
        XCTAssertTrue(contains(.init(x: 30.0 / 96, y: 40.0 / 96), in: smooth[holeIndex]))
        XCTAssertNil(GarmentSilhouettePresentationGeometry.aligned(smooth, to: smooth),
                     "Multiple paths and holes require a complete-path fade")
    }

    func testSinglePixelHoleAndDiagonalComponentsDoNotCollapse() throws {
        let hole = mask(width: 16, height: 16) { x, y in
            (2..<14).contains(x) && (2..<14).contains(y) && !(x == 7 && y == 7)
        }
        let loops = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: hole))
        XCTAssertEqual(loops.count, 2)
        XCTAssertTrue(loops.contains { area($0) < 0 && contains(.init(x: 7.5 / 16, y: 7.5 / 16), in: $0) })
        let diagonal = mask(width: 8, height: 8) { x, y in (x == 2 && y == 2) || (x == 3 && y == 3) }
        XCTAssertEqual(try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: diagonal)).count, 2)
    }

    func testStaircaseCurveUsesPixelBoundedSmoothingInAnisotropicRaster() throws {
        let original = mask(width: 256, height: 128) { x, y in
            let nx = (Double(x) + 0.5 - 128) / 90, ny = (Double(y) + 0.5 - 64) / 45
            return nx * nx + ny * ny < 1
        }
        let exact = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: original))[0]
        let smooth = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: original))[0]
        XCTAssertEqual(smooth.count, 128)
        XCTAssertGreaterThan(exact.count, 128)
        XCTAssertLessThanOrEqual(maximumDeviation(smooth, exact, size: original.size), 2.001)
        XCTAssertTrue(smooth.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
    }

    func testDisplayGeometryPreservesShapeAfterEachCardinalRawRotation() throws {
        let original = shirt()
        for orientation in [ImageOrientation.up, .right, .down, .left] {
            let raw = try GarmentMaskOrientation.originalMask(fromUpright: original, orientation: orientation)
            let exact = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: raw))[0]
            let smooth = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: raw))[0]
            XCTAssertLessThanOrEqual(maximumDeviation(smooth, exact, size: raw.size), 2.001)
            let display = smooth.map { ImageCoordinateTransform.originalToDisplay($0, orientation: orientation) }
            XCTAssertFalse(contains(.init(x: 0.5, y: 0.25), in: display))
            XCTAssertTrue(contains(.init(x: 0.5, y: 0.7), in: display))
        }
    }

    func testSlantedShortAndLongSleeveStaircasesFitFixedCapacityWithinDisplayBudget() throws {
        for longSleeves in [false, true] {
            let vertices: [(Double, Double)] = longSleeves
                ? [(200,55),(232,55),(234,75),(256,82),(278,75),(280,55),(312,55),(355,78),
                   (402,147),(457,295),(425,316),(376,183),(346,157),(345,344),(170,344),
                   (168,157),(140,183),(92,316),(58,295),(111,147),(158,78)]
                : [(200,55),(232,55),(234,75),(256,82),(278,75),(280,55),(312,55),(368,100),
                   (395,160),(347,184),(325,145),(345,344),(170,344),(186,145),(163,184),
                   (117,160),(145,100)]
            let polygon = vertices.map { ImagePoint(x: $0.0, y: $0.1) }
            let original = mask(width: 512, height: 384) { x, y in
                self.contains(.init(x: Double(x) + 0.5, y: Double(y) + 0.5), in: polygon)
            }
            let exact = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: original))[0]
            let smooth = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: original))[0]
            XCTAssertEqual(smooth.count, 128)
            XCTAssertGreaterThan(exact.count, 128)
            XCTAssertLessThanOrEqual(maximumDeviation(smooth, exact, size: original.size),
                GarmentSilhouettePresentationGeometry.maximumDisplayDeviationPixels + 0.001)
            XCTAssertFalse(contains(.init(x: 256.0 / 512, y: 65.0 / 384), in: smooth))
            if longSleeves { XCTAssertFalse(contains(.init(x: 152.0 / 512, y: 240.0 / 384), in: smooth)) }
            XCTAssertEqual(original.values, (0..<(512 * 384)).map {
                contains(.init(x: Double($0 % 512) + 0.5, y: Double($0 / 512) + 0.5), in: polygon) ? 1 : 0
            })
        }
    }

    func testExactPreviewPantsHaveStraightCrotchEdgesInsteadOfRasterStaircases() throws {
        let vertices: [ImagePoint] = [.init(x: 0.27, y: 0.15), .init(x: 0.73, y: 0.15),
            .init(x: 0.78, y: 0.87), .init(x: 0.57, y: 0.87), .init(x: 0.50, y: 0.46),
            .init(x: 0.43, y: 0.87), .init(x: 0.22, y: 0.87)]
        let original = mask(width: 400, height: 500) { x, y in
            self.contains(.init(x: (Double(x) + 0.5) / 400, y: (Double(y) + 0.5) / 500), in: vertices)
        }
        let exact = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: original))[0]
        let smooth = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: original))[0]
        let pixels = smooth.map { ImagePoint(x: $0.x * 400, y: $0.y * 500) }
        var checked = 0
        for index in pixels.indices {
            let a = pixels[index], b = pixels[(index + 1) % pixels.count]
            if a.y > 250 && a.y < 415 && b.y > 250 && b.y < 415,
               a.x > 172 && a.x < 228 && b.x > 172 && b.x < 228 {
                let dx = b.x - a.x, dy = b.y - a.y
                let left = (a.x + b.x) / 2 < 200
                let expectedDX = left ? -28.0 : 28.0
                let cosine = abs((dx * expectedDX + dy * 205) / (hypot(dx, dy) * hypot(expectedDX, 205)))
                XCTAssertGreaterThan(cosine, 0.999, "An inner-leg segment must follow the long edge, not a pixel stair")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 12)
        // Seven garment corners plus a possible two-pixel bevel at the raster
        // crotch apex; repeated inner-leg staircase turns are forbidden above.
        XCTAssertLessThanOrEqual(sharpTurns(smooth), 8)
        XCTAssertFalse(contains(.init(x: 0.5, y: 0.6), in: smooth), "The crotch/leg gap must remain open")
        XCTAssertTrue(contains(.init(x: 0.3, y: 0.7), in: smooth))
        XCTAssertLessThanOrEqual(maximumDeviation(smooth, exact, size: original.size), 2.001)
    }

    func testExactPreviewTopShoulderAndSleeveEdgesRemainStraightAndKeepNeckNotch() throws {
        let vertices: [ImagePoint] = [.init(x: 0.41, y: 0.16), .init(x: 0.30, y: 0.23),
            .init(x: 0.075, y: 0.42), .init(x: 0.13, y: 0.52), .init(x: 0.32, y: 0.43),
            .init(x: 0.32, y: 0.84), .init(x: 0.50, y: 0.86), .init(x: 0.68, y: 0.84),
            .init(x: 0.68, y: 0.43), .init(x: 0.87, y: 0.52), .init(x: 0.925, y: 0.42),
            .init(x: 0.70, y: 0.23), .init(x: 0.59, y: 0.16), .init(x: 0.50, y: 0.21)]
        let original = mask(width: 400, height: 500) { x, y in
            self.contains(.init(x: (Double(x) + 0.5) / 400, y: (Double(y) + 0.5) / 500), in: vertices)
        }
        let exact = try XCTUnwrap(GarmentSilhouetteGeometry.contours(from: original))[0]
        let smooth = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: original))[0]
        let pixels = smooth.map { ImagePoint(x: $0.x * 400, y: $0.y * 500) }
        var checked = 0
        for index in pixels.indices {
            let a = pixels[index], b = pixels[(index + 1) % pixels.count]
            if a.x > 45 && a.x < 105 && b.x > 45 && b.x < 105,
               a.y > 125 && a.y < 195 && b.y > 125 && b.y < 195 {
                let dx = b.x - a.x, dy = b.y - a.y
                let cosine = abs((dx * 90 - dy * 95) / (hypot(dx, dy) * hypot(90, 95)))
                XCTAssertGreaterThan(cosine, 0.999)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 4)
        XCTAssertLessThanOrEqual(sharpTurns(smooth), 14)
        XCTAssertFalse(contains(.init(x: 0.5, y: 0.18), in: smooth))
        XCTAssertFalse(contains(.init(x: 0.25, y: 0.60), in: smooth))
        XCTAssertLessThanOrEqual(maximumDeviation(smooth, exact, size: original.size), 2.001)
    }

    func testComplexityLimitRejectsWholeGeometryInsteadOfDiscardingComponents() {
        let fragmented = mask(width: 32, height: 32) { x, y in x.isMultiple(of: 4) && y.isMultiple(of: 4) }
        XCTAssertEqual(GarmentSilhouetteGeometry.contours(from: fragmented)?.count, 64)
        XCTAssertNil(GarmentSilhouettePresentationGeometry.contours(from: fragmented))
    }

    func testPhaseAlignmentPreservesSuccessfulContourUnderDifferentStartingVertex() throws {
        let contour = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: shirt()))[0]
        let shifted = Array(contour[37...]) + Array(contour[..<37])
        XCTAssertEqual(try XCTUnwrap(GarmentSilhouettePresentationGeometry.aligned([shifted], to: [contour])), [contour])
    }

    func testAcceptedSmallMotionMorphHasSimpleQuarterAndMidpointPolygons() throws {
        let contour = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: shirt()))[0]
        let moved = contour.map { ImagePoint(x: $0.x + 0.004, y: $0.y - 0.003) }
        let aligned = try XCTUnwrap(GarmentSilhouettePresentationGeometry.aligned([moved], to: [contour]))[0]
        for fraction in [0.25, 0.5, 0.75] {
            let intermediate = zip(contour, aligned).map {
                ImagePoint(x: $0.0.x + ($0.1.x - $0.0.x) * fraction,
                           y: $0.0.y + ($0.1.y - $0.0.y) * fraction)
            }
            XCTAssertFalse(hasCrossing(intermediate))
            XCTAssertGreaterThan(area(intermediate), 0)
            XCTAssertFalse(contains(.init(x: 0.5 + 0.004 * fraction, y: 0.25 - 0.003 * fraction), in: intermediate))
        }
    }

    func testLargeMovementWindingAndUnsafeEndpointDoNotMorph() throws {
        let contour = try XCTUnwrap(GarmentSilhouettePresentationGeometry.contours(from: shirt()))[0]
        XCTAssertNil(GarmentSilhouettePresentationGeometry.aligned([Array(contour.reversed())], to: [contour]))
        XCTAssertNil(GarmentSilhouettePresentationGeometry.aligned(
            [contour.map { .init(x: $0.x + 0.12, y: $0.y) }], to: [contour]))
        var crossing = contour
        crossing.swapAt(4, 60)
        XCTAssertTrue(hasCrossing(crossing))
        XCTAssertNil(GarmentSilhouettePresentationGeometry.aligned([crossing], to: [contour]))
    }

    private func maximumDeviation(_ first: [ImagePoint], _ second: [ImagePoint], size: PixelSize) -> Double {
        let a = first.map { ImagePoint(x: $0.x * Double(size.width), y: $0.y * Double(size.height)) }
        let b = second.map { ImagePoint(x: $0.x * Double(size.width), y: $0.y * Double(size.height)) }
        func directed(_ points: [ImagePoint], _ polygon: [ImagePoint]) -> Double {
            points.map { point in polygon.indices.map { index in
                let start = polygon[index], end = polygon[(index + 1) % polygon.count]
                let dx = end.x - start.x, dy = end.y - start.y
                let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)))
                return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
            }.min()! }.max()!
        }
        return max(directed(a, b), directed(b, a))
    }

    private func contains(_ p: ImagePoint, in polygon: [ImagePoint]) -> Bool {
        var crossings = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y) { crossings += 1 }
        }
        return !crossings.isMultiple(of: 2)
    }

    private func area(_ polygon: [ImagePoint]) -> Double {
        zip(polygon, Array(polygon.dropFirst()) + [polygon[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y } / 2
    }

    private func hasCrossing(_ polygon: [ImagePoint]) -> Bool {
        func side(_ p: ImagePoint, _ a: ImagePoint, _ b: ImagePoint) -> Double {
            (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)
        }
        for i in 0..<(polygon.count - 2) { for j in (i + 2)..<polygon.count {
            if i == 0 && j == polygon.count - 1 { continue }
            let a = polygon[i], b = polygon[(i + 1) % polygon.count], c = polygon[j], d = polygon[(j + 1) % polygon.count]
            if side(c, a, b) * side(d, a, b) < 0 && side(a, c, d) * side(b, c, d) < 0 { return true }
        } }
        return false
    }

    private func sharpTurns(_ polygon: [ImagePoint]) -> Int {
        polygon.indices.filter { index in
            let before = polygon[(index + polygon.count - 1) % polygon.count]
            let point = polygon[index], after = polygon[(index + 1) % polygon.count]
            let ax = point.x - before.x, ay = point.y - before.y
            let bx = after.x - point.x, by = after.y - point.y
            let cosine = (ax * bx + ay * by) / (hypot(ax, ay) * hypot(bx, by))
            return cosine < cos(30 * .pi / 180)
        }.count
    }
}

import XCTest
@testable import DobbyLiDARCore

final class LiveForegroundPreviewSelectionTests: XCTestCase {
    private let sourceSize = PixelSize(width: 1_000, height: 800)

    private func mask(size: PixelSize = .init(width: 100, height: 80),
                      rectangles: [(Range<Int>, Range<Int>)] = [(20..<80, 16..<64)]) -> GarmentMask {
        var result = GarmentMask(size: size, values: .init(repeating: 0, count: size.width * size.height))
        for (xs, ys) in rectangles {
            for y in ys { for x in xs { result.values[y * size.width + x] = 1 } }
        }
        return result
    }

    private func selection(_ masks: [GarmentMask], imageSize: PixelSize? = nil) -> LiveForegroundPreviewSelection {
        LiveForegroundPreviewSelectionPolicy.select(masks: masks, imageSize: imageSize ?? sourceSize)
    }

    func testSingleForegroundDrawsImmediatelyWithoutAnyMeasurementClaim() {
        let source = mask()
        let selected = selection([source])
        XCTAssertEqual(selected.state, .analyzing)
        XCTAssertEqual(selected.mask, source)
        XCTAssertEqual(selected.bounds, .init(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        let preview = selected.readiness(timestamp: 12)
        XCTAssertEqual(preview.timestamp, 12)
        XCTAssertEqual(preview.silhouette, source)
        XCTAssertFalse(preview.isReady)
        XCTAssertFalse(preview.garmentRecognized)
        XCTAssertNil(preview.recognitionModelVersion)
        XCTAssertNil(preview.garmentKind)
        XCTAssertNil(preview.depthCoverage)
        XCTAssertNil(preview.highConfidenceCoverage)
        XCTAssertNil(preview.boundaryCoverage)
        XCTAssertNil(preview.medianDepthMeters)
    }

    func testNoForegroundClearsOutline() {
        XCTAssertEqual(selection([]).state, .searching)
        let empty = mask(rectangles: [])
        let result = selection([empty])
        XCTAssertEqual(result.state, .searching)
        XCTAssertNil(result.mask)
        XCTAssertNil(result.bounds)
    }

    func testMultipleInstancesNeverPickTheLargestOrIgnoreTinySecondObject() {
        let large = mask()
        let tiny = mask(rectangles: [(85..<88, 30..<33)])
        for masks in [[large, tiny], [tiny, large], [large, large]] {
            let result = selection(masks)
            XCTAssertEqual(result.state, .multipleObjects)
            XCTAssertNil(result.mask)
            XCTAssertFalse(result.readiness(timestamp: 1).isReady)
        }
    }

    func testOneInstanceWithTwoMaterialComponentsRemainsAmbiguous() {
        let result = selection([mask(rectangles: [(20..<40, 20..<60), (60..<80, 20..<60)])])
        XCTAssertEqual(result.state, .multipleObjects)
        XCTAssertNil(result.mask)
    }

    func testHolesAndTinySpecklesArePreservedWithoutFabricatingAContour() {
        var source = mask()
        for y in 30..<50 { for x in 42..<58 { source.values[y * 100 + x] = 0 } }
        source.values[10 * 100 + 10] = 1
        let result = selection([source])
        XCTAssertEqual(result.state, .analyzing)
        XCTAssertEqual(result.mask, source)
        XCTAssertEqual(result.mask?.values[40 * 100 + 50], 0)
        XCTAssertEqual(result.mask?.values[10 * 100 + 10], 1)
    }

    func testClippedForegroundHasNoDisplayedOutline() {
        for source in [mask(rectangles: [(0..<60, 16..<64)]),
                       mask(rectangles: [(20..<80, 0..<48)]),
                       mask(rectangles: [(40..<100, 16..<64)]),
                       mask(rectangles: [(20..<80, 32..<80)])] {
            let result = selection([source])
            XCTAssertEqual(result.state, .clipped)
            XCTAssertNil(result.mask)
        }
    }

    func testTinyAndNearlyWholeFrameMasksDoNotProduceGuide() {
        let tiny = selection([mask(rectangles: [(45..<55, 32..<40)])])
        XCTAssertEqual(tiny.state, .tooSmall)
        XCTAssertNil(tiny.mask)
        let nearlyWhole = selection([mask(rectangles: [(2..<98, 2..<78)])])
        XCTAssertEqual(nearlyWhole.state, .searching)
        XCTAssertNil(nearlyWhole.mask)
    }

    func testInvalidBinaryRasterAndAspectMismatchAreRejected() {
        var truncated = mask()
        truncated.values.removeLast()
        var nonbinary = mask()
        nonbinary.values[500] = 2
        var wrongAspect = mask()
        wrongAspect.size = .init(width: 80, height: 100)
        for source in [truncated, nonbinary, wrongAspect] {
            let result = selection([source])
            XCTAssertEqual(result.state, .analysisFailed)
            XCTAssertNil(result.mask)
        }
        XCTAssertEqual(selection([mask()], imageSize: .init(width: 0, height: 800)).state, .analysisFailed)
    }

    func testOversizedForegroundCannotBypassBoundedPreviewBudget() {
        let oversized = mask(size: .init(width: 1_000, height: 800), rectangles: [(200..<800, 160..<640)])
        let result = selection([oversized])
        XCTAssertEqual(result.state, .analysisFailed)
        XCTAssertNil(result.mask)
    }

    func testPreviewRasterPreservesCompleteCameraAspectWithin512Pixels() {
        let size = LivePreviewRasterGeometry.analysisSize(for: .init(width: 1_920, height: 1_440),
            maximumDimension: LiveForegroundPreviewSelectionPolicy.maximumRasterDimension)
        XCTAssertEqual(size, .init(width: 512, height: 384))
        let portrait = LivePreviewRasterGeometry.analysisSize(for: .init(width: 1_440, height: 1_920),
            maximumDimension: LiveForegroundPreviewSelectionPolicy.maximumRasterDimension)
        XCTAssertEqual(portrait, .init(width: 384, height: 512))
        XCTAssertNil(LivePreviewRasterGeometry.analysisSize(for: .init(width: 4_001, height: 3_001),
            maximumDimension: LiveForegroundPreviewSelectionPolicy.maximumRasterDimension))
    }

    func testOrientationRestorationDoesNotChangeRawMaskOrItsPreviewBounds() throws {
        var raw = mask()
        // An asymmetric hole distinguishes a true quarter-turn restoration
        // from a mirror, the opposite rotation, or an unchanged rectangle.
        for y in 22..<30 { for x in 30..<40 { raw.values[y * 100 + x] = 0 } }
        // An exact clockwise raw->upright quarter turn, as CoreImage presents it.
        var upright = GarmentMask(size: .init(width: 80, height: 100), values: .init(repeating: 0, count: 8_000))
        for y in 0..<80 { for x in 0..<100 { upright.values[x * 80 + (79 - y)] = raw.values[y * 100 + x] } }
        let restored = try GarmentMaskOrientation.originalMask(fromUpright: upright, orientation: .right)
        XCTAssertEqual(restored, raw)
        let result = selection([restored])
        XCTAssertEqual(result.state, .analyzing)
        XCTAssertEqual(result.bounds, .init(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
    }
}

import XCTest
@testable import DobbyLiDARCore

final class LivePreviewRasterGeometryTests: XCTestCase {
    func testCameraFormatsReduceWithoutChangingFullFieldAspectOrUpscaling() throws {
        let cases: [(PixelSize, PixelSize)] = [
            (.init(width: 1920, height: 1440), .init(width: 960, height: 720)),
            (.init(width: 1440, height: 1920), .init(width: 720, height: 960)),
            (.init(width: 1920, height: 1080), .init(width: 960, height: 540)),
            (.init(width: 4032, height: 3024), .init(width: 960, height: 720)),
            (.init(width: 640, height: 480), .init(width: 640, height: 480))
        ]
        for (original, expected) in cases {
            let reduced = try XCTUnwrap(LivePreviewRasterGeometry.analysisSize(for: original))
            XCTAssertEqual(reduced, expected)
            XCTAssertEqual(original.width * reduced.height, original.height * reduced.width)
            XCTAssertLessThanOrEqual(max(reduced.width, reduced.height), 960)
        }
    }

    func testReducedRasterPreservesNormalizedLandmarksInAllOrientations() throws {
        let original = PixelSize(width: 1920, height: 1440)
        let reduced = try XCTUnwrap(LivePreviewRasterGeometry.analysisSize(for: original))
        let point = ImagePoint(x: 0.17, y: 0.68)
        for orientation in ImageOrientation.allCases {
            let full = try BottomLetterboxGeometry(originalSize: original, orientation: orientation)
            let small = try BottomLetterboxGeometry(originalSize: reduced, orientation: orientation)
            let display = ImageCoordinateTransform.originalToDisplay(point, orientation: orientation)
            let fullPoint = try XCTUnwrap(full.originalPoint(modelX: Double(full.padLeft) + display.x * Double(full.resizedSize.width),
                                                            modelY: Double(full.padTop) + display.y * Double(full.resizedSize.height)))
            let smallPoint = try XCTUnwrap(small.originalPoint(modelX: Double(small.padLeft) + display.x * Double(small.resizedSize.width),
                                                              modelY: Double(small.padTop) + display.y * Double(small.resizedSize.height)))
            XCTAssertEqual(fullPoint.x, smallPoint.x, accuracy: 1e-12)
            XCTAssertEqual(fullPoint.y, smallPoint.y, accuracy: 1e-12)
        }
    }

    func testRejectsInvalidOrIrreducibleLargeInputsInsteadOfDistortingTheFrame() {
        XCTAssertNil(LivePreviewRasterGeometry.analysisSize(for: .init(width: 0, height: 480)))
        XCTAssertNil(LivePreviewRasterGeometry.analysisSize(for: .init(width: Int.max, height: 480)))
        XCTAssertNil(LivePreviewRasterGeometry.analysisSize(for: .init(width: 1920, height: 1440), maximumDimension: 0))
        XCTAssertNil(LivePreviewRasterGeometry.analysisSize(for: .init(width: 1009, height: 1013)))
        XCTAssertEqual(LivePreviewRasterGeometry.analysisSize(for: .init(width: 400, height: 533)), .init(width: 400, height: 533))
    }
}

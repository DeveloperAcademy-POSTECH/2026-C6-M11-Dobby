import XCTest
@testable import DobbyLiDARCore

final class GarmentOrientationTransformTests: XCTestCase {
    func testCompositionAndInverseOnRectangularImageAllSixteenDirections() throws {
        let raw = ImagePoint(x: 0.17, y: 0.73)
        for device in ImageOrientation.allCases {
            for correction in GarmentOrientationCorrection.allCases {
                let composed = GarmentOrientationTransform.composed(device: device, correction: correction)
                let devicePoint = ImageCoordinateTransform.originalToDisplay(raw, orientation: device)
                let upright = ImageCoordinateTransform.originalToDisplay(devicePoint, orientation: correction.imageOrientation)
                let combined = ImageCoordinateTransform.originalToDisplay(raw, orientation: composed)
                XCTAssertEqual(combined.x, upright.x, accuracy: 1e-12)
                XCTAssertEqual(combined.y, upright.y, accuracy: 1e-12)
                let restored = ImageCoordinateTransform.displayToOriginal(combined, orientation: composed)
                XCTAssertEqual(restored.x, raw.x, accuracy: 1e-12)
                XCTAssertEqual(restored.y, raw.y, accuracy: 1e-12)
                // Letterbox is the pose's existing one-and-only inverse, using
                // actual per-axis integer resized dimensions on a rectangle.
                let box = try BottomLetterboxGeometry(originalSize: .init(width: 1200, height: 800), orientation: composed)
                let point = try XCTUnwrap(box.originalPoint(
                    modelX: Double(box.padLeft) + combined.x * Double(box.resizedSize.width),
                    modelY: Double(box.padTop) + combined.y * Double(box.resizedSize.height)))
                XCTAssertEqual(point.x, raw.x, accuracy: 1e-12)
                XCTAssertEqual(point.y, raw.y, accuracy: 1e-12)
            }
        }
    }

    func testPredictionChoosesClockwiseCorrectionAndRetainsLowConfidenceTie() throws {
        let tie = try GarmentOrientationPrediction(probabilities: [0: 0.25, 90: 0.25, 180: 0.25, 270: 0.25])
        XCTAssertEqual(tie.correction, .upright)
        XCTAssertEqual(tie.confidence, 0.25)
        XCTAssertEqual(tie.margin, 0)
        let rotated = try GarmentOrientationPrediction(probabilities: [0: 0.1, 90: 0.6, 180: 0.2, 270: 0.1])
        XCTAssertEqual(rotated.correction, .clockwise90)
        XCTAssertEqual(GarmentOrientationTransform.composed(device: .right, correction: rotated.correction), .down)
        for probabilities: [Int: Double] in [[0: 1], [0: 0.2, 90: 0.2, 180: 0.2, 270: 0.2],
                                             [0: .nan, 90: 0.25, 180: 0.25, 270: 0.25]] {
            XCTAssertThrowsError(try GarmentOrientationPrediction(probabilities: probabilities))
        }
    }

    func testRoundHalfUpLetterboxAndFloorPadding() throws {
        // 224 * 3/64 = 10.5: explicitly 11 rather than banker's rounding.
        let box = try GarmentOrientationLetterbox(size: .init(width: 64, height: 3))
        XCTAssertEqual(box.resizedWidth, 224)
        XCTAssertEqual(box.resizedHeight, 11)
        XCTAssertEqual(box.offsetY, 106)
        XCTAssertEqual(224 - box.offsetY - box.resizedHeight, 107)
        XCTAssertEqual(GarmentOrientationLetterbox.padding, 114)
        XCTAssertThrowsError(try GarmentOrientationLetterbox(size: .init(width: 0, height: 3)))
    }

    func testTransformRetainsOutOfImageEvidenceAndNeverSwapsSemanticNames() {
        let outside = ImagePoint(x: -0.1, y: 1.2)
        let transformed = ImageCoordinateTransform.originalToDisplay(outside, orientation: .right)
        let restored = ImageCoordinateTransform.displayToOriginal(transformed, orientation: .right)
        XCTAssertEqual(restored.x, outside.x, accuracy: 1e-12)
        XCTAssertEqual(restored.y, outside.y, accuracy: 1e-12)
        XCTAssertFalse(restored.isValid)
    }
}

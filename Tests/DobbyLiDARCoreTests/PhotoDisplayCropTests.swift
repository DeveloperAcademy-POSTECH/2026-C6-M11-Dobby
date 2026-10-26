import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Pure display geometry: no sensor capture, physical lens selection, or change
/// to the measurement frame is implied by these fabricated dimensions.
final class PhotoDisplayCropTests: XCTestCase {
    private let imageSize = PixelSize(width: 1920, height: 1440)
    private let portraitWindow = NormalizedRect(x: 0, y: 146.0 / 874,
                                               width: 1, height: 536.0 / 874)

    func testPortraitWindowMatchesOnlyTheUnobscuredPreviewRegion() throws {
        let crop = try XCTUnwrap(PhotoDisplayCrop.matchingPreview(imageSize: imageSize, orientation: .right,
            viewportWidth: 402, viewportHeight: 874, visibleRect: portraitWindow))
        XCTAssertTrue(crop.isValid)
        XCTAssertEqual(crop.x, (1 - 536.0 / 874) / 2, accuracy: 1e-12)
        XCTAssertEqual(crop.y, 146.0 / 874, accuracy: 1e-12)
        XCTAssertEqual(crop.width, 536.0 / 874, accuracy: 1e-12)
        XCTAssertEqual(crop.height, 536.0 / 874, accuracy: 1e-12)
        XCTAssertEqual(crop.width * 1440 / (crop.height * 1920), 402.0 / 536, accuracy: 1e-12)
    }

    func testLandscapeWindowExcludesTheTrailingControlColumn() throws {
        let crop = try XCTUnwrap(PhotoDisplayCrop.matchingPreview(imageSize: imageSize, orientation: .up,
            viewportWidth: 874, viewportHeight: 402,
            visibleRect: .init(x: 0, y: 0, width: 694.0 / 874, height: 1)))
        XCTAssertEqual(crop.x, 0, accuracy: 1e-12)
        XCTAssertEqual(crop.y, (1 - 536.0 / 874) / 2, accuracy: 1e-12)
        XCTAssertEqual(crop.width, 694.0 / 874, accuracy: 1e-12)
        XCTAssertEqual(crop.height, 536.0 / 874, accuracy: 1e-12)
    }

    func testAllOrientationsUseOrientedDimensionsWithoutRotatingTheCropTwice() throws {
        var crops: [ImageOrientation: PhotoDisplayCrop] = [:]
        for orientation in ImageOrientation.allCases {
            crops[orientation] = try XCTUnwrap(PhotoDisplayCrop.matchingPreview(imageSize: imageSize,
                orientation: orientation, viewportWidth: 402, viewportHeight: 874,
                visibleRect: portraitWindow))
        }
        XCTAssertEqual(crops[.left], crops[.right])
        XCTAssertEqual(crops[.up], crops[.down])
        XCTAssertNotEqual(crops[.right]?.width, crops[.up]?.width)
        XCTAssertEqual(try XCTUnwrap(crops[.up]).width, 402 * 1440.0 / (874 * 1920), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(crops[.up]).y, try XCTUnwrap(crops[.right]).y, accuracy: 1e-12)
    }

    func testFullMatchingAspectViewportRetainsTheEntirePhotograph() throws {
        for orientation in ImageOrientation.allCases {
            let quarterTurn = orientation == .left || orientation == .right
            let crop = try XCTUnwrap(PhotoDisplayCrop.matchingPreview(imageSize: imageSize,
                orientation: orientation, viewportWidth: quarterTurn ? 300 : 400,
                viewportHeight: quarterTurn ? 400 : 300,
                visibleRect: .init(x: 0, y: 0, width: 1, height: 1)))
            XCTAssertEqual(crop, .full)
        }
    }

    func testRegisteredOneAndTwoXDimensionsHaveTheSameNormalizedDisplayWindow() throws {
        let one = try XCTUnwrap(PhotoDisplayCrop.matchingPreview(imageSize: imageSize, orientation: .right,
            viewportWidth: 402, viewportHeight: 874, visibleRect: portraitWindow))
        let two = try XCTUnwrap(PhotoDisplayCrop.matchingPreview(imageSize: .init(width: 960, height: 720),
            orientation: .right, viewportWidth: 402, viewportHeight: 874, visibleRect: portraitWindow))
        XCTAssertEqual(one, two, "The already registered 2x crop must not be magnified a second time")
    }

    func testInvalidImageViewportAndVisibleWindowNeverProduceACrop() {
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        for size in [PixelSize(width: 0, height: 10), .init(width: -1, height: 10),
                     .init(width: Int.max, height: Int.max)] {
            XCTAssertNil(PhotoDisplayCrop.matchingPreview(imageSize: size, orientation: .up,
                viewportWidth: 402, viewportHeight: 874, visibleRect: full))
        }
        for value in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertNil(PhotoDisplayCrop.matchingPreview(imageSize: imageSize, orientation: .up,
                viewportWidth: value, viewportHeight: 874, visibleRect: full))
            XCTAssertNil(PhotoDisplayCrop.matchingPreview(imageSize: imageSize, orientation: .up,
                viewportWidth: 402, viewportHeight: value, visibleRect: full))
        }
        let invalidRects = [NormalizedRect(x: -0.1, y: 0, width: 1, height: 1),
                            .init(x: 0, y: 0, width: 0, height: 1),
                            .init(x: 0, y: 0, width: 1, height: 0),
                            .init(x: 0.5, y: 0, width: 0.500_000_1, height: 1),
                            .init(x: 0, y: 0, width: 1, height: .nan)]
        for rect in invalidRects {
            XCTAssertNil(PhotoDisplayCrop.matchingPreview(imageSize: imageSize, orientation: .right,
                viewportWidth: 402, viewportHeight: 874, visibleRect: rect))
        }
    }

    func testIncludingPointsExpandsMinimallyAndKeepsEveryValidHandleVisible() {
        let crop = PhotoDisplayCrop(x: 0.3, y: 0.25, width: 0.4, height: 0.5)
        let points = [ImagePoint(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.6),
                      .init(x: 0.5, y: 0.04), .init(x: 0.5, y: 0.98)]
        let expanded = crop.including(displayPoints: points)
        XCTAssertTrue(expanded.isValid)
        XCTAssertEqual(expanded.x, 0.08, accuracy: 1e-12)
        XCTAssertEqual(expanded.y, 0.02, accuracy: 1e-12)
        XCTAssertEqual(expanded.x + expanded.width, 0.92, accuracy: 1e-12)
        XCTAssertEqual(expanded.y + expanded.height, 1, accuracy: 1e-12)
        for point in points {
            XCTAssertGreaterThanOrEqual(point.x, expanded.x)
            XCTAssertLessThanOrEqual(point.x, expanded.x + expanded.width)
            XCTAssertGreaterThanOrEqual(point.y, expanded.y)
            XCTAssertLessThanOrEqual(point.y, expanded.y + expanded.height)
        }
        XCTAssertEqual(crop.including(displayPoints: [.init(x: 0.5, y: 0.5)]), crop)
        XCTAssertEqual(crop.including(displayPoints: []), crop)
    }

    func testIncludingClampsEdgesIgnoresInvalidPointsAndNeverShrinks() {
        let crop = PhotoDisplayCrop(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let expanded = crop.including(displayPoints: [.init(x: 0, y: 0),
                                                     .init(x: 0.999, y: 0.999)])
        XCTAssertEqual(expanded, .full)
        XCTAssertEqual(crop.including(displayPoints: [.init(x: 0, y: 0), .init(x: 1, y: 1)]), .full,
                       "Rotating a valid raw point on the zero edge can produce display coordinate 1")
        let invalid = [ImagePoint(x: .nan, y: 0.5), .init(x: 0.5, y: .infinity),
                       .init(x: -0.1, y: 0.5), .init(x: 1.1, y: 0.5)]
        XCTAssertEqual(crop.including(displayPoints: invalid), crop)
        for padding in [Double.nan, .infinity, -1] {
            let result = crop.including(displayPoints: [.init(x: 0.1, y: 0.5)], padding: padding)
            XCTAssertTrue(result.isValid)
            XCTAssertEqual(result.x, 0.1, accuracy: 1e-12)
            XCTAssertEqual(result.x + result.width, 0.8, accuracy: 1e-12)
        }
    }

    func testCodablePreservesValidWindowAndInvalidImportedGeometryFallsBackToFull() throws {
        let crop = PhotoDisplayCrop(x: 0.2, y: 0.1, width: 0.6, height: 0.7)
        XCTAssertEqual(try JSONDecoder().decode(PhotoDisplayCrop.self,
            from: JSONEncoder().encode(crop)), crop)
        let imported = try JSONDecoder().decode(PhotoDisplayCrop.self,
            from: Data(#"{"x":0,"y":0,"width":2,"height":1}"#.utf8))
        XCTAssertFalse(imported.isValid)
        XCTAssertEqual(imported.including(displayPoints: []), .full)
    }

    func testLegacyCaptureWithoutPresentationCropUsesTheFullPhotograph() throws {
        let snapshot = CaptureSnapshot(frame: SyntheticFixtures.scene().frame, imageJPEG: Data([0x01]))
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "presentationCrop")
        let legacy = try JSONDecoder().decode(CaptureSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.presentationCrop)
        XCTAssertEqual(legacy.presentationCrop ?? .full, .full)
    }
}

import XCTest
@testable import DobbyLiDARCore

final class MeasurementCameraChromeLayoutTests: XCTestCase {
    func testDefaultShutterIsRaisedWithoutTouchingEitherFourByThreeOrTallBorder() throws {
        let shutter = try XCTUnwrap(MeasurementCameraChromeLayout.shutterFrame(containerWidth: 402,
            containerHeight: 874))
        XCTAssertEqual(shutter, .init(x: 155, y: 672, width: 92, height: 92))
        XCTAssertEqual(shutter.y + shutter.height / 2, 718)
        XCTAssertLessThan(shutter.y + shutter.height / 2, 874 - 112,
                          "The previous fixed centre crossed the tall photo's lower border")
        for aspect in [0.75, 1, 9.0 / 16] {
            let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: 402,
                containerHeight: 874, photoAspectRatio: aspect))
            assertCircle(shutter, clears: photo, by: 8)
        }
        let oldShutter = CameraPhotoViewport(x: 155, y: 716, width: 92, height: 92)
        let tall = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 9.0 / 16))
        XCTAssertLessThan(distanceFromCircleCenter(oldShutter, toBorderOf: tall), 46,
                          "This fixture must reproduce the actual old border intersection")
    }

    func testOneFixedShutterClearsEveryRatioAcrossPhonesAndTablets() throws {
        for (width, height) in [(375.0, 667.0), (390, 844), (402, 874), (430, 932),
                                (768, 1024), (1024, 1366)] {
            for sourceAspect in [0.75, 0.8] {
                let shutter = try XCTUnwrap(MeasurementCameraChromeLayout.shutterFrame(containerWidth: width,
                    containerHeight: height, sourceAspectRatio: sourceAspect), "\(width)×\(height)/\(sourceAspect)")
                XCTAssertGreaterThanOrEqual(shutter.x, 0)
                XCTAssertGreaterThanOrEqual(shutter.y, 0)
                XCTAssertLessThanOrEqual(shutter.x + shutter.width, width)
                XCTAssertLessThanOrEqual(shutter.y + shutter.height, height)
                XCTAssertEqual(shutter.width, 92)
                for aspect in [sourceAspect, 1, 9.0 / 16] {
                    let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: width,
                        containerHeight: height, photoAspectRatio: aspect))
                    assertCircle(shutter, clears: photo, by: 8)
                }
            }
        }
    }

    func testCompactShutterMovesInsideTheCommonPhotoWhenNoLowerGapCanFitIt() throws {
        let shutter = try XCTUnwrap(MeasurementCameraChromeLayout.shutterFrame(containerWidth: 375,
            containerHeight: 667))
        XCTAssertEqual(shutter.y + shutter.height / 2, 445.5, accuracy: 1e-10)
        for aspect in [0.75, 1, 9.0 / 16] {
            let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: 375,
                containerHeight: 667, photoAspectRatio: aspect))
            XCTAssertGreaterThanOrEqual(shutter.y, photo.y + 8)
            XCTAssertLessThanOrEqual(shutter.y + shutter.height, photo.y + photo.height - 8 + 1e-9)
        }
    }

    func testZoomStaysAboveTheRaisedShutterWhileKeepingItsTouchAreaAndPhotoCoordinates() throws {
        for (width, height) in [(375.0, 667.0), (390, 844), (402, 874), (430, 932), (1024, 1366)] {
            let shutter = try XCTUnwrap(MeasurementCameraChromeLayout.shutterFrame(containerWidth: width,
                containerHeight: height))
            for aspect in [0.75, 1, 9.0 / 16] {
                let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: width,
                    containerHeight: height, photoAspectRatio: aspect))
                let originalPhoto = photo
                let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: width,
                    containerHeight: height, photo: photo, shutter: shutter))
                XCTAssertLessThanOrEqual(chrome.zoomFrame.y + chrome.zoomFrame.height, shutter.y - 12 + 1e-9)
                XCTAssertEqual(chrome.zoomFrame.width, 48)
                XCTAssertGreaterThanOrEqual(chrome.zoomFrame.y, photo.y)
                XCTAssertEqual(photo, originalPhoto)
                if let guidance = chrome.guidanceFrame {
                    XCTAssertEqual(guidance.y + guidance.height + 12, chrome.zoomFrame.y, accuracy: 1e-10)
                }
            }
        }
    }

    func testLandscapeShutterUsesTheSidebarAndClearsAllPhotoEdges() throws {
        for (width, height) in [(874.0, 402.0), (667, 375), (1366, 1024)] {
            let shutter = try XCTUnwrap(MeasurementCameraChromeLayout.shutterFrame(containerWidth: width,
                containerHeight: height, sourceAspectRatio: 4.0 / 3))
            XCTAssertEqual(shutter.x + 46, width - 90)
            XCTAssertEqual(shutter.y + 46, height / 2)
            for aspect in [4.0 / 3, 1, 16.0 / 9] {
                let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: width,
                    containerHeight: height, photoAspectRatio: aspect))
                assertCircle(shutter, clears: photo, by: 8)
            }
        }
    }

    func testShutterRejectsInvalidDimensionsAndAWindowThatCannotFitIt() {
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertNil(MeasurementCameraChromeLayout.shutterFrame(containerWidth: invalid, containerHeight: 874))
            XCTAssertNil(MeasurementCameraChromeLayout.shutterFrame(containerWidth: 402, containerHeight: invalid))
            XCTAssertNil(MeasurementCameraChromeLayout.shutterFrame(containerWidth: 402,
                containerHeight: 874, sourceAspectRatio: invalid))
        }
        XCTAssertNil(MeasurementCameraChromeLayout.shutterFrame(containerWidth: 402, containerHeight: 874, diameter: 20))
        XCTAssertNil(MeasurementCameraChromeLayout.shutterFrame(containerWidth: 402, containerHeight: 874, edgeClearance: .nan))
        XCTAssertNil(MeasurementCameraChromeLayout.shutterFrame(containerWidth: 120, containerHeight: 200))
        XCTAssertNil(MeasurementCameraChromeLayout.layout(containerWidth: 402, containerHeight: 874,
            photo: .init(x: 0, y: 127, width: 402, height: 536),
            shutter: .init(x: 155, y: .nan, width: 92, height: 92)))
    }

    func testSquareMovesTheZoomUpWhileFourByThreeAndTallPhotoStayAboveTheFixedShutterRow() throws {
        let standard = try layout(width: 402, height: 874, aspect: 0.75)
        let square = try layout(width: 402, height: 874, aspect: 1)
        let tall = try layout(width: 402, height: 874, aspect: 9.0 / 16)
        XCTAssertEqual(standard.zoomCenterY, 623, accuracy: 1e-10)
        XCTAssertEqual(square.zoomCenterY, 539.25, accuracy: 1e-10)
        XCTAssertEqual(tall.zoomCenterY, 646)
        XCTAssertEqual(standard.zoomCenterX, 201)
        XCTAssertEqual(square.zoomCenterX, 201)
        XCTAssertLessThan(square.zoomCenterY, standard.zoomCenterY)
        for position in [standard, square, tall] {
            XCTAssertLessThanOrEqual(position.zoomFrame.y + position.zoomFrame.height, 874 - 192 - 12)
        }
    }

    func testPortraitPhotoBoundsFollowTheReferenceRatiosAndTallImageExtendsBehindShutter() throws {
        let references: [(Double, Double, Double)] = [(9.0 / 16, 60, 714.6666666666666),
                                                       (0.75, 127, 536), (1, 177.25, 402)]
        for (aspect, y, height) in references {
            let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: 402,
                containerHeight: 874, photoAspectRatio: aspect))
            XCTAssertEqual(photo.x, 0)
            XCTAssertEqual(photo.width, 402)
            XCTAssertEqual(photo.y, y, accuracy: 1e-10)
            XCTAssertEqual(photo.height, height, accuracy: 1e-10)
            XCTAssertEqual(photo.width / photo.height, aspect, accuracy: 1e-12)
        }
        let tall = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 9.0 / 16))
        XCTAssertGreaterThan(tall.y + tall.height, 874 - 192 + 80,
            "The actual camera photograph must remain behind the fixed shutter area")
    }

    func testPhotoBoundsRemainInsideCompactPhonesAndTabletsWithoutChangingSelectedAspect() throws {
        for (width, height) in [(375.0, 667.0), (402, 874), (430, 932), (768, 1024), (1024, 1366)] {
            for aspect in [0.75, 1, 9.0 / 16, 0.8] {
                let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: width,
                    containerHeight: height, photoAspectRatio: aspect))
                XCTAssertGreaterThanOrEqual(photo.x, 0)
                XCTAssertGreaterThanOrEqual(photo.y, 60)
                XCTAssertLessThanOrEqual(photo.x + photo.width, width)
                XCTAssertLessThanOrEqual(photo.y + photo.height, height - 60 + 1e-10)
                XCTAssertEqual(photo.width / photo.height, aspect, accuracy: 1e-12)
            }
        }
    }

    func testNativeOneAndTwoTimesKeepTheSameFullFieldPhotoBounds() throws {
        let one = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 1440.0 / 1920))
        let two = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 720.0 / 960))
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.width, 402)
        XCTAssertEqual(one.height, 536)
    }

    func testLandscapePhotoViewportPreservesTheExistingSideControlContract() {
        for aspect in [4.0 / 3, 1, 16.0 / 9] {
            XCTAssertEqual(MeasurementCameraChromeLayout.photoViewport(containerWidth: 874,
                containerHeight: 402, photoAspectRatio: aspect),
                CameraPhotoViewport.layout(containerWidth: 874, containerHeight: 402, photoAspectRatio: aspect))
        }
    }

    func testGuidanceFollowsTheZoomWithoutOverlappingItOrLeavingThePhoto() throws {
        for (width, height) in [(375.0, 667.0), (402, 874), (430, 932), (768, 1024), (1024, 1366)] {
            for aspect in [0.75, 1, 9.0 / 16] {
                let photo = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: width,
                    containerHeight: height, photoAspectRatio: aspect))
                let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: width,
                    containerHeight: height, photo: photo))
                XCTAssertGreaterThanOrEqual(chrome.zoomFrame.x, photo.x)
                XCTAssertGreaterThanOrEqual(chrome.zoomFrame.y, photo.y)
                XCTAssertLessThanOrEqual(chrome.zoomFrame.x + chrome.zoomFrame.width, photo.x + photo.width)
                XCTAssertEqual(chrome.zoomFrame.width, 48)
                if let guidance = chrome.guidanceFrame {
                    XCTAssertGreaterThanOrEqual(guidance.y, photo.y + 8)
                    XCTAssertEqual(guidance.y + guidance.height + 12, chrome.zoomFrame.y, accuracy: 1e-10)
                    XCTAssertGreaterThanOrEqual(guidance.x, photo.x)
                    XCTAssertLessThanOrEqual(guidance.x + guidance.width, photo.x + photo.width)
                }
            }
        }
    }

    func testLandscapeAnchorsToThePhotoAndNeverMovesTheZoomIntoTheShutterSidebar() throws {
        for aspect in [4.0 / 3, 1, 16.0 / 9] {
            let photo = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 874,
                containerHeight: 402, photoAspectRatio: aspect))
            let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: 874,
                containerHeight: 402, photo: photo))
            XCTAssertEqual(chrome.zoomCenterX, photo.x + photo.width / 2)
            XCTAssertEqual(chrome.zoomCenterY, photo.y + photo.height - 40)
            XCTAssertLessThanOrEqual(chrome.zoomFrame.x + chrome.zoomFrame.width, 874 - 180)
            if let guidance = chrome.guidanceFrame {
                XCTAssertLessThanOrEqual(guidance.x + guidance.width, 874 - 180)
            }
        }
    }

    func testPhotoExtendingBehindShutterCapsZoomBeforeControlsWithoutChangingPhoto() throws {
        let photo = CameraPhotoViewport(x: 0, y: 100, width: 402, height: 730)
        let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: 402,
            containerHeight: 874, photo: photo))
        XCTAssertLessThanOrEqual(chrome.zoomFrame.y + chrome.zoomFrame.height, 874 - 192 - 12)
        XCTAssertEqual(photo, .init(x: 0, y: 100, width: 402, height: 730))
    }

    func testCompactWindowPreservesTouchSizeAndHidesOnlyGuidanceWhenItCannotFit() throws {
        let compact = try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: 300,
            containerHeight: 500, photo: .init(x: 30, y: 150, width: 240, height: 70)))
        XCTAssertEqual(compact.zoomFrame.width, 48)
        XCTAssertEqual(compact.zoomFrame.height, 48)
        XCTAssertNil(compact.guidanceFrame)
        XCTAssertGreaterThanOrEqual(compact.zoomFrame.y, 150)
        XCTAssertLessThanOrEqual(compact.zoomFrame.y + compact.zoomFrame.height, 220)
        XCTAssertNil(MeasurementCameraChromeLayout.layout(containerWidth: 300,
            containerHeight: 500, photo: .init(x: 30, y: 150, width: 240, height: 47)))
    }

    func testLargerGuidanceBudgetStillKeepsNavigationAndZoomSeparate() throws {
        let photo = try XCTUnwrap(CameraPhotoViewport.layout(containerWidth: 402,
            containerHeight: 874, photoAspectRatio: 1))
        let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: 402,
            containerHeight: 874, photo: photo, guidanceHeight: 120))
        let guidance = try XCTUnwrap(chrome.guidanceFrame)
        XCTAssertEqual(guidance.height, 120)
        XCTAssertGreaterThanOrEqual(guidance.y, photo.y + 8)
        XCTAssertEqual(guidance.y + guidance.height + 12, chrome.zoomFrame.y)
    }

    func testNonfiniteInvalidAndOutOfBoundsInputsDoNotProduceChromeCoordinates() {
        let photo = CameraPhotoViewport(x: 0, y: 146, width: 402, height: 536)
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertNil(MeasurementCameraChromeLayout.layout(containerWidth: invalid,
                containerHeight: 874, photo: photo))
            XCTAssertNil(MeasurementCameraChromeLayout.layout(containerWidth: 402,
                containerHeight: invalid, photo: photo))
        }
        for invalidPhoto in [CameraPhotoViewport(x: -1, y: 146, width: 402, height: 536),
                             .init(x: 0, y: 146, width: 403, height: 536),
                             .init(x: 0, y: 146, width: 402, height: .infinity)] {
            XCTAssertNil(MeasurementCameraChromeLayout.layout(containerWidth: 402,
                containerHeight: 874, photo: invalidPhoto))
        }
        XCTAssertNil(MeasurementCameraChromeLayout.layout(containerWidth: 402,
            containerHeight: 874, photo: photo, zoomDiameter: 20))
        XCTAssertNil(MeasurementCameraChromeLayout.layout(containerWidth: 402,
            containerHeight: 874, photo: photo, guidanceHeight: .nan))
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertNil(MeasurementCameraChromeLayout.photoViewport(containerWidth: 402,
                containerHeight: 874, photoAspectRatio: invalid))
        }
        XCTAssertNil(MeasurementCameraChromeLayout.photoViewport(containerWidth: 90,
            containerHeight: 120, photoAspectRatio: 0.75))
    }

    private func layout(width: Double, height: Double, aspect: Double) throws -> MeasurementCameraChromeLayout {
        let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: width,
            containerHeight: height, photoAspectRatio: aspect))
        return try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: width,
            containerHeight: height, photo: photo))
    }

    private func assertCircle(_ circle: CameraPhotoViewport, clears photo: CameraPhotoViewport,
                              by clearance: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(distanceFromCircleCenter(circle, toBorderOf: photo),
            circle.width / 2 + clearance - 1e-9, "\(circle) intersects \(photo)", file: file, line: line)
    }

    /// Independent Euclidean point-to-segment distances, not the production
    /// interval/candidate algorithm. This also detects vertical letterbox edges.
    private func distanceFromCircleCenter(_ circle: CameraPhotoViewport,
                                          toBorderOf photo: CameraPhotoViewport) -> Double {
        let x = circle.x + circle.width / 2, y = circle.y + circle.height / 2
        let right = photo.x + photo.width, bottom = photo.y + photo.height
        let nearestX = min(max(x, photo.x), right), nearestY = min(max(y, photo.y), bottom)
        return [hypot(x - nearestX, y - photo.y), hypot(x - nearestX, y - bottom),
                hypot(x - photo.x, y - nearestY), hypot(x - right, y - nearestY)].min()!
    }
}

import XCTest
@testable import DobbyLiDARCore

final class MeasurementCameraChromeLayoutTests: XCTestCase {
    func testPortraitControlsFollowEachSelectedPhotoRatio() throws {
        var rowCenters: [Double] = []
        var zoomCenters: [Double] = []
        for aspect in [1.0, 0.75, 9.0 / 16] {
            let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: 402,
                containerHeight: 874, photoAspectRatio: aspect))
            let originalPhoto = photo
            let controls = try XCTUnwrap(MeasurementCameraChromeLayout.controls(containerWidth: 402,
                containerHeight: 874, photo: photo, bottomSafeAreaInset: 34))
            let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: 402,
                containerHeight: 874, photo: photo, shutter: controls.shutter))
            let rowCenter = controls.shutter.y + controls.shutter.height / 2
            rowCenters.append(rowCenter)
            zoomCenters.append(chrome.zoomCenterY)
            XCTAssertEqual(controls.more.y + controls.more.height / 2, rowCenter)
            XCTAssertEqual(controls.accessory.y + controls.accessory.height / 2, rowCenter)
            XCTAssertEqual(MeasurementCameraChromeLayout.shutterFrame(containerWidth: 402,
                containerHeight: 874, sourceAspectRatio: aspect, bottomSafeAreaInset: 34), controls.shutter)
            XCTAssertEqual(photo, originalPhoto, "Moving the controls must preserve the calibrated photograph")
        }
        XCTAssertEqual(Set(rowCenters).count, 3)
        XCTAssertEqual(Set(zoomCenters).count, 3)
        XCTAssertEqual(zoomCenters[0], 539.25, accuracy: 1e-10)
        XCTAssertEqual(zoomCenters[1], 623, accuracy: 1e-10)
        XCTAssertEqual(zoomCenters[2], 630.6666666666666, accuracy: 1e-10)
    }

    func testPortraitControlsStayWhollyBelowOrInsideThePhotoAcrossPhonesAndTablets() throws {
        for (width, height) in [(375.0, 667.0), (390, 844), (402, 874), (430, 932),
                                (768, 1024), (1024, 1366)] {
            for safeArea in [0.0, 21, 34] {
                for aspect in [1.0, 0.75, 9.0 / 16] {
                    let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: width,
                        containerHeight: height, photoAspectRatio: aspect))
                    let controls = try XCTUnwrap(MeasurementCameraChromeLayout.controls(containerWidth: width,
                        containerHeight: height, photo: photo, bottomSafeAreaInset: safeArea))
                    let shutter = controls.shutter
                    XCTAssertEqual(shutter.x + shutter.width / 2, width / 2)
                    XCTAssertEqual(shutter.width, 92)
                    XCTAssertEqual(controls.more.width, 48)
                    XCTAssertEqual(controls.accessory.width, 48)
                    let photoBottom = photo.y + photo.height
                    let usableBottom = height - safeArea
                    if usableBottom - photoBottom >= 92 + 16 * 2 {
                        XCTAssertGreaterThanOrEqual(shutter.y, photoBottom + 16 - 1e-9)
                        XCTAssertEqual(shutter.y + 46, (photoBottom + usableBottom) / 2, accuracy: 1e-10)
                    } else {
                        XCTAssertGreaterThanOrEqual(shutter.y, photo.y + 16 - 1e-9)
                        XCTAssertLessThanOrEqual(shutter.y + shutter.height, photoBottom - 16 + 1e-9)
                    }
                    for frame in [shutter, controls.more, controls.accessory] {
                        XCTAssertGreaterThanOrEqual(frame.x, 16)
                        XCTAssertGreaterThanOrEqual(frame.y, 16)
                        XCTAssertLessThanOrEqual(frame.x + frame.width, width - 16 + 1e-9)
                        XCTAssertLessThanOrEqual(frame.y + frame.height, usableBottom - 16 + 1e-9)
                    }
                    XCTAssertLessThanOrEqual(controls.accessory.x + controls.accessory.width, shutter.x - 16 + 1e-9)
                    XCTAssertGreaterThanOrEqual(controls.more.x, shutter.x + shutter.width + 16 - 1e-9)
                }
            }
        }
    }

    func testCompactTallPhotoKeepsTheShutterInsideInsteadOfCrossingThePhotoBorder() throws {
        let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: 375,
            containerHeight: 667, photoAspectRatio: 9.0 / 16))
        let controls = try XCTUnwrap(MeasurementCameraChromeLayout.controls(containerWidth: 375,
            containerHeight: 667, photo: photo, bottomSafeAreaInset: 34))
        XCTAssertEqual(controls.shutter.y + controls.shutter.height, photo.y + photo.height - 16, accuracy: 1e-10)
        XCTAssertEqual(controls.shutter.x + 46, 187.5)
    }

    func testZoomStaysAboveTheResponsiveShutterWithoutChangingItsTouchAreaOrPhotoCoordinates() throws {
        for (width, height) in [(375.0, 667.0), (390, 844), (402, 874), (430, 932), (1024, 1366)] {
            for aspect in [0.75, 1, 9.0 / 16] {
                let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: width,
                    containerHeight: height, photoAspectRatio: aspect))
                let originalPhoto = photo
                let controls = try XCTUnwrap(MeasurementCameraChromeLayout.controls(containerWidth: width,
                    containerHeight: height, photo: photo, bottomSafeAreaInset: 34))
                let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: width,
                    containerHeight: height, photo: photo, shutter: controls.shutter))
                XCTAssertLessThanOrEqual(chrome.zoomFrame.y + chrome.zoomFrame.height, controls.shutter.y - 12 + 1e-9)
                XCTAssertEqual(chrome.zoomFrame.width, 48)
                XCTAssertGreaterThanOrEqual(chrome.zoomFrame.y, photo.y)
                XCTAssertLessThanOrEqual(chrome.zoomFrame.y + chrome.zoomFrame.height, photo.y + photo.height)
                XCTAssertEqual(photo, originalPhoto)
                if let guidance = chrome.guidanceFrame {
                    XCTAssertEqual(guidance.y + guidance.height + 12, chrome.zoomFrame.y, accuracy: 1e-10)
                }
            }
        }
    }

    func testLandscapeControlsFollowThePhotoSidebarWithoutShorteningTheZoomArea() throws {
        for (width, height) in [(874.0, 402.0), (667, 375), (1366, 1024)] {
            var shutterCenters: [Double] = []
            for aspect in [4.0 / 3, 1, 16.0 / 9] {
                let photo = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(containerWidth: width,
                    containerHeight: height, photoAspectRatio: aspect))
                let controls = try XCTUnwrap(MeasurementCameraChromeLayout.controls(containerWidth: width,
                    containerHeight: height, photo: photo, bottomSafeAreaInset: 21))
                let shutter = controls.shutter
                let photoRight = photo.x + photo.width
                let centerX = shutter.x + 46
                shutterCenters.append(centerX)
                XCTAssertEqual(centerX, (photoRight + width) / 2, accuracy: 1e-10)
                XCTAssertEqual(shutter.y + 46, (height - 21) / 2)
                XCTAssertGreaterThanOrEqual(shutter.x, photoRight + 16 - 1e-9)
                XCTAssertLessThanOrEqual(controls.accessory.y + 48, shutter.y - 16 + 1e-9)
                XCTAssertGreaterThanOrEqual(controls.more.y, shutter.y + 92 + 16 - 1e-9)
                for frame in [shutter, controls.more, controls.accessory] {
                    XCTAssertGreaterThanOrEqual(frame.x, photoRight + 16 - 1e-9)
                    XCTAssertGreaterThanOrEqual(frame.y, 16)
                    XCTAssertLessThanOrEqual(frame.x + frame.width, width - 16 + 1e-9)
                    XCTAssertLessThanOrEqual(frame.y + frame.height, height - 21 - 16 + 1e-9)
                }
                let chrome = try XCTUnwrap(MeasurementCameraChromeLayout.layout(containerWidth: width,
                    containerHeight: height, photo: photo, shutter: shutter))
                XCTAssertEqual(chrome.zoomCenterY, photo.y + photo.height - 40, accuracy: 1e-10)
                XCTAssertLessThanOrEqual(chrome.zoomFrame.x + chrome.zoomFrame.width, photoRight)
            }
            XCTAssertGreaterThan(Set(shutterCenters).count, 1)
        }
    }

    func testControlsRejectInvalidDimensionsOrAWindowThatCannotFitAllTouchTargets() {
        let photo = CameraPhotoViewport(x: 0, y: 127, width: 402, height: 536)
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertNil(MeasurementCameraChromeLayout.controls(containerWidth: invalid, containerHeight: 874, photo: photo))
            XCTAssertNil(MeasurementCameraChromeLayout.controls(containerWidth: 402, containerHeight: invalid, photo: photo))
            XCTAssertNil(MeasurementCameraChromeLayout.shutterFrame(containerWidth: 402,
                containerHeight: 874, sourceAspectRatio: invalid))
        }
        for invalidPhoto in [CameraPhotoViewport(x: -1, y: 127, width: 402, height: 536),
                             .init(x: 0, y: 127, width: 403, height: 536),
                             .init(x: 0, y: 127, width: 402, height: .infinity),
                             .init(x: 0, y: 127, width: 402, height: 0)] {
            XCTAssertNil(MeasurementCameraChromeLayout.controls(containerWidth: 402,
                containerHeight: 874, photo: invalidPhoto))
        }
        for invalid in [Double.nan, .infinity, -1] {
            XCTAssertNil(MeasurementCameraChromeLayout.controls(containerWidth: 402,
                containerHeight: 874, photo: photo, bottomSafeAreaInset: invalid))
            XCTAssertNil(MeasurementCameraChromeLayout.controls(containerWidth: 402,
                containerHeight: 874, photo: photo, edgeClearance: invalid))
        }
        XCTAssertNil(MeasurementCameraChromeLayout.controls(containerWidth: 402,
            containerHeight: 874, photo: photo, bottomSafeAreaInset: 874))
        XCTAssertNil(MeasurementCameraChromeLayout.controls(containerWidth: 402,
            containerHeight: 874, photo: photo, diameter: 20))
        XCTAssertNil(MeasurementCameraChromeLayout.controls(containerWidth: 250,
            containerHeight: 500, photo: .init(x: 0, y: 100, width: 250, height: 250)))
        XCTAssertNil(MeasurementCameraChromeLayout.controls(containerWidth: 667,
            containerHeight: 240, photo: .init(x: 0, y: 0, width: 320, height: 240)))
        XCTAssertNil(MeasurementCameraChromeLayout.layout(containerWidth: 402, containerHeight: 874,
            photo: photo, shutter: .init(x: 155, y: .nan, width: 92, height: 92)))
    }

    func testPortraitPhotoBoundsFollowTheReferenceRatiosWithoutReservingChromeSpace() throws {
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
            "Control placement must not shrink the actual tall photograph")
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

    func testLegacyLayoutWithoutAnExplicitShutterRetainsItsFooterFallback() throws {
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

}

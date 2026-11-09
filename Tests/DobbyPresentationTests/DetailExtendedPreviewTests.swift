import AVFoundation
import SwiftUI
import XCTest
@testable import Dobby

@MainActor
final class DetailExtendedPreviewTests: XCTestCase {
    func testFigmaPhotographFillsWidthAndEndsAtScreenBottom() {
        let layout = DetailCameraPreviewLayout(containerSize: CGSize(width: 402, height: 874),
            aspectRatio: .sixteenNine, prefersBottomAlignedPortrait: true)
        XCTAssertTrue(layout.isBottomAligned)
        XCTAssertEqual(layout.photoFrame.minX, 0)
        XCTAssertEqual(layout.photoFrame.minY, 159.333333, accuracy: 0.001)
        XCTAssertEqual(layout.photoFrame.width, 402)
        XCTAssertEqual(layout.photoFrame.height, 714.666667, accuracy: 0.001)
        XCTAssertEqual(layout.photoFrame.maxY, 874, accuracy: 0.001)
        XCTAssertEqual(layout.previewFrame, layout.photoFrame)
        XCTAssertEqual(layout.photoRectInPreview, CGRect(origin: .zero, size: layout.photoFrame.size))
    }

    func testOtherRatiosAndCompactWindowsRetainExistingPlacement() {
        for size in [CGSize(width: 402, height: 874), CGSize(width: 375, height: 667),
                     CGSize(width: 874, height: 402), CGSize(width: 320, height: 320)] {
            for ratio in DetailPhotoAspectRatio.allCases {
                if size == CGSize(width: 402, height: 874), ratio == .sixteenNine { continue }
                let layout = DetailCameraPreviewLayout(containerSize: size, aspectRatio: ratio,
                    prefersBottomAlignedPortrait: true)
                let baseline = DetailAspectRatioPreviewLayout(containerSize: size, aspectRatio: ratio).frame
                XCTAssertFalse(layout.isBottomAligned)
                XCTAssertEqual(layout.photoFrame, baseline)
                XCTAssertEqual(layout.previewFrame, baseline)
                XCTAssertEqual(layout.photoRectInPreview.origin, .zero)
            }
        }
    }

    func testTallDevicesKeepButtonsAboveHomeIndicatorAndZoomAboveShutter() throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 402, height: 874),
                     CGSize(width: 440, height: 956)] {
            let layout = DetailCameraPreviewLayout(containerSize: size, aspectRatio: .sixteenNine,
                prefersBottomAlignedPortrait: true)
            let controls = try XCTUnwrap(layout.controls(in: size, bottomSafeAreaInset: 34))
            let photo = layout.photoFrame
            XCTAssertEqual(photo.width, size.width)
            XCTAssertEqual(photo.width / photo.height, 9.0 / 16, accuracy: 0.00001)
            XCTAssertEqual(photo.maxY, size.height, accuracy: 0.001)
            XCTAssertEqual(controls.shutter.y + controls.shutter.height, size.height - 66, accuracy: 0.001)
            let zoom = try XCTUnwrap(MeasurementCameraChromeLayout.layout(
                containerWidth: size.width, containerHeight: size.height,
                photo: .init(x: photo.minX, y: photo.minY, width: photo.width, height: photo.height),
                guidanceHeight: 0, shutter: controls.shutter))
            XCTAssertLessThanOrEqual(zoom.zoomFrame.y + zoom.zoomFrame.height, controls.shutter.y - 12)
            for frame in [controls.shutter, controls.more, controls.accessory] {
                XCTAssertGreaterThanOrEqual(frame.width, 44)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
                XCTAssertLessThanOrEqual(frame.y + frame.height, size.height - 34)
            }
        }
    }

    func testInvalidGeometryDoesNotCreateAnExtendedSurface() {
        for size in [CGSize.zero, CGSize(width: -1, height: 874),
                     CGSize(width: CGFloat.nan, height: 874), CGSize(width: 402, height: CGFloat.infinity)] {
            let layout = DetailCameraPreviewLayout(containerSize: size, aspectRatio: .sixteenNine,
                prefersBottomAlignedPortrait: true)
            XCTAssertEqual(layout.photoFrame, .zero)
            XCTAssertEqual(layout.previewFrame, .zero)
            XCTAssertFalse(layout.isBottomAligned)
        }
    }

    func testSurfaceCropExcludesHeaderAndRejectsInvalidRectangles() {
        let view = CameraPreviewSurface.PreviewView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.photoRect = CGRect(x: 0, y: 159.333333, width: 402, height: 714.666667)
        XCTAssertFalse(view.photoViewport.contains(CGPoint(x: 201, y: 100)))
        XCTAssertTrue(view.photoViewport.contains(CGPoint(x: 201, y: 800)))
        XCTAssertEqual(view.photoViewport.minY, 159.333333, accuracy: 0.001)
        view.photoRect = CGRect(x: 0, y: 900, width: 402, height: 10)
        XCTAssertTrue(view.photoViewport.isEmpty)
        view.photoRect = CGRect(x: CGFloat.nan, y: 0, width: 402, height: 874)
        XCTAssertTrue(view.photoViewport.isEmpty)
        view.photoRect = nil
        XCTAssertEqual(view.photoViewport, view.bounds)
        view.tearDownInteraction()
    }

    func testRenderedTopIsOpaqueForEveryRatioAndExtendedBottomShowsVideo() throws {
        for ratio in [DetailPhotoAspectRatio.fourThree, .sixteenNine, .square] {
            let renderer = ImageRenderer(content:
                DetailAspectRatioPreview(aspectRatio: ratio, prefersBottomAlignedPortrait: true) { _ in
                    Color.white
                }.frame(width: 402, height: 874))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage)
            let top = try pixel(image, x: 20, y: 80)
            let bottom = try pixel(image, x: 20, y: 840)
            let center = try pixel(image, x: 201, y: 440)
            XCTAssertEqual(top, 0, accuracy: 1, "All ratios use the same opaque header")
            if ratio == .sixteenNine {
                XCTAssertEqual(bottom, 255, accuracy: 1, "No lower black cover remains")
            } else {
                XCTAssertEqual(bottom, 0, accuracy: 1)
            }
            XCTAssertEqual(center, 255, accuracy: 1)
            let attachment = XCTAttachment(image: image)
            attachment.name = "detail-preview-mask-\(ratio.rawValue.replacingOccurrences(of: ":", with: "-"))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testPhotoReferenceSnapshotsForVisualReview() throws {
        guard case let .localFile(url, _) = try CameraPreviewPhotos.source(at: 0) else {
            return XCTFail("Expected the existing detail-camera photo fixture")
        }
        let photo = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        for ratio in [DetailPhotoAspectRatio.fourThree, .sixteenNine, .square] {
            let renderer = ImageRenderer(content:
                DetailAspectRatioPreview(aspectRatio: ratio, prefersBottomAlignedPortrait: true) { _ in
                    GeometryReader { geometry in
                        Image(uiImage: photo).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                }.frame(width: 402, height: 874))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "detail-preview-photo-\(ratio.rawValue.replacingOccurrences(of: ":", with: "-"))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return Double(bytes[(y * cg.width + x) * 4])
    }
}

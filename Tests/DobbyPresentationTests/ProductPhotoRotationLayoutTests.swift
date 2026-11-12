import SwiftUI
import Testing
import UIKit
@testable import Dobby

@MainActor
struct ProductPhotoRotationLayoutTests {
    @Test func everyIntermediateAngleKeepsTheWholePhotoInsideItsViewport() {
        // Includes the actual capture ratios and an already-cropped panorama.
        let images = [CGSize(width: 800, height: 1000), CGSize(width: 1200, height: 900),
                      CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080),
                      CGSize(width: 1000, height: 1000), CGSize(width: 2400, height: 600)]
        let viewports = [CGSize(width: 402, height: 536), CGSize(width: 536, height: 402)]
        for image in images {
            for viewport in viewports {
                for angle in stride(from: -450.0, through: 450.0, by: 15) {
                    let fitted = ProductPhotoRotationLayout.fittedImageSize(imageSize: image,
                        containerSize: viewport, angleDegrees: angle)
                    #expect(fitted.width > 0 && fitted.height > 0)
                    #expect(abs(fitted.width / fitted.height - image.width / image.height) < 0.000_001)
                    let radians = angle * .pi / 180
                    var occupiedX: CGFloat = 0
                    var occupiedY: CGFloat = 0
                    // Transform all four corners independently of the production
                    // bounding-box implementation: a midpoint crop must fail.
                    for xSign in [CGFloat(-1), 1] {
                        for ySign in [CGFloat(-1), 1] {
                            let x = xSign * fitted.width / 2
                            let y = ySign * fitted.height / 2
                            let px = x * cos(radians) - y * sin(radians)
                            let py = x * sin(radians) + y * cos(radians)
                            #expect(abs(px) <= viewport.width / 2 + 0.001)
                            #expect(abs(py) <= viewport.height / 2 + 0.001)
                            occupiedX = max(occupiedX, abs(px) * 2)
                            occupiedY = max(occupiedY, abs(py) * 2)
                        }
                    }
                    #expect(abs(occupiedX - viewport.width) < 0.001
                         || abs(occupiedY - viewport.height) < 0.001,
                            "Aspect fit should fill one dimension, not shrink the photograph unnecessarily")
                }
            }
        }
    }

    @Test func fourthTurnContinuesInTheChosenDirectionWithoutAFullReverseSpin() {
        var clockwise = 0.0
        var previous = 0
        for (index, next) in [1, 2, 3, 0, 1].enumerated() {
            clockwise = ProductPhotoRotationLayout.nextDisplayAngle(currentDegrees: clockwise,
                previousQuarterTurns: previous, nextQuarterTurns: next)
            #expect(clockwise == Double(index + 1) * 90)
            previous = next
        }

        var counterclockwise = 0.0
        previous = 0
        for (index, next) in [3, 2, 1, 0, 3].enumerated() {
            counterclockwise = ProductPhotoRotationLayout.nextDisplayAngle(currentDegrees: counterclockwise,
                previousQuarterTurns: previous, nextQuarterTurns: next)
            #expect(counterclockwise == Double(index + 1) * -90)
            previous = next
        }
    }

    @Test func quarterTurnBoundsSwapAxesAndInvalidSizesCannotProduceANaNTransform() {
        let image = CGSize(width: 128, height: 64)
        let bounds = ProductPhotoRotationLayout.rotatedBounds(imageSize: image, angleDegrees: 90)
        #expect(abs(bounds.width - 64) < 0.001 && abs(bounds.height - 128) < 0.001)
        for invalid in [CGSize.zero, CGSize(width: -1, height: 100),
                        CGSize(width: CGFloat.infinity, height: 100)] {
            #expect(ProductPhotoRotationLayout.fittedImageSize(imageSize: invalid,
                containerSize: CGSize(width: 200, height: 240), angleDegrees: 45) == .zero)
            #expect(ProductPhotoRotationLayout.fittedImageSize(imageSize: image,
                containerSize: invalid, angleDegrees: 45) == .zero)
        }
    }

    @Test func renderedGalleryImageHasTransparentMarginsAndCounterclockwisePixels() throws {
        let image = try fixtureImage()
        let size = CGSize(width: 200, height: 240)
        for angle in [0.0, -45, -90, -180, -270, -360] {
            let renderer = ImageRenderer(content: ProductPhotoRotatingImage(image: image, angleDegrees: angle)
                .frame(width: size.width, height: size.height))
            renderer.scale = 1
            renderer.isOpaque = false
            let raster = try #require(renderer.uiImage?.cgImage)
            let margin = try pixel(in: raster, x: 1, y: 1)
            let center = try pixel(in: raster, x: 100, y: 120)
            #expect(margin.alpha == 0,
                    "The photo's container must not paint opaque black letterbox margins")
            #expect(center.alpha > 240, "The renderer must contain the photograph, not just an empty clear frame")
            if angle == -90 {
                let top = try pixel(in: raster, x: 100, y: 60)
                let bottom = try pixel(in: raster, x: 100, y: 180)
                #expect(top.blue > 180 && top.red < 75)
                #expect(bottom.red > 180 && bottom.blue < 75)
            }
        }
    }

    private func fixtureImage() throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 64), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.blue.setFill(); context.fill(CGRect(x: 64, y: 0, width: 64, height: 64))
        }
        return try #require(image.cgImage)
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws
        -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let sample = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &rgba, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (rgba[0], rgba[1], rgba[2], rgba[3])
    }
}

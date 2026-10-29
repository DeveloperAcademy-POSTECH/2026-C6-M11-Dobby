import CoreGraphics
import CoreVideo
import Metal
import XCTest
@testable import Dobby

/// Bounded live-raster fixtures. These validate color-range/coordinate contracts
/// when executed on a Metal runner; they are not physical garment validation.
@MainActor
final class MultiCameraLiveRasterTests: XCTestCase {
    func testLiveYCbCrFullAndVideoRangePreserveNeutralBlackAndWhite() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable") }
        let rectifier = MultiCameraRectifier()
        let cases: [(OSType, UInt8, UInt8)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 0, 255),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 16, 235)
        ]
        for (type, black, white) in cases {
            for y in [black, white] {
                let result = try rectifier.image(pixelBuffer: yuvBuffer(type: type, luma: y),
                    calibration: lens(), maximumDimension: 8)
                XCTAssertEqual(result.width, 8)
                XCTAssertEqual(result.height, 6)
                let expected: UInt8 = y == black ? 0 : 255
                try assertPixel(result, x: 2, y: 1, expected: [expected, expected, expected, 255])
                try assertPixel(result, x: 6, y: 4, expected: [expected, expected, expected, 255])
            }
        }
    }

    func testLiveWarpLeavesOutOfLensPixelsTransparentAndUsesTheSameAspectGrid() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable") }
        let rectifier = MultiCameraRectifier()
        let input = try yuvBuffer(type: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, luma: 255)
        let result = try rectifier.image(pixelBuffer: input, calibration: lens(table: [0.5, 0.5]),
                                        maximumDimension: 9)
        // Exact 4:3 reduction: 9px is a bound, not independent axis rounding.
        XCTAssertEqual(result.width, 8)
        XCTAssertEqual(result.height, 6)
        try assertPixel(result, x: 0, y: 0, expected: [0, 0, 0, 0])
        try assertPixel(result, x: 3, y: 2, expected: [255, 255, 255, 255])
        // The full-size API remains the captured-image path and keeps its grid.
        let full = try rectifier.image(pixelBuffer: input, calibration: lens())
        XCTAssertEqual(full.width, 16)
        XCTAssertEqual(full.height, 12)
    }

    func testFusedMaskCopyMatchesExistingPermutationForEveryOrientationAndThreshold() throws {
        let size = PixelSize(width: 4, height: 3)
        let floats: [Float] = [0, 0.49, 0.5, 1, .nan, .infinity, -.infinity, -1, 0.7, 0.2, 0.9, 0.5]
        let bytes: [UInt8] = [0, 127, 128, 255, 1, 127, 0, 126, 129, 12, 250, 128]
        let binary: [UInt8] = [0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1]
        let upright = GarmentMask(size: size, values: binary)
        for format in [kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_OneComponent8] {
            var output: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, format,
                                             nil, &output), kCVReturnSuccess)
            let buffer = try XCTUnwrap(output)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
            do {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<size.height {
                    let row = base.advanced(by: y * stride)
                    for x in 0..<size.width {
                        if format == kCVPixelFormatType_OneComponent32Float {
                            row.assumingMemoryBound(to: Float.self)[x] = floats[y * size.width + x]
                        } else {
                            row.assumingMemoryBound(to: UInt8.self)[x] = bytes[y * size.width + x]
                        }
                    }
                }
            } catch {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw error
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for orientation in [ImageOrientation.up, .right, .down, .left] {
                let expected = try GarmentMaskOrientation.originalMask(fromUpright: upright, orientation: orientation)
                let actual = try LiveForegroundAnalyzer.copyMaskRestoringOrientation(buffer,
                    expectedSize: size, orientation: orientation)
                XCTAssertEqual(actual, expected)
            }
        }
    }

    private func lens(table: [Float] = [0, 0]) throws -> MultiCameraLensCalibration {
        try MultiCameraLensCalibration(
            intrinsics: CameraIntrinsics(fx: 16, fy: 16, cx: 8, cy: 6,
                                         referenceSize: PixelSize(width: 16, height: 12)),
            distortionCenter: SIMD2(8, 6), distortionLookupTable: table)
    }

    private func yuvBuffer(type: OSType, luma: UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 12, type,
                                         attributes as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
                .assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let bytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            for row in 0..<height {
                for column in 0..<bytes { base[row * stride + column] = plane == 0 ? luma : 128 }
            }
        }
        return buffer
    }

    private func assertPixel(_ image: CGImage, x: Int, y: Int, expected: [UInt8],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = y * image.bytesPerRow + x * 4
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(Int(data[offset + channel]) - Int(expected[channel])), 3,
                                     file: file, line: line)
        }
    }
}

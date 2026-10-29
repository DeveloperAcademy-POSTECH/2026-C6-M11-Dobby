import AVFoundation
import CoreGraphics
import CoreVideo
import Metal
import simd
import XCTest
@testable import Dobby

/// Generated pixels and explicit factory-style calibration verify registration
/// mathematics. They do not establish real-device lens or centimetre accuracy.
@MainActor
final class MultiCameraRectifierTests: XCTestCase {
    func testZeroDistortionPreservesDepthSamplesAndLeavesInvalidSamplesAsHoles() throws {
        let size = PixelSize(width: 8, height: 6)
        var values = (1...48).map(Float.init)
        values[0] = 0
        values[5] = .nan
        values[12] = .infinity
        values[20] = -1
        let source = DepthMap(size: size, values: values, confidence: nil)
        let rectified = try MultiCameraRectifier.rectifyDepth(source, calibration: calibration())
        XCTAssertEqual(rectified.size, size)
        XCTAssertNil(rectified.confidence, "Missing AVFoundation confidence must stay unknown")
        for i in values.indices {
            XCTAssertEqual(rectified.values[i], values[i].isFinite && values[i] > 0 ? values[i] : 0)
        }
    }

    func testForwardTableMapsRectifiedDestinationOutwardRatherThanUsingInverseDirection() throws {
        let lens = try calibration(table: [0.5, 0.5])
        let source = try XCTUnwrap(lens.sourcePoint(forRectifiedPixel: SIMD2(6, 3), in: .init(width: 8, height: 6)))
        XCTAssertEqual(source.x, 7, accuracy: 0.0001)
        XCTAssertEqual(source.y, 3, accuracy: 0.0001)
        let map = DepthMap(size: .init(width: 8, height: 6), values: (1...48).map(Float.init), confidence: nil)
        let result = try MultiCameraRectifier.rectifyDepth(map, calibration: lens)
        // Pixel centre (5.5, 2.5) maps to raw (6.25, 2.25), the source cell (6,2).
        XCTAssertEqual(result.values[2 * 8 + 5], map.values[2 * 8 + 6])
        XCTAssertEqual(result.values[0], 0, "Outside the real lens raster is a hole, never an edge-clamped measurement")
    }

    func testRemappingNeverFillsAHoleWithNeighbouringDepthOrFabricatesConfidence() throws {
        let lens = try calibration(table: [0.5, 0.5])
        var values = [Float](repeating: 1, count: 48)
        values[2 * 8 + 6] = 0
        var confidence = [UInt8](repeating: 1, count: 48)
        confidence[3 * 8 + 4] = 2
        let result = try MultiCameraRectifier.rectifyDepth(
            .init(size: .init(width: 8, height: 6), values: values, confidence: confidence), calibration: lens)
        XCTAssertEqual(result.values[2 * 8 + 5], 0)
        XCTAssertEqual(result.confidence?[2 * 8 + 5], 0)
        XCTAssertEqual(result.confidence?[0], 0)
        XCTAssertEqual(result.confidence?[3 * 8 + 4], 2)
    }

    func testCalibrationScalesKAndDistortionCentreTogetherWithoutChangingRadialTable() throws {
        let original = try MultiCameraLensCalibration(
            intrinsics: .init(fx: 120, fy: 118, cx: 8, cy: 6, referenceSize: .init(width: 16, height: 12)),
            distortionCenter: SIMD2(7, 5), distortionLookupTable: [0, 0.1])
        let scaled = try original.scaled(to: .init(width: 8, height: 6))
        XCTAssertEqual(scaled.intrinsics.fx, 60)
        XCTAssertEqual(scaled.intrinsics.fy, 59)
        XCTAssertEqual(scaled.intrinsics.cx, 4)
        XCTAssertEqual(scaled.intrinsics.cy, 3)
        XCTAssertEqual(scaled.distortionCenter, SIMD2(3.5, 2.5))
        XCTAssertEqual(scaled.distortionLookupTable, original.distortionLookupTable)
        let fromReference = try XCTUnwrap(original.sourcePoint(forRectifiedPixel: SIMD2(5, 4), in: .init(width: 8, height: 6)))
        let fromScaled = try XCTUnwrap(scaled.sourcePoint(forRectifiedPixel: SIMD2(5, 4), in: .init(width: 8, height: 6)))
        XCTAssertEqual(fromReference, fromScaled)
        XCTAssertThrowsError(try original.scaled(to: .init(width: 8, height: 8)))
    }

    func testMalformedCalibrationAndDepthAreRejected() throws {
        let validK = CameraIntrinsics(fx: 8, fy: 8, cx: 4, cy: 3, referenceSize: .init(width: 8, height: 6))
        for table in [[Float](), [0], [0, .nan], [-1, 0], [0, .infinity]] {
            XCTAssertThrowsError(try MultiCameraLensCalibration(intrinsics: validK,
                distortionCenter: SIMD2(4, 3), distortionLookupTable: table))
        }
        var invalidK = validK
        invalidK.fx = 0
        XCTAssertThrowsError(try MultiCameraLensCalibration(intrinsics: invalidK,
            distortionCenter: SIMD2(4, 3), distortionLookupTable: [0, 0]))
        XCTAssertThrowsError(try MultiCameraRectifier.rectifyDepth(
            .init(size: .init(width: 8, height: 6), values: [1], confidence: nil), calibration: calibration()))
        XCTAssertThrowsError(try MultiCameraRectifier.rectifyDepth(
            .init(size: .init(width: 8, height: 6), values: Array(repeating: 1, count: 48),
                  confidence: Array(repeating: 3, count: 48)), calibration: calibration()))
    }

    func testAbsoluteDepthAndSynchronizedClockAreRequired() throws {
        XCTAssertNoThrow(try MultiCameraFrame.validateDepthAccuracy(.absolute))
        XCTAssertThrowsError(try MultiCameraFrame.validateDepthAccuracy(.relative))
        let skew = try MultiCameraFrame.validatedSkew(wide: 10, depth: 10.002)
        XCTAssertEqual(skew, 0.002, accuracy: 0.000001)
        XCTAssertEqual(try MultiCameraFrame.validatedSkew(wide: 10.002, depth: 10), skew, accuracy: 0.000001)
        XCTAssertThrowsError(try MultiCameraFrame.validatedSkew(wide: 10, depth: 10.020))
        XCTAssertThrowsError(try MultiCameraFrame.validatedSkew(wide: .nan, depth: 10))
        XCTAssertThrowsError(try MultiCameraFrame.validatedSkew(wide: -1, depth: -1))
    }

    func testDeliveredIntrinsicsMustMatchTheDepthCameraCalibration() throws {
        let lens = try calibration()
        let valid = simd_float3x3(columns: (SIMD3(8, 0, 0), SIMD3(0, 8, 0), SIMD3(4, 3, 1)))
        XCTAssertTrue(lens.matchesDeliveredIntrinsics(valid))
        var differentCrop = valid
        differentCrop.columns.2.x += 2
        XCTAssertFalse(lens.matchesDeliveredIntrinsics(differentCrop))
        var differentLens = valid
        differentLens.columns.0.x *= 2
        XCTAssertFalse(lens.matchesDeliveredIntrinsics(differentLens))
    }

    func testPairedWideCanUseItsDepthCalibrationWhenVideoIntrinsicsAreAbsent() throws {
        let lens = try calibration()
        let result = try MultiCameraFrame.validatedWideIntrinsics(calibration: lens, deliveredData: nil)
        XCTAssertEqual(result.columns.0, lens.intrinsicMatrix.columns.0)
        XCTAssertEqual(result.columns.1, lens.intrinsicMatrix.columns.1)
        XCTAssertEqual(result.columns.2, lens.intrinsicMatrix.columns.2)
    }

    func testPresentWideVideoIntrinsicsAreCheckedButDoNotReplaceCanonicalDepthK() throws {
        let lens = try calibration()
        var delivered = lens.intrinsicMatrix
        delivered.columns.0.x += 0.02
        let data = withUnsafeBytes(of: delivered) { Data($0) }
        let result = try MultiCameraFrame.validatedWideIntrinsics(calibration: lens, deliveredData: data)
        XCTAssertEqual(result.columns.0, lens.intrinsicMatrix.columns.0)
        XCTAssertEqual(result.columns.1, lens.intrinsicMatrix.columns.1)
        XCTAssertEqual(result.columns.2, lens.intrinsicMatrix.columns.2)
        XCTAssertNotEqual(result.columns.0.x, delivered.columns.0.x)
    }

    func testContradictoryWideVideoIntrinsicsStillRejectThePacket() throws {
        let lens = try calibration()
        var cropped = lens.intrinsicMatrix
        cropped.columns.2.x += 2
        var differentLens = lens.intrinsicMatrix
        differentLens.columns.0.x *= 2
        for matrix in [cropped, differentLens] {
            let data = withUnsafeBytes(of: matrix) { Data($0) }
            XCTAssertThrowsError(try MultiCameraFrame.validatedWideIntrinsics(calibration: lens, deliveredData: data))
        }
    }

    func testMalformedPresentWideVideoIntrinsicsNeverMasqueradeAsMissingMetadata() throws {
        let lens = try calibration()
        for data in [Data(), Data(repeating: 0, count: 47), Data(repeating: 0, count: 49)] {
            XCTAssertThrowsError(try MultiCameraFrame.validatedWideIntrinsics(calibration: lens, deliveredData: data))
        }
        var invalid = lens.intrinsicMatrix
        invalid.columns.2.z = .nan
        let data = withUnsafeBytes(of: invalid) { Data($0) }
        XCTAssertThrowsError(try MultiCameraFrame.validatedWideIntrinsics(calibration: lens, deliveredData: data))
    }

    func testMetalIdentityWarpPreservesTopLeftRasterAndPreviewAspectRatio() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this test runner") }
        let source = try colorBuffer()
        let rectifier = MultiCameraRectifier()
        let full = try rectifier.image(pixelBuffer: source, calibration: calibration())
        XCTAssertEqual(full.width, 8)
        XCTAssertEqual(full.height, 6)
        try assertPixel(in: full, x: 0, y: 0, rgba: [255, 0, 0, 255])
        try assertPixel(in: full, x: 7, y: 0, rgba: [0, 255, 0, 255])
        try assertPixel(in: full, x: 0, y: 5, rgba: [0, 0, 255, 255])
        try assertPixel(in: full, x: 7, y: 5, rgba: [255, 255, 0, 255])
        let preview = try rectifier.image(pixelBuffer: source, calibration: calibration(), maximumDimension: 4)
        XCTAssertEqual(preview.width, 4)
        XCTAssertEqual(preview.height, 3)
        let oddBound = try rectifier.image(pixelBuffer: source, calibration: calibration(), maximumDimension: 5)
        XCTAssertEqual(oddBound.width, 4, "An odd bound must not round the two axes independently")
        XCTAssertEqual(oddBound.height, 3)
        XCTAssertThrowsError(try rectifier.image(pixelBuffer: source, calibration: calibration(), maximumDimension: 0))
    }

    func testMetalForwardWarpAndDepthSelectTheSameSourceRegion() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this test runner") }
        let lens = try calibration(table: [0.5, 0.5])
        let image = try MultiCameraRectifier().image(pixelBuffer: colorBuffer(), calibration: lens)
        // The top-left quadrant remains red at this destination, while an
        // outside destination is transparent instead of inventing edge pixels.
        try assertPixel(in: image, x: 2, y: 1, rgba: [255, 0, 0, 255])
        try assertPixel(in: image, x: 0, y: 0, rgba: [0, 0, 0, 0])
        let depth = try MultiCameraRectifier.rectifyDepth(
            .init(size: .init(width: 8, height: 6), values: Array(repeating: 1, count: 48), confidence: nil), calibration: lens)
        XCTAssertEqual(depth.values[0], 0)
        XCTAssertEqual(depth.values[1 * 8 + 2], 1)
    }

    private func calibration(table: [Float] = [0, 0]) throws -> MultiCameraLensCalibration {
        try MultiCameraLensCalibration(
            intrinsics: .init(fx: 8, fy: 8, cx: 4, cy: 3, referenceSize: .init(width: 8, height: 6)),
            distortionCenter: SIMD2(4, 3), distortionLookupTable: table)
    }

    private func colorBuffer() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<6 {
            for x in 0..<8 {
                let rgba: [UInt8]
                if y < 3 { rgba = x < 4 ? [255, 0, 0, 255] : [0, 255, 0, 255] }
                else { rgba = x < 4 ? [0, 0, 255, 255] : [255, 255, 0, 255] }
                let offset = y * stride + x * 4
                base[offset] = rgba[2]
                base[offset + 1] = rgba[1]
                base[offset + 2] = rgba[0]
                base[offset + 3] = rgba[3]
            }
        }
        return buffer
    }

    private func assertPixel(in image: CGImage, x: Int, y: Int, rgba: [UInt8],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = y * image.bytesPerRow + x * 4
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(Int(data[offset + channel]) - Int(rgba[channel])), 3, file: file, line: line)
        }
    }
}

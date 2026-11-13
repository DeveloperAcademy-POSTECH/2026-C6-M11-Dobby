import CoreVideo
import Metal
import XCTest
import simd
@testable import Dobby

/// Generated preview fixtures exercise production delivery/rendering only.
/// They provide no depth and never claim a valid measurement or device accuracy.
@MainActor
final class MultiCameraFrameDeliveryTests: XCTestCase {
    func testDepthlessPreviewCannotBecomeAMeasurementOrPinnedWinner() throws {
        let store = MultiCameraFrameStore()
        let session = UUID()
        let wide = try wideBuffer()
        let calibration = try lens()
        store.begin(sessionID: session)
        store.publishPreview(sessionID: session, timestamp: 1, wideImage: wide, calibration: calibration)

        let preview = try XCTUnwrap(store.latestPreview())
        XCTAssertEqual(preview.sessionID, session)
        XCTAssertEqual(preview.timestamp, 1)
        XCTAssertEqual(preview.wideCalibration, calibration)
        XCTAssertEqual(CVPixelBufferGetWidth(preview.wideImage), 32)
        XCTAssertNil(preview.measurement)
        XCTAssertNil(store.latest(), "Display-only RGB must not satisfy the measurement mailbox")
        XCTAssertNil(store.pinned(), "A preview must not manufacture a shutter winner")
    }

    func testRetiredSessionCannotPublishOrClearANewerPreview() throws {
        let store = MultiCameraFrameStore()
        let previous = UUID(), current = UUID()
        let wide = try wideBuffer()
        let calibration = try lens()
        store.begin(sessionID: previous)
        store.begin(sessionID: current)
        store.publishPreview(sessionID: previous, timestamp: 4, wideImage: wide, calibration: calibration)
        XCTAssertNil(store.latestPreview())

        store.publishPreview(sessionID: current, timestamp: 5, wideImage: wide, calibration: calibration)
        XCTAssertFalse(store.clear(sessionID: previous))
        XCTAssertEqual(store.latestPreview()?.timestamp, 5)
        XCTAssertEqual(store.latestPreview()?.sessionID, current)
        XCTAssertTrue(store.clear(sessionID: current))
        XCTAssertNil(store.latestPreview())
        store.publishPreview(sessionID: current, timestamp: 6, wideImage: wide, calibration: calibration)
        XCTAssertNil(store.latestPreview(), "A cleared session cannot revive its own old mailbox")
    }

    func testPreviewMailboxAdvancesOnlyForFiniteIncreasingTimestamps() throws {
        let store = MultiCameraFrameStore()
        let session = UUID()
        let wide = try wideBuffer()
        let calibration = try lens()
        store.begin(sessionID: session)
        for invalid: TimeInterval in [-1, .nan, .infinity] {
            store.publishPreview(sessionID: session, timestamp: invalid, wideImage: wide, calibration: calibration)
        }
        XCTAssertNil(store.latestPreview())

        store.publishPreview(sessionID: session, timestamp: 1, wideImage: wide, calibration: calibration)
        let firstRevision = try XCTUnwrap(store.latestPreview()).revision
        for rejected: TimeInterval in [1, 0.5, -1, .nan, .infinity] {
            store.publishPreview(sessionID: session, timestamp: rejected, wideImage: wide, calibration: calibration)
        }
        XCTAssertEqual(store.latestPreview()?.timestamp, 1)
        XCTAssertEqual(store.latestPreview()?.revision, firstRevision)
        store.publishPreview(sessionID: session, timestamp: 2, wideImage: wide, calibration: calibration)
        let advanced = try XCTUnwrap(store.latestPreview())
        XCTAssertEqual(advanced.timestamp, 2)
        XCTAssertGreaterThan(advanced.revision, firstRevision)
        XCTAssertNil(store.latest(), "Monotonic preview updates still provide no measurement depth")
    }

    func testGPUCentralWideRendersWithoutRetainingDepthTextures() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let calibration = try lens()
        let inputs = MultiCameraRenderInputs(sessionID: UUID(), timestamp: 1,
            wideImage: try wideBuffer(), wideCalibration: calibration)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 40, height: 40, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let geometry = try XCTUnwrap(MultiCameraPreviewGeometry.make(imageSize: .init(width: 32, height: 24),
            photoRect: CGRect(x: 4, y: 8, width: 32, height: 24), orientation: .up, zoom: .standard))
        let renderer = MultiCameraPreviewCompositor(device: device)
        let completed = await withCheckedContinuation { continuation in
            renderer.renderFixture(inputs: inputs, geometry: geometry, canvasSize: CGSize(width: 40, height: 40),
                texture: output) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(completed, "The production compositor must render valid central RGB without depth textures")
        for point in [SIMD2(8, 12), SIMD2(20, 20), SIMD2(32, 28)] {
            let actual = pixel(output, x: point.x, y: point.y)
            let expected = SIMD3<UInt8>(72, 132, 220)
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - Int(expected[channel])), 3)
            }
        }
        XCTAssertEqual(pixel(output, x: 20, y: 1), SIMD3<UInt8>(repeating: 0),
            "Black surroundings must not be filled with stretched or repeated photo pixels")
    }

    private func lens() throws -> MultiCameraLensCalibration {
        try .init(intrinsics: .init(fx: 24, fy: 24, cx: 16, cy: 12,
            referenceSize: .init(width: 32, height: 24)), distortionCenter: SIMD2(16, 12),
            distortionLookupTable: [0, 0])
    }

    private func wideBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_32BGRA,
            attributes, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(result, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(result))
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<24 { for x in 0..<32 {
            let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            pixel[0] = 220; pixel[1] = 132; pixel[2] = 72; pixel[3] = 255
        } }
        return result
    }

    private func pixel(_ texture: any MTLTexture, x: Int, y: Int) -> SIMD3<UInt8> {
        var bgra = SIMD4<UInt8>(repeating: 0)
        texture.getBytes(&bgra, bytesPerRow: 4,
            from: .init(origin: .init(x: x, y: y, z: 0), size: .init(width: 1, height: 1, depth: 1)),
            mipmapLevel: 0)
        return SIMD3(bgra.z, bgra.y, bgra.x)
    }
}

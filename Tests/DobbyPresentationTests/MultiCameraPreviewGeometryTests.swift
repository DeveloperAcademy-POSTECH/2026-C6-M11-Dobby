import CoreVideo
import Metal
import XCTest
import simd
@testable import Dobby

@MainActor
final class MultiCameraPreviewGeometryTests: XCTestCase {
    func testFullOneTimesKeepsTheCompleteWideFrameInEveryOrientation() throws {
        let size = PixelSize(width: 800, height: 600)
        for orientation in ImageOrientation.allCases {
            let quarterTurn = orientation == .left || orientation == .right
            let rect = CGRect(x: 19, y: 37, width: quarterTurn ? 300 : 400, height: quarterTurn ? 400 : 300)
            let mapping = try XCTUnwrap(MultiCameraPreviewGeometry.make(imageSize: size,
                photoRect: rect, orientation: orientation, zoom: .standard))
            for source in [ImagePoint(x: 0.1, y: 0.2), .init(x: 0.9, y: 0.8), .init(x: 0.5, y: 0.5)] {
                let expected = ImageCoordinateTransform.originalToDisplay(source, orientation: orientation)
                let canvas = CGPoint(x: source.x, y: source.y).applying(mapping.sensorToCanvas)
                XCTAssertEqual(canvas.x, rect.minX + expected.x * rect.width, accuracy: 0.00001)
                XCTAssertEqual(canvas.y, rect.minY + expected.y * rect.height, accuracy: 0.00001)
                let restored = try XCTUnwrap(mapping.sensorPoint(at: canvas))
                XCTAssertEqual(restored.x, source.x, accuracy: 0.00001)
                XCTAssertEqual(restored.y, source.y, accuracy: 0.00001)
                let normalized = try XCTUnwrap(CameraPreviewGeometry.displayPoint(sensorPoint: source,
                    viewportWidth: rect.width, viewportHeight: rect.height,
                    displayTransform: mapping.photoTransform))
                XCTAssertEqual(normalized.x, canvas.x - rect.minX, accuracy: 0.00001)
                XCTAssertEqual(normalized.y, canvas.y - rect.minY, accuracy: 0.00001)
            }
        }
    }

    func testTwoTimesUsesTheCenteredQuarterWithoutDoubleZoomingTheFocusCoordinates() throws {
        let rect = CGRect(x: 0, y: 146, width: 402, height: 536)
        let mapping = try XCTUnwrap(MultiCameraPreviewGeometry.make(imageSize: .init(width: 1920, height: 1440),
            photoRect: rect, orientation: .right, zoom: .double))
        let center = try XCTUnwrap(mapping.sensorPoint(at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(center.x, 0.5, accuracy: 0.00001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.00001)
        let topLeft = CGPoint(x: rect.minX + 0.01, y: rect.minY + 0.01).applying(mapping.canvasToSensor)
        XCTAssertEqual(topLeft.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(topLeft.y, 0.75, accuracy: 0.0001)
        XCTAssertNil(mapping.sensorPoint(at: CGPoint(x: rect.midX, y: rect.minY - 1)),
                     "Black surroundings never become measurement focus targets")
        XCTAssertTrue(mapping.rawWideCovers(CGPoint(x: rect.midX, y: rect.minY - 40)),
                      "2x crop geometry retains the original sensor field without admitting outside focus taps")
    }

    func testNarrowerPhotoRatioRetainsRealWidePixelsOutsideItsWindow() throws {
        let mapping = try XCTUnwrap(MultiCameraPreviewGeometry.make(imageSize: .init(width: 800, height: 600),
            photoRect: CGRect(x: 20, y: 40, width: 80, height: 40), orientation: .up, zoom: .standard))
        XCTAssertTrue(mapping.rawWideCovers(CGPoint(x: 60, y: 35)))
        XCTAssertFalse(mapping.rawWideCovers(CGPoint(x: 60, y: 10)))
        XCTAssertNil(mapping.sensorPoint(at: CGPoint(x: 60, y: 35)))
        let sourceCenter = CGPoint(x: 0.5, y: 0.5).applying(mapping.sensorToCanvas)
        XCTAssertEqual(sourceCenter.x, 60, accuracy: 0.00001)
        XCTAssertEqual(sourceCenter.y, 60, accuracy: 0.00001)
    }

    func testRejectsDegenerateOrNonfiniteGeometry() {
        XCTAssertNil(MultiCameraPreviewGeometry.make(imageSize: .init(width: 0, height: 600),
            photoRect: CGRect(x: 0, y: 0, width: 80, height: 60), orientation: .up, zoom: .standard))
        XCTAssertNil(MultiCameraPreviewGeometry.make(imageSize: .init(width: 800, height: 600),
            photoRect: .zero, orientation: .up, zoom: .standard))
        XCTAssertNil(MultiCameraPreviewGeometry.make(imageSize: .init(width: 800, height: 600),
            photoRect: CGRect(x: Double.nan, y: 0, width: 80, height: 60), orientation: .up, zoom: .standard))
    }

    func testIntermediateRatioWindowsKeepGPUAndFocusCoordinatesRegistered() throws {
        let start = CGRect(x: 0,y: 146,width: 402,height: 536)
        let end = CGRect(x: 0,y: 213,width: 402,height: 402)
        let sensor = ImagePoint(x: 0.55,y: 0.65)
        for progress in [0.0,0.25,0.5,0.75,1.0] {
            let rect = CGRect(x: start.minX+(end.minX-start.minX)*progress,
                y: start.minY+(end.minY-start.minY)*progress,
                width: start.width+(end.width-start.width)*progress,
                height: start.height+(end.height-start.height)*progress)
            let mapping = try XCTUnwrap(MultiCameraPreviewGeometry.make(imageSize: .init(width: 1920,height: 1440),
                photoRect: rect,orientation: .right,zoom: .standard))
            let focus = try XCTUnwrap(CameraPreviewGeometry.displayPoint(sensorPoint: sensor,
                viewportWidth: rect.width,viewportHeight: rect.height,displayTransform: mapping.photoTransform))
            let canvas = CGPoint(x: focus.x+rect.minX,y: focus.y+rect.minY)
            let shaderSensor = canvas.applying(mapping.canvasToSensor)
            XCTAssertEqual(shaderSensor.x,sensor.x,accuracy: 0.00001)
            XCTAssertEqual(shaderSensor.y,sensor.y,accuracy: 0.00001)
        }
    }

    func testRuntimeMetalSourceCompilesIntoTheActualPreviewPipeline() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let library = try device.makeLibrary(source: MultiCameraPreviewCompositor.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "cameraPreviewVertex"))
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "cameraPreviewFragment"))
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor: descriptor))
    }

    func testGPUKeepsExactCentralWideAndFillsSurroundingsBlack() async throws {
        let output = try await render(photoRect: CGRect(x: 20, y: 30, width: 80, height: 60))
        assertPixel(output, at: .init(x: 60, y: 60), equals: SIMD3(255, 0, 0))
        assertPixel(output, at: .init(x: 21, y: 31), equals: SIMD3(255, 0, 0))
        for point in [CGPoint(x: 60, y: 8), .init(x: 8, y: 60), .init(x: 112, y: 60)] {
            assertPixel(output, at: point, equals: SIMD3(repeating: 0))
        }
    }

    func testCroppedRatioHidesEvenUnusedWidePixelsOutsidePhoto() async throws {
        let output = try await render(photoRect: CGRect(x: 20, y: 40, width: 80, height: 40))
        assertPixel(output, at: .init(x: 60, y: 60), equals: SIMD3(255, 0, 0))
        // These points map to spare sensor pixels. Every area
        // outside the selected photograph is now intentionally opaque black.
        for point in [CGPoint(x: 60, y: 35), .init(x: 60, y: 8), .init(x: 60, y: 90)] {
            assertPixel(output, at: point, equals: SIMD3(repeating: 0))
        }
    }

    private func render(photoRect: CGRect) async throws -> any MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let imageSize = PixelSize(width: 80, height: 60)
        let wide = try buffer(width: 80, height: 60, format: kCVPixelFormatType_32BGRA)
        fill(wide, color: SIMD3(255, 0, 0))
        let lens = try MultiCameraLensCalibration(intrinsics: .init(fx: 60, fy: 60, cx: 40, cy: 30,
            referenceSize: imageSize), distortionCenter: SIMD2(40, 30), distortionLookupTable: [0, 0])
        let inputs = MultiCameraRenderInputs(sessionID: UUID(), timestamp: 1, wideImage: wide,
            wideCalibration: lens)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 120, height: 120, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget,.shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let geometry = try XCTUnwrap(MultiCameraPreviewGeometry.make(imageSize: imageSize,
            photoRect: photoRect, orientation: .up, zoom: .standard))
        let renderer = MultiCameraPreviewCompositor(device: device)
        let success = await withCheckedContinuation { continuation in
            renderer.renderFixture(inputs: inputs, geometry: geometry, canvasSize: CGSize(width: 120,height: 120),
                texture: output) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(success, "The real camera compositor shader must finish its generated GPU fixture")
        return output
    }

    private func buffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,width,height,format,attributes,&buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func fill(_ buffer: CVPixelBuffer, color: SIMD3<UInt8>) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        for y in 0..<CVPixelBufferGetHeight(buffer) { for x in 0..<CVPixelBufferGetWidth(buffer) {
            let p = base.advanced(by: y*CVPixelBufferGetBytesPerRow(buffer)+x*4).assumingMemoryBound(to: UInt8.self)
            p[0] = color.z; p[1] = color.y; p[2] = color.x; p[3] = 255
        } }
    }

    private func pixel(_ texture: any MTLTexture, at point: CGPoint) -> SIMD3<UInt8> {
        var bgra = SIMD4<UInt8>(repeating: 0)
        texture.getBytes(&bgra,bytesPerRow: 4,from: .init(origin: .init(x: Int(point.x),y: Int(point.y),z: 0),
            size: .init(width: 1,height: 1,depth: 1)),mipmapLevel: 0)
        return SIMD3(bgra.z,bgra.y,bgra.x)
    }

    private func assertPixel(_ texture: any MTLTexture, at point: CGPoint, equals expected: SIMD3<UInt8>,
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = pixel(texture,at: point)
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(actual[channel])-Int(expected[channel])), 3,file: file,line: line)
        }
    }
}

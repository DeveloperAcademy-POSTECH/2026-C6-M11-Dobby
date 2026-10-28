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
                     "Visible peripheral pixels never become measurement focus targets")
        XCTAssertTrue(mapping.rawWideCovers(CGPoint(x: rect.midX, y: rect.minY - 40)),
                      "2x has real wide pixels outside the photographed crop; use those before ultra")
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

    func testGPUUsesUltraOnlyOutsideWideWhilePreservingTheExactCentralPixels() async throws {
        let output = try await render(photoRect: CGRect(x: 20, y: 30, width: 80, height: 60))
        assertPixel(output, at: .init(x: 60, y: 60), equals: SIMD3(255,0,0))
        assertPixel(output, at: .init(x: 21, y: 31), equals: SIMD3(255,0,0))
        assertPixel(output, at: .init(x: 60, y: 8), equals: SIMD3(0,0,255))
        // Chrome translucency belongs to native regular Liquid Glass. Camera
        // pixels under it must reach that layer at their original brightness.
    }

    func testGPURatioSurroundUsesExistingWidePixelsBeforeSwitchingToUltra() async throws {
        let output = try await render(photoRect: CGRect(x: 20, y: 40, width: 80, height: 40))
        assertPixel(output, at: .init(x: 60, y: 60), equals: SIMD3(255,0,0))
        assertPixel(output, at: .init(x: 60, y: 35), equals: SIMD3(255,0,0))
        assertPixel(output, at: .init(x: 60, y: 8), equals: SIMD3(0,0,255))
    }

    func testGPUWithoutLocalDepthUsesOnlyTheCalibratedUltraDirectionAndPreservesWide() async throws {
        let rect = CGRect(x: 20, y: 30, width: 80, height: 60)
        let output = try await render(photoRect: rect, depthValue: 0, translationX: 0.2)
        assertPixel(output, at: .init(x: 60, y: 60), equals: SIMD3(255,0,0))
        assertPixel(output, at: .init(x: 60, y: 8), equals: SIMD3(0,0,255))
        // Unknown distance has no valid translation correction. Two different
        // baselines must render the same direction, never a fabricated metre Z.
        let zeroBaseline = try await render(photoRect: rect,depthValue: 0,ultraGradient: true)
        let changedBaseline = try await render(photoRect: rect,depthValue: 0,translationX: 0.2,ultraGradient: true)
        assertPixel(changedBaseline,at: .init(x: 60,y: 8),
                    equals: pixel(zeroBaseline,at: .init(x: 60,y: 8)))
    }

    func testGPUCalibratedWorldPatternContinuesAcrossTheWideUltraBoundaryWithoutAScaleJump() async throws {
        let rect = CGRect(x: 20,y: 30,width: 80,height: 60)
        let output = try await render(photoRect: rect,translationX: 0.12,matchingWorldPattern: true)
        // Both synthetic lenses photograph the SAME plane at Z=1, from camera
        // centres separated by 12cm. Their pixel patterns are generated in
        // world coordinates, not by resizing/copying one image into the other.
        for point in [CGPoint(x: 60,y: 31),.init(x: 60,y: 29),.init(x: 60,y: 24),
                      .init(x: 15,y: 60),.init(x: 104,y: 60),.init(x: 60,y: 60)] {
            let x = (Float(point.x)+0.5-20-40)/60
            let y = (Float(point.y)+0.5-30-30)/60
            let color = worldPattern(x,y)
            assertPixel(output,at: point,equals: SIMD3(UInt8((color.x*255).rounded()),
                UInt8((color.y*255).rounded()),UInt8((color.z*255).rounded())))
        }
    }

    func testGPUFourByThreeWideAndSixteenByNineUltraUseTheirOwnCalibratedRasters() async throws {
        let rect = CGRect(x: 20, y: 30, width: 80, height: 60)
        let output = try await render(photoRect: rect, translationX: 0.12,
            matchingWorldPattern: true, ultraSize: .init(width: 160, height: 90),
            ultraFocalLength: 45, markWideCenter: true)
        // This is a separate 16:9 sensor raster with square pixels and its own
        // focal length/principal point, not a stretched 80x60 camera image.
        // Both cameras see the same Z=1 world plane from different centres.
        for point in [CGPoint(x: 60, y: 8), .init(x: 60, y: 112),
                      .init(x: 8, y: 60), .init(x: 112, y: 60),
                      .init(x: 60, y: 29), .init(x: 60, y: 31),
                      .init(x: 15, y: 60), .init(x: 104, y: 60)] {
            let rayX = (Float(point.x) + 0.5 - 20 - 40) / 60
            let rayY = (Float(point.y) + 0.5 - 30 - 30) / 60
            let expected = worldPattern(rayX, rayY)
            assertPixel(output, at: point, equals: SIMD3(UInt8((expected.x * 255).rounded()),
                UInt8((expected.y * 255).rounded()), UInt8((expected.z * 255).rounded())))
        }
        // Only the wide camera contains this marker. If peripheral format
        // support accidentally replaces/mixes the central photo, it disappears.
        assertPixel(output, at: .init(x: 60, y: 60), equals: SIMD3(255, 0, 0))
        assertPixel(output, at: .init(x: 58, y: 58), equals: SIMD3(255, 0, 0))
    }

    func testGPUTiltedFloorUsesItsPlaneInsteadOfAConstantBorderDistance() async throws {
        let output = try await render(photoRect: CGRect(x: 20,y: 30,width: 80,height: 60),
            depthSlopeY: 0.8, translationX: 0.2, ultraGradient: true)
        // Pixel centres map to rectified wide(40.5,-21.5). For the generated
        // plane, inverseZ=1+0.8*(y-30)/60. Project into ultra after a 0.2m
        // baseline. The deliberately enlarged baseline distinguishes the true
        // plane from a constant-Z shortcut by more than the raster tolerance.
        let rayX: Float = (40.5-40)/60, rayY: Float = (-21.5-30)/60
        let inverseZ: Float = 1+0.8*rayY
        let ultraX: Float = 30*(rayX+0.2*inverseZ)+40
        let expected = Int((ultraX/80*255).rounded())
        let actual = Int(pixel(output,at: .init(x: 60,y: 8)).x)
        XCTAssertLessThanOrEqual(abs(actual-expected),3)
        let constantZValue = Int(((30*(rayX+0.2)+40)/80*255).rounded())
        XCTAssertGreaterThan(abs(actual-constantZValue),4)
    }

    private func render(photoRect: CGRect, depthValue: Float = 1, depthSlopeY: Float = 0,
                        translationX: Float = 0, ultraGradient: Bool = false,
                        matchingWorldPattern: Bool = false,
                        ultraSize: PixelSize = .init(width: 80, height: 60),
                        ultraFocalLength: Float = 30,
                        markWideCenter: Bool = false) async throws -> any MTLTexture {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let imageSize = PixelSize(width: 80, height: 60)
        let wide = try buffer(width: 80, height: 60, format: kCVPixelFormatType_32BGRA)
        let ultra = try buffer(width: ultraSize.width, height: ultraSize.height, format: kCVPixelFormatType_32BGRA)
        let depth = try buffer(width: 20, height: 15, format: kCVPixelFormatType_DepthFloat32)
        fill(wide, color: SIMD3(255,0,0)); fill(ultra, color: SIMD3(0,0,255))
        if ultraGradient {
            CVPixelBufferLockBaseAddress(ultra, [])
            if let base = CVPixelBufferGetBaseAddress(ultra) {
                for y in 0..<ultraSize.height { for x in 0..<ultraSize.width {
                    let p = base.advanced(by: y*CVPixelBufferGetBytesPerRow(ultra)+x*4).assumingMemoryBound(to: UInt8.self)
                    p[0] = 0; p[1] = 0
                    p[2] = UInt8(((Float(x)+0.5)/Float(ultraSize.width)*255).rounded()); p[3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(ultra, [])
        }
        if matchingWorldPattern {
            for (buffer,focal,offset) in [(wide,Float(60),Float(0)),(ultra,ultraFocalLength,translationX)] {
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                    for y in 0..<height { for x in 0..<width {
                        let color = worldPattern((Float(x)+0.5-Float(width)/2)/focal-offset,
                            (Float(y)+0.5-Float(height)/2)/focal)
                        let p = base.advanced(by: y*CVPixelBufferGetBytesPerRow(buffer)+x*4).assumingMemoryBound(to: UInt8.self)
                        p[0] = UInt8((color.z*255).rounded()); p[1] = UInt8((color.y*255).rounded())
                        p[2] = UInt8((color.x*255).rounded()); p[3] = 255
                    } }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
            }
        }
        if markWideCenter {
            CVPixelBufferLockBaseAddress(wide, [])
            if let base = CVPixelBufferGetBaseAddress(wide) {
                for y in 26..<34 { for x in 36..<44 {
                    let p = base.advanced(by: y*CVPixelBufferGetBytesPerRow(wide)+x*4).assumingMemoryBound(to: UInt8.self)
                    p[0] = 0; p[1] = 0; p[2] = 255; p[3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(wide, [])
        }
        CVPixelBufferLockBaseAddress(depth, [])
        if let base = CVPixelBufferGetBaseAddress(depth) {
            for row in 0..<15 {
                let values = base.advanced(by: row*CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)
                let rayY = ((Float(row)+0.5)*4-30)/60
                for x in 0..<20 { values[x] = depthValue == 0 ? 0 : depthValue/(1+depthSlopeY*rayY) }
            }
        }
        CVPixelBufferUnlockBaseAddress(depth, [])
        let wideK = simd_float3x3(columns: (SIMD3(60,0,0),SIMD3(0,60,0),SIMD3(40,30,1)))
        let ultraK = simd_float3x3(columns: (SIMD3(ultraFocalLength,0,0),SIMD3(0,ultraFocalLength,0),
            SIMD3(Float(ultraSize.width)/2,Float(ultraSize.height)/2,1)))
        let lens = try MultiCameraLensCalibration(intrinsics: .init(fx: 60, fy: 60, cx: 40, cy: 30,
            referenceSize: imageSize), distortionCenter: SIMD2(40,30), distortionLookupTable: [0,0])
        let inputs = MultiCameraRenderInputs(sessionID: UUID(), timestamp: 1, wideImage: wide,
            ultraWideImage: ultra, depth: depth, wideIntrinsics: wideK, ultraWideIntrinsics: ultraK,
            wideToUltra: .init(columns: (SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1),SIMD3(translationX,0,0))),
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

    private func worldPattern(_ x: Float, _ y: Float) -> SIMD3<Float> {
        SIMD3(0.48+0.28*sin(4*x+0.5),0.48+0.25*sin(4*y+0.1),0.4+0.2*sin(2*x-3*y))
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

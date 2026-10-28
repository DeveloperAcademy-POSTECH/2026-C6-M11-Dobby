import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import Synchronization

/// Owned snapshot data. Ultra-wide pixels never replace measurement RGB or K.
nonisolated struct MultiCameraRectifiedFrame: @unchecked Sendable {
    let sessionID: UUID
    let timestamp: TimeInterval
    let image: CGImage
    let depth: DepthMap
    let intrinsics: CameraIntrinsics
}

/// A single inverse radial map is shared by RGB and axial depth. Snapshot-only
/// RGB rectification uses Metal; depth keeps nearest samples and invalid holes.
/// Call from a worker queue. Initializing this value does no GPU compilation.
nonisolated final class MultiCameraRectifier: @unchecked Sendable {
    private let cachedResources = Mutex<Resources?>(nil)

    func rectify(frame: MultiCameraFrame) throws -> MultiCameraRectifiedFrame {
        let rectifiedDepth = try depth(frame: frame)
        let rectifiedImage = try image(frame: frame)
        return MultiCameraRectifiedFrame(sessionID: frame.sessionID, timestamp: frame.timestamp,
            image: rectifiedImage, depth: rectifiedDepth, intrinsics: frame.wideCalibration.intrinsics)
    }

    func depth(frame: MultiCameraFrame) throws -> DepthMap {
        try MultiCameraFrame.validateDepthAccuracy(frame.depthData.depthDataAccuracy)
        let source = try Self.copyDepth(frame.depthData)
        return try Self.rectifyDepth(source, calibration: frame.wideCalibration)
    }

    func image(frame: MultiCameraFrame, maximumDimension: Int? = nil) throws -> CGImage {
        try image(pixelBuffer: frame.wideImage, calibration: frame.wideCalibration, maximumDimension: maximumDimension)
    }

    func preview(frame: MultiCameraFrame, maximumDimension: Int) -> CGImage? {
        try? image(frame: frame, maximumDimension: maximumDimension)
    }

    static func rectifyDepth(_ source: DepthMap, calibration: MultiCameraLensCalibration) throws -> DepthMap {
        let size = source.size
        guard size.isValid, size.width <= 2_048, size.height <= 2_048,
              source.values.count == size.width * size.height,
              let scaled = try? calibration.scaled(to: size) else { throw MultiCameraFrameError.invalidDepth }
        let sourceConfidence = source.confidence.flatMap {
            $0.count == source.values.count && $0.allSatisfy({ $0 <= 2 }) ? $0 : nil
        }
        if source.confidence != nil && sourceConfidence == nil { throw MultiCameraFrameError.invalidDepth }
        var values = [Float](repeating: 0, count: source.values.count)
        var confidence = sourceConfidence.map { _ in [UInt8](repeating: 0, count: source.values.count) }
        for y in 0..<size.height {
            for x in 0..<size.width {
                // Pixel centres follow the engine's (x + 0.5) / width convention.
                guard let p = scaled.sourcePoint(forRectifiedPixel: SIMD2(Float(x) + 0.5, Float(y) + 0.5), in: size),
                      p.x >= 0, p.y >= 0, p.x < Float(size.width), p.y < Float(size.height) else { continue }
                let sourceIndex = Int(p.y) * size.width + Int(p.x)
                let value = source.values[sourceIndex]
                guard value.isFinite, value > 0 else { continue }
                let destinationIndex = y * size.width + x
                // No interpolation across cloth/floor discontinuities and no
                // filling invalid samples from neighbouring valid depth.
                values[destinationIndex] = value
                if let sourceConfidence { confidence?[destinationIndex] = sourceConfidence[sourceIndex] }
            }
        }
        return DepthMap(size: size, values: values, confidence: confidence)
    }

    func image(pixelBuffer: CVPixelBuffer, calibration: MultiCameraLensCalibration,
               maximumDimension: Int? = nil) throws -> CGImage {
        let sourceSize = PixelSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let calibration = try calibration.scaled(to: sourceSize)
        if let maximumDimension, !(1...16_384).contains(maximumDimension) { throw MultiCameraFrameError.invalidImage }
        guard sourceSize.width * sourceSize.height <= 16_777_216 else { throw MultiCameraFrameError.invalidImage }
        // Preserve the exact aspect ratio, just as LivePreviewRasterGeometry
        // does. Independent rounding would stretch/crop normalized contours.
        var divisor = sourceSize.width, remainder = sourceSize.height
        while remainder != 0 { let next = divisor % remainder; divisor = remainder; remainder = next }
        let unitWidth = sourceSize.width / divisor, unitHeight = sourceSize.height / divisor
        let multiplier = maximumDimension.map { min(divisor, $0 / max(unitWidth, unitHeight)) } ?? divisor
        guard multiplier > 0 else { throw MultiCameraFrameError.invalidImage }
        let outputWidth = unitWidth * multiplier, outputHeight = unitHeight * multiplier
        let resources = try cachedResources.withLock { cached in
            if let cached { return cached }
            let created = try Resources()
            cached = created
            return created
        }
        return try resources.rectify(pixelBuffer: pixelBuffer, calibration: calibration,
                                     width: outputWidth, height: outputHeight)
    }

    private static func copyDepth(_ depth: AVDepthData) throws -> DepthMap {
        let converted = depth.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depth : depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let buffer = converted.depthDataMap
        let size = PixelSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard size.isValid, size.width <= 2_048, size.height <= 2_048,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw MultiCameraFrameError.invalidDepth
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), stride >= size.width * MemoryLayout<Float>.stride else {
            throw MultiCameraFrameError.invalidDepth
        }
        var values = [Float](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<size.width {
                let value = row[x]
                values[y * size.width + x] = value.isFinite && value > 0 ? value : 0
            }
        }
        // AVDepthData does not deliver ARKit per-pixel confidence. Nil is unknown.
        return DepthMap(size: size, values: values, confidence: nil)
    }

    private nonisolated struct Uniforms {
        var imageSize: SIMD2<UInt32>
        var outputSize: SIMD2<UInt32>
        var distortionCenter: SIMD2<Float>
        var lookupCount: UInt32
        var padding: UInt32 = 0
    }

    private nonisolated final class Resources: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let context: CIContext
        let textureCache: CVMetalTextureCache

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw MultiCameraFrameError.rendererUnavailable
            }
            let library = try device.makeLibrary(source: MultiCameraRectifier.shader, options: nil)
            guard let function = library.makeFunction(name: "dobby_rectify_wide") else {
                throw MultiCameraFrameError.rendererUnavailable
            }
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
                  let cache else { throw MultiCameraFrameError.rendererUnavailable }
            self.device = device
            self.queue = queue
            pipeline = try device.makeComputePipelineState(function: function)
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            textureCache = cache
        }

        func rectify(pixelBuffer: CVPixelBuffer, calibration: MultiCameraLensCalibration,
                     width: Int, height: Int) throws -> CGImage {
            let size = calibration.intrinsics.referenceSize
            var converted: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA,
                                      attributes as CFDictionary, &converted) == kCVReturnSuccess,
                  let converted else { throw MultiCameraFrameError.invalidImage }
            // CI's CVPixelBuffer output and the texture cache both use the same
            // top-row-first raster; do not insert a display rotation or Y flip.
            context.render(CIImage(cvPixelBuffer: pixelBuffer), to: converted,
                           bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            var sourceTexture: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, converted, nil,
                .bgra8Unorm, size.width, size.height, 0, &sourceTexture) == kCVReturnSuccess,
                  let sourceTexture, let input = CVMetalTextureGetTexture(sourceTexture) else {
                throw MultiCameraFrameError.invalidImage
            }
            let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: width, height: height, mipmapped: false)
            description.storageMode = .shared
            description.usage = [.shaderWrite, .shaderRead]
            guard let output = device.makeTexture(descriptor: description),
                  let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw MultiCameraFrameError.rendererUnavailable
            }
            var uniforms = Uniforms(imageSize: SIMD2(UInt32(size.width), UInt32(size.height)),
                outputSize: SIMD2(UInt32(width), UInt32(height)), distortionCenter: calibration.distortionCenter,
                lookupCount: UInt32(calibration.distortionLookupTable.count))
            let lut = calibration.distortionLookupTable
            let buffer = lut.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard let buffer else { throw MultiCameraFrameError.rendererUnavailable }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            let groupWidth = pipeline.threadExecutionWidth
            let groupHeight = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / groupWidth))
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { throw MultiCameraFrameError.rendererUnavailable }
            var bytes = Data(count: width * height * 4)
            bytes.withUnsafeMutableBytes { destination in
                output.getBytes(destination.baseAddress!, bytesPerRow: width * 4,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw MultiCameraFrameError.invalidImage
            }
            // Keep the CVMetalTexture/IOSurface alive through GPU completion.
            withExtendedLifetime((sourceTexture, converted)) {}
            return image
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct RectifyUniforms {
        uint2 imageSize;
        uint2 outputSize;
        float2 distortionCenter;
        uint lookupCount;
        uint padding;
    };
    kernel void dobby_rectify_wide(texture2d<float, access::sample> input [[texture(0)]],
                                  texture2d<float, access::write> output [[texture(1)]],
                                  device const float *lookup [[buffer(0)]],
                                  constant RectifyUniforms &u [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= u.outputSize)) return;
        float2 size = float2(u.imageSize);
        float2 point = (float2(gid) + 0.5f) * size / float2(u.outputSize);
        float2 farthest = max(u.distortionCenter, size - u.distortionCenter);
        float radiusMaximum = length(farthest);
        float2 delta = point - u.distortionCenter;
        float index = clamp(length(delta) / radiusMaximum * float(u.lookupCount - 1), 0.0f, float(u.lookupCount - 1));
        uint lower = min(uint(index), u.lookupCount - 2);
        float magnification = mix(lookup[lower], lookup[lower + 1], index - float(lower));
        float2 source = u.distortionCenter + delta * (1.0f + magnification);
        if (any(source < 0.0f) || any(source >= size)) {
            output.write(float4(0.0f), gid);
            return;
        }
        constexpr sampler sampling(coord::normalized, address::clamp_to_edge, filter::linear);
        output.write(input.sample(sampling, source / size), gid);
    }
    """
}

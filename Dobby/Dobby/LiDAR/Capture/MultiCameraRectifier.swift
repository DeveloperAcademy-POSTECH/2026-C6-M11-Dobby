import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import Synchronization

/// Owned snapshot data from a calibrated RGB/depth pair.
nonisolated struct MultiCameraRectifiedFrame: @unchecked Sendable {
    let sessionID: UUID
    let timestamp: TimeInterval
    let image: CGImage
    let depth: DepthMap
    let intrinsics: CameraIntrinsics
}

/// A single inverse radial map is shared by RGB and axial depth. Captured RGB
/// retains its full-resolution color-managed path. Small live-analysis rasters
/// sample supported camera textures directly; depth retains nearest samples
/// and invalid holes.
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
            width: outputWidth, height: outputHeight,
            directPreview: maximumDimension != nil && max(outputWidth, outputHeight) <= 512)
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
        var format: UInt32 = 0
    }

    private nonisolated final class Resources: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let previewPipeline: MTLComputePipelineState
        let textureCache: CVMetalTextureCache
        private let cachedContext = Mutex<CIContext?>(nil)
        private var context: CIContext {
            cachedContext.withLock { cached in
                if let cached { return cached }
                let created = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
                cached = created
                return created
            }
        }
        let neutralChroma: MTLTexture
        private let lookupCache = Mutex<LookupEntry?>(nil)

        private struct LookupEntry {
            let table: [Float]
            let buffer: MTLBuffer
        }

        /// Only immutable lookup storage is shared across jobs. Outputs and CV
        /// wrappers remain job-owned, so callers need not share a GPU barrier.
        private func lookupBuffer(for table: [Float]) -> MTLBuffer? {
            lookupCache.withLock { cached in
                if let cached, cached.table == table { return cached.buffer }
                let buffer = table.withUnsafeBytes { bytes -> MTLBuffer? in
                    guard let base = bytes.baseAddress else { return nil }
                    return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
                }
                if let buffer { cached = LookupEntry(table: table, buffer: buffer) }
                return buffer
            }
        }

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw MultiCameraFrameError.rendererUnavailable
            }
            let library = try device.makeLibrary(source: MultiCameraRectifier.shader, options: nil)
            guard let function = library.makeFunction(name: "dobby_rectify_wide"),
                  let previewFunction = library.makeFunction(name: "dobby_rectify_live_wide") else {
                throw MultiCameraFrameError.rendererUnavailable
            }
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
                  let cache else { throw MultiCameraFrameError.rendererUnavailable }
            self.device = device
            self.queue = queue
            pipeline = try device.makeComputePipelineState(function: function)
            previewPipeline = try device.makeComputePipelineState(function: previewFunction)
            textureCache = cache
            let neutralDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm,
                width: 1, height: 1, mipmapped: false)
            neutralDescription.usage = .shaderRead
            guard let neutralChroma = device.makeTexture(descriptor: neutralDescription) else {
                throw MultiCameraFrameError.rendererUnavailable
            }
            var neutral = SIMD2<UInt8>(128, 128)
            neutralChroma.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                                  withBytes: &neutral, bytesPerRow: 2)
            self.neutralChroma = neutralChroma
        }

        /// Small previews preserve destination centres and the exact forward
        /// lens lookup, but avoid a source-size BGRA allocation/conversion.
        /// Unsupported camera color metadata keeps the color-managed fallback.
        func rectify(pixelBuffer: CVPixelBuffer, calibration: MultiCameraLensCalibration,
                     width: Int, height: Int, directPreview: Bool) throws -> CGImage {
            let size = calibration.intrinsics.referenceSize
            let direct = directPreview ? VideoTextures.make(pixelBuffer, cache: textureCache) : nil
            let source: VideoTextures
            if let direct {
                source = direct
            } else {
                var converted: CVPixelBuffer?
                let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                    kCVPixelBufferIOSurfacePropertiesKey: [:]]
                guard CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA,
                                          attributes as CFDictionary, &converted) == kCVReturnSuccess,
                      let converted else { throw MultiCameraFrameError.invalidImage }
                // Captured RGB keeps the existing color-managed conversion and
                // top-row-first raster. No display rotation or Y flip is added.
                context.render(CIImage(cvPixelBuffer: pixelBuffer), to: converted,
                               bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                guard let convertedSource = VideoTextures.make(converted, cache: textureCache) else {
                    throw MultiCameraFrameError.invalidImage
                }
                source = convertedSource
            }
            // Keep the pixel buffer, CVMetalTexture wrappers and IOSurface alive
            // until this job's synchronous GPU completion, including error exits.
            defer { withExtendedLifetime(source) {} }
            let selectedPipeline = direct == nil ? pipeline : previewPipeline
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
                lookupCount: UInt32(calibration.distortionLookupTable.count), format: source.format)
            guard let buffer = lookupBuffer(for: calibration.distortionLookupTable) else {
                throw MultiCameraFrameError.rendererUnavailable
            }
            encoder.setComputePipelineState(selectedPipeline)
            encoder.setTexture(source.luma, index: 0)
            if direct != nil {
                encoder.setTexture(source.chroma ?? neutralChroma, index: 1)
                encoder.setTexture(output, index: 2)
            } else {
                encoder.setTexture(output, index: 1)
            }
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            let groupWidth = selectedPipeline.threadExecutionWidth
            let groupHeight = max(1, min(8, selectedPipeline.maxTotalThreadsPerThreadgroup / groupWidth))
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
            return image
        }

        private struct VideoTextures {
            let buffer: CVPixelBuffer
            let retained: [CVMetalTexture]
            let luma: MTLTexture
            let chroma: MTLTexture?
            /// 0 BGRA, 1/2 BT.601 full/video, 3/4 BT.709 full/video.
            let format: UInt32

            static func make(_ buffer: CVPixelBuffer, cache: CVMetalTextureCache) -> Self? {
                let type = CVPixelBufferGetPixelFormatType(buffer)
                if type == kCVPixelFormatType_32BGRA,
                   let wrapper = texture(buffer, plane: 0, format: .bgra8Unorm, cache: cache),
                   let image = CVMetalTextureGetTexture(wrapper) {
                    return Self(buffer: buffer, retained: [wrapper], luma: image, chroma: nil, format: 0)
                }
                guard type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                        || type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                      CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
                let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
                // Do not treat unknown/BT.2020 metadata as BT.601. Core Image
                // remains the safe path for color spaces this shader cannot decode.
                guard matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
                        || matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String),
                      let y = texture(buffer, plane: 0, format: .r8Unorm, cache: cache),
                      let uv = texture(buffer, plane: 1, format: .rg8Unorm, cache: cache),
                      let luma = CVMetalTextureGetTexture(y), let chroma = CVMetalTextureGetTexture(uv) else { return nil }
                let full = type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                let bt709 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
                return Self(buffer: buffer, retained: [y, uv], luma: luma, chroma: chroma,
                            format: (full ? 1 : 2) + (bt709 ? 2 : 0))
            }

            private static func texture(_ buffer: CVPixelBuffer, plane: Int,
                                        format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
                let planar = CVPixelBufferIsPlanar(buffer)
                let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
                let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
                var wrapper: CVMetalTexture?
                guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
                    format, width, height, plane, &wrapper) == kCVReturnSuccess else { return nil }
                return wrapper
            }
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
        uint format;
    };
    float2 liveSource(uint2 gid, constant RectifyUniforms &u, device const float *lookup) {
        float2 size = float2(u.imageSize);
        float2 point = (float2(gid) + 0.5f) * size / float2(u.outputSize);
        float2 farthest = max(u.distortionCenter, size - u.distortionCenter);
        float radiusMaximum = length(farthest);
        float2 delta = point - u.distortionCenter;
        float index = clamp(length(delta) / radiusMaximum * float(u.lookupCount - 1), 0.0f, float(u.lookupCount - 1));
        uint lower = min(uint(index), u.lookupCount - 2);
        float magnification = mix(lookup[lower], lookup[lower + 1], index - float(lower));
        return u.distortionCenter + delta * (1.0f + magnification);
    }
    kernel void dobby_rectify_live_wide(texture2d<float, access::sample> y [[texture(0)]],
                                       texture2d<float, access::sample> uv [[texture(1)]],
                                       texture2d<float, access::write> output [[texture(2)]],
                                       device const float *lookup [[buffer(0)]],
                                       constant RectifyUniforms &u [[buffer(1)]],
                                       uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= u.outputSize)) return;
        float2 source = liveSource(gid, u, lookup);
        float2 size = float2(u.imageSize);
        if (any(source < 0.0f) || any(source >= size)) {
            output.write(float4(0.0f), gid);
            return;
        }
        constexpr sampler sampling(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 p = source / size;
        float4 color = y.sample(sampling, p);
        if (u.format == 0) { output.write(color, gid); return; }
        float luma = color.r;
        float2 chroma = uv.sample(sampling, p).rg - float2(128.0f / 255.0f);
        bool full = u.format == 1 || u.format == 3;
        if (!full) { luma = (luma - 16.0f / 255.0f) * (255.0f / 219.0f); chroma *= 255.0f / 224.0f; }
        bool bt709 = u.format >= 3;
        float3 rgb = float3(luma + (bt709 ? 1.5748f : 1.4020f) * chroma.y,
            luma - (bt709 ? 0.187324f : 0.344136f) * chroma.x - (bt709 ? 0.468124f : 0.714136f) * chroma.y,
            luma + (bt709 ? 1.8556f : 1.7720f) * chroma.x);
        output.write(float4(clamp(rgb, 0.0f, 1.0f), 1.0f), gid);
    }
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

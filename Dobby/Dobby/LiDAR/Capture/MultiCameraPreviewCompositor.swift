import AVFoundation
import CoreVideo
import Metal
import OSLog
import QuartzCore
import Synchronization
import simd

/// Low-level renderer input is separate from the validated capture packet so
/// generated GPU fixtures never masquerade as a real calibrated measurement.
nonisolated struct MultiCameraRenderInputs: @unchecked Sendable {
    let sessionID: UUID
    let timestamp: TimeInterval
    let wideImage: CVPixelBuffer
    let ultraWideImage: CVPixelBuffer
    let depth: CVPixelBuffer
    let wideIntrinsics: simd_float3x3
    let ultraWideIntrinsics: simd_float3x3
    let wideToUltra: simd_float4x3
    let wideCalibration: MultiCameraLensCalibration

    init(sessionID: UUID, timestamp: TimeInterval, wideImage: CVPixelBuffer, ultraWideImage: CVPixelBuffer,
         depth: CVPixelBuffer, wideIntrinsics: simd_float3x3, ultraWideIntrinsics: simd_float3x3,
         wideToUltra: simd_float4x3, wideCalibration: MultiCameraLensCalibration) {
        self.sessionID = sessionID; self.timestamp = timestamp
        self.wideImage = wideImage; self.ultraWideImage = ultraWideImage; self.depth = depth
        self.wideIntrinsics = wideIntrinsics; self.ultraWideIntrinsics = ultraWideIntrinsics
        self.wideToUltra = wideToUltra; self.wideCalibration = wideCalibration
    }

    init(_ frame: MultiCameraFrame) {
        self.init(sessionID: frame.sessionID, timestamp: frame.timestamp,
            wideImage: frame.wideImage, ultraWideImage: frame.ultraWideImage, depth: frame.depthData.depthDataMap,
            wideIntrinsics: frame.wideIntrinsics, ultraWideIntrinsics: frame.ultraWideIntrinsics,
            wideToUltra: frame.wideToUltra, wideCalibration: frame.wideCalibration)
    }
}

/// A latest-frame, one-command GPU compositor. It never copies a camera raster
/// through UIImage or serializes preview work with the landmark model queue.
nonisolated final class MultiCameraPreviewCompositor: @unchecked Sendable {
    private struct Key: Equatable {
        let sessionID: UUID
        let timestamp: TimeInterval
        let width: CGFloat
        let height: CGFloat
        let generation: UInt64
    }
    private struct State {
        var generation: UInt64 = 0
        var sessionID: UUID?
        var ready = false
        var busy = false
        var lastKey: Key?
    }
    private let state = Mutex(State())
    private let device: any MTLDevice
    private let queue = DispatchQueue(label: "com.dobby.lidar.multicam-preview", qos: .userInteractive)
    private var commandQueue: (any MTLCommandQueue)?
    private var pipeline: (any MTLRenderPipelineState)?
    private var textureCache: CVMetalTextureCache?
    private var neutralChroma: (any MTLTexture)?
    private var colorGain = SIMD3<Float>(repeating: 1)
    private var colorSessionID: UUID?
    private static let logger = Logger(subsystem: "com.dobby.lidar", category: "multicam-preview")

    init(device: any MTLDevice) {
        self.device = device
        queue.async { [self] in prepare() }
    }

    func invalidate() {
        state.withLock { value in
            value.generation &+= 1
            value.lastKey = nil
        }
    }

    func needsFrame(sessionID: UUID, timestamp: TimeInterval, canvasSize: CGSize) -> Bool {
        state.withLock { value in
            if value.sessionID != sessionID {
                value.sessionID = sessionID
                value.generation &+= 1
                value.lastKey = nil
            }
            return value.ready && !value.busy && value.lastKey != Key(sessionID: sessionID,
                timestamp: timestamp, width: canvasSize.width, height: canvasSize.height,
                generation: value.generation)
        }
    }

    func render(frame: MultiCameraFrame, geometry: MultiCameraPreviewGeometry.Mapping,
                canvasSize: CGSize, drawable: any CAMetalDrawable) {
        submit(inputs: MultiCameraRenderInputs(frame), geometry: geometry, canvasSize: canvasSize,
               target: RenderTarget(drawable))
    }

    /// GPU fixture entry: identical textures, uniforms, shaders and completion
    /// barriers, with an offscreen texture in place of a display drawable.
    func renderFixture(inputs: MultiCameraRenderInputs, geometry: MultiCameraPreviewGeometry.Mapping,
                       canvasSize: CGSize, texture: any MTLTexture,
                       completion: @escaping @Sendable (Bool) -> Void) {
        let target = RenderTarget(texture: texture, completion: completion)
        // Serial enqueue waits for the real pipeline preparation without a
        // sleeping polling loop or any test-only change to the shader path.
        queue.async { [self, inputs, target] in
            submit(inputs: inputs, geometry: geometry, canvasSize: canvasSize, target: target)
        }
    }

    private func submit(inputs: MultiCameraRenderInputs, geometry: MultiCameraPreviewGeometry.Mapping,
                        canvasSize: CGSize, target: RenderTarget) {
        let key: Key? = state.withLock { value in
            guard value.ready, !value.busy else { return nil }
            let key = Key(sessionID: inputs.sessionID, timestamp: inputs.timestamp,
                width: canvasSize.width, height: canvasSize.height, generation: value.generation)
            guard key != value.lastKey else { return nil }
            value.busy = true
            return key
        }
        guard let key else { target.complete(false); return }
        queue.async { [self, inputs, target] in
            autoreleasepool { encode(frame: inputs, geometry: geometry, canvasSize: canvasSize,
                                      target: target, key: key) }
        }
    }

    private func prepare() {
        guard let commandQueue = device.makeCommandQueue() else {
            Self.logger.error("Multi-camera preview could not create its Metal command queue")
            return
        }
        let library: any MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaderSource, options: nil) }
        catch {
            Self.logger.error("Multi-camera preview Metal source failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let vertex = library.makeFunction(name: "cameraPreviewVertex"),
              let fragment = library.makeFunction(name: "cameraPreviewFragment") else {
            Self.logger.error("Multi-camera preview Metal entry functions are missing")
            return
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline: any MTLRenderPipelineState
        do { pipeline = try device.makeRenderPipelineState(descriptor: descriptor) }
        catch {
            Self.logger.error("Multi-camera preview pipeline failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return }
        let chromaDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm,
            width: 1, height: 1, mipmapped: false)
        chromaDescriptor.usage = .shaderRead
        guard let neutralChroma = device.makeTexture(descriptor: chromaDescriptor) else { return }
        var neutral = SIMD2<UInt8>(128, 128)
        neutralChroma.replace(region: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1, height: 1, depth: 1)),
                              mipmapLevel: 0, withBytes: &neutral, bytesPerRow: 2)
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.textureCache = cache
        self.neutralChroma = neutralChroma
        state.withLock { $0.ready = true }
    }

    private func encode(frame: MultiCameraRenderInputs, geometry: MultiCameraPreviewGeometry.Mapping,
                        canvasSize: CGSize, target: RenderTarget, key: Key) {
        guard isCurrent(key), let pipeline, let commandQueue, let textureCache, let neutralChroma,
              let wide = VideoTextures.make(frame.wideImage, cache: textureCache),
              let ultra = VideoTextures.make(frame.ultraWideImage, cache: textureCache),
              let depth = depthTexture(frame.depth, cache: textureCache),
              let command = commandQueue.makeCommandBuffer() else { finish(key, presented: false, target: target); return }

        if colorSessionID != frame.sessionID { colorSessionID = frame.sessionID; colorGain = SIMD3(repeating: 1) }
        if let measured = MultiCameraPreviewColorMatch.gain(frame: frame) {
            // Only low-frequency exposure/white-balance compensation is smoothed;
            // camera pixels and their timing are never interpolated or delayed.
            colorGain += (measured - colorGain) * 0.18
        }
        var uniforms = Uniforms(frame: frame, geometry: geometry, canvasSize: canvasSize,
            wideFormat: wide.format, ultraFormat: ultra.format, colorGain: colorGain)
        let table = frame.wideCalibration.distortionLookupTable
        guard let lookup = table.withUnsafeBytes({ bytes -> (any MTLBuffer)? in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }) else { finish(key, presented: false, target: target); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            finish(key, presented: false, target: target); return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBuffer(lookup, offset: 0, index: 1)
        encoder.setFragmentTexture(wide.luma, index: 0)
        encoder.setFragmentTexture(wide.chroma ?? neutralChroma, index: 1)
        encoder.setFragmentTexture(ultra.luma, index: 2)
        encoder.setFragmentTexture(ultra.chroma ?? neutralChroma, index: 3)
        encoder.setFragmentTexture(depth.texture, index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        // Retain all CVMetalTexture wrappers and their pixel buffers through GPU
        // completion. A resize/session change cannot present an obsolete frame.
        let retainedLookup = RetainedMetalBuffer(lookup)
        command.addCompletedHandler { [self, frame, wide, ultra, depth, retainedLookup, target] command in
            _ = (frame, wide, ultra, depth, retainedLookup)
            let present = command.status == .completed && isCurrent(key)
            if present { target.present() }
            finish(key, presented: present, target: target)
        }
        guard isCurrent(key) else { finish(key, presented: false, target: target); return }
        command.commit()
    }

    private func isCurrent(_ key: Key) -> Bool { state.withLock { $0.generation == key.generation } }
    private func finish(_ key: Key, presented: Bool, target: RenderTarget) {
        state.withLock { value in
            value.busy = false
            if presented, value.generation == key.generation { value.lastKey = key }
        }
        target.complete(presented)
    }

    private static func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                                cache: CVMetalTextureCache) -> CVMetalTexture? {
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var result: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
            format, width, height, plane, &result) == kCVReturnSuccess else { return nil }
        return result
    }

    /// Immutable strong retention through GPU completion. The buffer is never
    /// mutated while the command reads it, even across executor boundaries.
    private struct RetainedMetalBuffer: @unchecked Sendable {
        let buffer: any MTLBuffer
        init(_ buffer: any MTLBuffer) { self.buffer = buffer }
    }

    private struct DepthTexture: @unchecked Sendable {
        let texture: any MTLTexture
        let retained: CVMetalTexture?
    }

    private func depthTexture(_ buffer: CVPixelBuffer, cache: CVMetalTextureCache) -> DepthTexture? {
        if let source = Self.texture(buffer, plane: 0, format: .r32Float, cache: cache),
           let texture = CVMetalTextureGetTexture(source) {
            return .init(texture: texture, retained: source)
        }
        // AVDepthData does not promise a Metal-compatible IOSurface. Copy only
        // this small Float32 depth raster when direct texture wrapping fails.
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        texture.replace(region: .init(origin: .init(x: 0, y: 0, z: 0),
            size: .init(width: width, height: height, depth: 1)), mipmapLevel: 0,
            withBytes: base, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        return .init(texture: texture, retained: nil)
    }

    private struct VideoTextures: @unchecked Sendable {
        let retained: [CVMetalTexture]
        let luma: any MTLTexture
        let chroma: (any MTLTexture)?
        let format: UInt32

        static func make(_ buffer: CVPixelBuffer, cache: CVMetalTextureCache) -> Self? {
            let type = CVPixelBufferGetPixelFormatType(buffer)
            if type == kCVPixelFormatType_32BGRA,
               let texture = MultiCameraPreviewCompositor.texture(buffer, plane: 0, format: .bgra8Unorm, cache: cache),
               let metal = CVMetalTextureGetTexture(texture) {
                return .init(retained: [texture], luma: metal, chroma: nil, format: 0)
            }
            guard type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  let y = MultiCameraPreviewCompositor.texture(buffer, plane: 0, format: .r8Unorm, cache: cache),
                  let uv = MultiCameraPreviewCompositor.texture(buffer, plane: 1, format: .rg8Unorm, cache: cache),
                  let luma = CVMetalTextureGetTexture(y), let chroma = CVMetalTextureGetTexture(uv) else { return nil }
            let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
            let bt709 = (matrix as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            let full = type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return .init(retained: [y, uv], luma: luma, chroma: chroma,
                         format: (full ? 1 : 2) + (bt709 ? 2 : 0))
        }
    }

    private final class RenderTarget: @unchecked Sendable {
        let texture: any MTLTexture
        private let drawable: (any CAMetalDrawable)?
        private let completion: (@Sendable (Bool) -> Void)?
        init(_ drawable: any CAMetalDrawable) {
            self.drawable = drawable; texture = drawable.texture; completion = nil
        }
        init(texture: any MTLTexture, completion: @escaping @Sendable (Bool) -> Void) {
            self.texture = texture; drawable = nil; self.completion = completion
        }
        func present() { drawable?.present() }
        func complete(_ success: Bool) { completion?(success) }
    }

    private struct Uniforms {
        var canvasToSensor: simd_float3x3
        var inverseWideK: simd_float3x3
        var ultraK: simd_float3x3
        var rotation: simd_float3x3
        var translation: SIMD4<Float>
        var canvasAndWide: SIMD4<Float>
        var ultraAndDepth: SIMD4<Float>
        var photoRect: SIMD4<Float>
        var distortion: SIMD4<Float>
        var colorGain: SIMD4<Float>
        var formats: SIMD4<UInt32>

        init(frame: MultiCameraRenderInputs, geometry: MultiCameraPreviewGeometry.Mapping,
             canvasSize: CGSize, wideFormat: UInt32, ultraFormat: UInt32, colorGain: SIMD3<Float>) {
            let a = geometry.canvasToSensor
            canvasToSensor = .init(columns: (SIMD3(Float(a.a), Float(a.b), 0),
                SIMD3(Float(a.c), Float(a.d), 0), SIMD3(Float(a.tx), Float(a.ty), 1)))
            inverseWideK = frame.wideIntrinsics.inverse
            ultraK = frame.ultraWideIntrinsics
            rotation = .init(columns: (frame.wideToUltra.columns.0, frame.wideToUltra.columns.1,
                                       frame.wideToUltra.columns.2))
            translation = SIMD4(frame.wideToUltra.columns.3, 0)
            canvasAndWide = SIMD4(Float(canvasSize.width), Float(canvasSize.height),
                Float(CVPixelBufferGetWidth(frame.wideImage)), Float(CVPixelBufferGetHeight(frame.wideImage)))
            ultraAndDepth = SIMD4(Float(CVPixelBufferGetWidth(frame.ultraWideImage)),
                Float(CVPixelBufferGetHeight(frame.ultraWideImage)),
                Float(CVPixelBufferGetWidth(frame.depth)), Float(CVPixelBufferGetHeight(frame.depth)))
            let rect = geometry.photoRect
            photoRect = SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.maxX), Float(rect.maxY))
            let center = frame.wideCalibration.distortionCenter
            let extent = SIMD2(canvasAndWide.z, canvasAndWide.w)
            let farCorner = max(center, extent - center)
            distortion = SIMD4(center.x, center.y, simd_length(farCorner),
                               Float(frame.wideCalibration.distortionLookupTable.count))
            self.colorGain = SIMD4(colorGain, 0)
            formats = SIMD4(wideFormat, ultraFormat, 0, 0)
        }
    }

    /// Kept internal so validation compiles the SAME runtime shader used by the
    /// app; a successful Swift build alone cannot validate Metal source strings.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct U {
        float3x3 canvasToSensor, inverseWideK, ultraK, rotation;
        float4 translation, canvasAndWide, ultraAndDepth, photoRect, distortion, colorGain;
        uint4 formats;
    };
    struct V { float4 position [[position]]; float2 uv; };
    vertex V cameraPreviewVertex(uint id [[vertex_id]]) {
        const float2 p[6] = { float2(-1,1), float2(-1,-1), float2(1,1),
                             float2(1,1), float2(-1,-1), float2(1,-1) };
        const float2 t[6] = { float2(0,0), float2(0,1), float2(1,0),
                             float2(1,0), float2(0,1), float2(1,1) };
        return { float4(p[id],0,1), t[id] };
    }
    bool inside(float2 uv) { return all(isfinite(uv)) && all(uv >= 0.0) && all(uv <= 1.0); }
    float2 distorted(float2 p, constant U& u, const device float* table) {
        float2 v = p - u.distortion.xy;
        float position = clamp(length(v) / max(u.distortion.z, 1.0), 0.0, 1.0) * (u.distortion.w - 1.0);
        uint lo = uint(position), hi = min(lo + 1, uint(u.distortion.w - 1));
        return u.distortion.xy + v * (1.0 + mix(table[lo], table[hi], fract(position)));
    }
    float3 rgb(texture2d<float> y, texture2d<float> uv, float2 p, uint format) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 color = y.sample(s,p);
        if (format == 0) return color.rgb;
        float luma = color.r;
        float2 chroma = uv.sample(s,p).rg - float2(128.0 / 255.0);
        bool full = format == 1 || format == 3;
        if (!full) { luma = (luma - 16.0/255.0) * (255.0/219.0); chroma *= 255.0/224.0; }
        bool bt709 = format >= 3;
        return clamp(float3(luma + (bt709 ? 1.5748 : 1.4020) * chroma.y,
            luma - (bt709 ? 0.187324 : 0.344136) * chroma.x - (bt709 ? 0.468124 : 0.714136) * chroma.y,
            luma + (bt709 ? 1.8556 : 1.7720) * chroma.x), 0.0, 1.0);
    }
    float depthAt(float2 p, constant U& u, const device float* table, texture2d<float> depth) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
        float2 uv = distorted(p,u,table) / u.canvasAndWide.zw;
        if (!inside(uv)) return 0;
        float z = depth.sample(s,uv).r;
        return isfinite(z) && z >= 0.15 && z <= 6.0 ? z : 0.0;
    }
    float3 borderPoint(float2 p, constant U& u, const device float* table, texture2d<float> depth) {
        float2 size = u.canvasAndWide.zw;
        float2 step = max(float2(4.0), size / u.ultraAndDepth.zw * 2.0);
        // Fit inverse-depth on a 3x3 patch, which is exactly affine for a
        // pinhole image of an arbitrarily tilted plane. A constant border Z
        // would shear a sloping floor as soon as the ray leaves the wide image.
        float2 margin = step * 2.0;
        float2 anchor = clamp(p, margin, size - margin);
        float3 anchorRay = u.inverseWideK * float3(anchor,1);
        float3 features[9]; float values[9]; uint count = 0;
        float3x3 normal = float3x3(0.0); float3 rhs = float3(0.0);
        for (int y = -1; y <= 1; ++y) { for (int x = -1; x <= 1; ++x) {
            float2 probe = anchor + float2(x,y)*step;
            float z = depthAt(probe,u,table,depth);
            if (z == 0.0) continue;
            float3 ray = u.inverseWideK * float3(probe,1);
            float3 f = float3(ray.xy-anchorRay.xy,1);
            normal += float3x3(f*f.x,f*f.y,f*f.z); rhs += f/z;
            features[count] = f; values[count] = 1.0/z; ++count;
        } }
        if (count < 5) return float3(0,0,-1);
        float determinant = dot(normal[0],cross(normal[1],normal[2]));
        if (abs(determinant) < 1e-10) return float3(0,0,-1);
        float3 coefficients = float3(dot(rhs,cross(normal[1],normal[2])),
            dot(normal[0],cross(rhs,normal[2])),dot(normal[0],cross(normal[1],rhs))) / determinant;
        // Reject a mixed foreground/background patch rather than extrapolating
        // a made-up slope. Refit with its coherent inliers to tolerate noise.
        normal = float3x3(0.0); rhs = float3(0.0); uint inliers = 0;
        for (uint i = 0; i < count; ++i) {
            float z = 1.0/values[i];
            float residualMetres = abs(dot(coefficients,features[i])-values[i])*z*z;
            if (residualMetres <= 0.025) {
                float3 f = features[i];
                normal += float3x3(f*f.x,f*f.y,f*f.z); rhs += f*values[i]; ++inliers;
            }
        }
        if (inliers < 5 || inliers*3 < count*2) return float3(0,0,-1);
        determinant = dot(normal[0],cross(normal[1],normal[2]));
        if (abs(determinant) < 1e-10) return float3(0,0,-1);
        coefficients = float3(dot(rhs,cross(normal[1],normal[2])),
            dot(normal[0],cross(rhs,normal[2])),dot(normal[0],cross(normal[1],rhs))) / determinant;
        float3 ray = u.inverseWideK * float3(p,1);
        float inverseZ = dot(coefficients,float3(ray.xy-anchorRay.xy,1));
        if (!isfinite(inverseZ) || inverseZ <= 0.0) return float3(0,0,-1);
        float z = 1.0/inverseZ;
        return z >= 0.15 && z <= 6.0 ? ray*z : float3(0,0,-1);
    }
    fragment float4 cameraPreviewFragment(V in [[stage_in]], constant U& u [[buffer(0)]],
        const device float* table [[buffer(1)]], texture2d<float> wideY [[texture(0)]],
        texture2d<float> wideUV [[texture(1)]], texture2d<float> ultraY [[texture(2)]],
        texture2d<float> ultraUV [[texture(3)]], texture2d<float> depth [[texture(4)]]) {
        float2 canvas = in.uv * u.canvasAndWide.xy;
        float2 sensor = (u.canvasToSensor * float3(canvas,1)).xy;
        float2 widePixel = sensor * u.canvasAndWide.zw;
        float2 wideUVPoint = distorted(widePixel,u,table) / u.canvasAndWide.zw;
        bool wideValid = inside(sensor) && inside(wideUVPoint);
        bool photo = all(canvas >= u.photoRect.xy) && all(canvas <= u.photoRect.zw);
        float3 color = float3(0);
        if (wideValid) color = rgb(wideY,wideUV,wideUVPoint,u.formats.x);
        if (!photo) {
            float3 point = borderPoint(widePixel,u,table,depth);
            {
                // A missing local plane must not punch a black hole in the
                // wider live view. At infinity, translation vanishes: project
                // only the calibrated ray direction. This display-only fallback
                // never invents a depth or supplies pixels to measurement RGB.
                float3 ray = u.inverseWideK * float3(widePixel,1);
                float3 ultraPosition = point.z > 0 ? u.rotation*point+u.translation.xyz : u.rotation*ray;
                float3 projected = u.ultraK * ultraPosition;
                float2 ultraPoint = projected.xy / projected.z / u.ultraAndDepth.xy;
                if (projected.z > 0 && inside(ultraPoint)) {
                    float3 ultraColor = rgb(ultraY,ultraUV,ultraPoint,u.formats.y) * u.colorGain.rgb;
                    float2 borderDistance = min(sensor,1.0-sensor)*u.canvasAndWide.zw;
                    float2 rawBorderDistance = min(wideUVPoint,1.0-wideUVPoint)*u.canvasAndWide.zw;
                    float edge = min(min(borderDistance.x,borderDistance.y),min(rawBorderDistance.x,rawBorderDistance.y));
                    float2 rate = (u.canvasToSensor*float3(1,0,0)).xy * u.canvasAndWide.zw;
                    float feather = max(2.0,length(rate)*4.0);
                    float2 outsidePhoto = max(max(u.photoRect.xy-canvas,canvas-u.photoRect.zw),float2(0));
                    float photoFade = smoothstep(0.0,4.0,length(outsidePhoto));
                    float blend = (1.0-smoothstep(0.0,feather,edge))*photoFade;
                    // Feather only captured overlap outside the strict photo.
                    // At full 4:3 there is no spare wide overlap: project ultra
                    // directly instead of repeating or stretching wide edges.
                    color = wideValid ? mix(color,ultraColor,blend) : ultraColor;
                }
            }
        }
        // The compositor returns unshaded camera pixels across the complete
        // canvas. Native SwiftUI regular Liquid Glass owns the chrome outside
        // the photograph; doing both would darken and blur that area twice.
        return float4(clamp(color,0.0,1.0),1);
    }
    """
}

/// Match only a few LiDAR-registered overlap probes. Reading 25 pixels avoids a
/// per-frame full-raster CPU conversion and does not change measurement RGB.
nonisolated private enum MultiCameraPreviewColorMatch {
    static func gain(frame: MultiCameraRenderInputs) -> SIMD3<Float>? {
        let wide = frame.wideImage, ultra = frame.ultraWideImage, depth = frame.depth
        guard CVPixelBufferLockBaseAddress(wide, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(wide, .readOnly) }
        guard CVPixelBufferLockBaseAddress(ultra, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(ultra, .readOnly) }
        guard CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let wideSize = PixelSize(width: CVPixelBufferGetWidth(wide), height: CVPixelBufferGetHeight(wide))
        let ultraSize = SIMD2(Float(CVPixelBufferGetWidth(ultra)), Float(CVPixelBufferGetHeight(ultra)))
        let depthWidth = CVPixelBufferGetWidth(depth), depthHeight = CVPixelBufferGetHeight(depth)
        let depthStride = CVPixelBufferGetBytesPerRow(depth)
        let inverseK = frame.wideIntrinsics.inverse
        let rotation = simd_float3x3(columns: (frame.wideToUltra.columns.0, frame.wideToUltra.columns.1, frame.wideToUltra.columns.2))
        var ratios: [SIMD3<Float>] = []
        for y in 1...5 { for x in 1...5 {
            let pixel = SIMD2(Float(wideSize.width) * Float(x) / 6, Float(wideSize.height) * Float(y) / 6)
            guard let source = frame.wideCalibration.sourcePoint(forRectifiedPixel: pixel, in: wideSize) else { continue }
            let uv = source / SIMD2(Float(wideSize.width), Float(wideSize.height))
            let dx = min(depthWidth-1,max(0,Int(uv.x*Float(depthWidth))))
            let dy = min(depthHeight-1,max(0,Int(uv.y*Float(depthHeight))))
            let z = depthBase.advanced(by: dy*depthStride).assumingMemoryBound(to: Float.self)[dx]
            guard z.isFinite, z >= 0.15, z <= 6 else { continue }
            let point = inverseK * SIMD3(pixel,1) * z
            let projected = frame.ultraWideIntrinsics * (rotation*point+frame.wideToUltra.columns.3)
            guard projected.z > 0 else { continue }
            let ultraPoint = SIMD2(projected.x,projected.y) / projected.z / ultraSize
            guard let w = color(wide,at: uv), let u = color(ultra,at: ultraPoint),
                  simd_reduce_min(w) > 0.08, simd_reduce_min(u) > 0.08,
                  simd_reduce_max(w) < 0.92, simd_reduce_max(u) < 0.92 else { continue }
            ratios.append(w/u)
        } }
        guard ratios.count >= 5 else { return nil }
        let median = SIMD3(ratios.map(\.x).sorted()[ratios.count/2],
                          ratios.map(\.y).sorted()[ratios.count/2], ratios.map(\.z).sorted()[ratios.count/2])
        return min(max(median,SIMD3(repeating:0.75)),SIMD3(repeating:1.33))
    }

    private static func color(_ buffer: CVPixelBuffer, at uv: SIMD2<Float>) -> SIMD3<Float>? {
        guard uv.x.isFinite, uv.y.isFinite, uv.x >= 0, uv.y >= 0, uv.x < 1, uv.y < 1 else { return nil }
        let x = Int(uv.x*Float(CVPixelBufferGetWidth(buffer))), y = Int(uv.y*Float(CVPixelBufferGetHeight(buffer)))
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(buffer) {
            let p = base.advanced(by: y*CVPixelBufferGetBytesPerRow(buffer)+x*4).assumingMemoryBound(to: UInt8.self)
            return SIMD3(Float(p[2]),Float(p[1]),Float(p[0])) / 255
        }
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer,0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer,1) else { return nil }
        var luma = Float(yBase.advanced(by: y*CVPixelBufferGetBytesPerRowOfPlane(buffer,0)+x).load(as: UInt8.self)) / 255
        let chroma = uvBase.advanced(by: (y/2)*CVPixelBufferGetBytesPerRowOfPlane(buffer,1)+(x/2)*2).assumingMemoryBound(to: UInt8.self)
        var cb = (Float(chroma[0])-128)/255, cr = (Float(chroma[1])-128)/255
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            luma = (luma-16/255)*(255/219); cb *= 255/224; cr *= 255/224
        }
        let matrix = CVBufferCopyAttachment(buffer,kCVImageBufferYCbCrMatrixKey,nil)
        let bt709 = (matrix as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        return SIMD3(luma+(bt709 ? 1.5748:1.402)*cr,
            luma-(bt709 ? 0.187324:0.344136)*cb-(bt709 ? 0.468124:0.714136)*cr,
            luma+(bt709 ? 1.8556:1.772)*cb)
    }
}

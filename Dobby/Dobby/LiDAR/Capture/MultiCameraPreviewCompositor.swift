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
    let wideCalibration: MultiCameraLensCalibration
    let revision: UInt64

    init(sessionID: UUID, timestamp: TimeInterval, wideImage: CVPixelBuffer,
         wideCalibration: MultiCameraLensCalibration, revision: UInt64 = 0) {
        self.sessionID = sessionID; self.timestamp = timestamp
        self.wideImage = wideImage; self.wideCalibration = wideCalibration; self.revision = revision
    }

    init(_ frame: MultiCameraFrame) {
        self.init(sessionID: frame.sessionID, timestamp: frame.timestamp,
            wideImage: frame.wideImage, wideCalibration: frame.wideCalibration)
    }

    init(_ preview: MultiCameraPreviewFrame) {
        // Rendering keeps only wide RGB + lens calibration. No depth camera
        // pool buffer is retained or uploaded by the display path.
        self.init(sessionID: preview.sessionID, timestamp: preview.timestamp,
            wideImage: preview.wideImage, wideCalibration: preview.wideCalibration, revision: preview.revision)
    }

}

/// A latest-frame, one-command GPU compositor. It never copies a camera raster
/// through UIImage or serializes preview work with the landmark model queue.
nonisolated final class MultiCameraPreviewCompositor: @unchecked Sendable {
    private struct Key: Equatable {
        let sessionID: UUID
        let timestamp: TimeInterval
        let revision: UInt64
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
        var lastRejectedKey: Key?
        var presentedSessionID: UUID?
    }
    private let state = Mutex(State())
    private let device: any MTLDevice
    private let queue = DispatchQueue(label: "com.dobby.lidar.multicam-preview", qos: .userInteractive)
    private var commandQueue: (any MTLCommandQueue)?
    private var pipeline: (any MTLRenderPipelineState)?
    private var textureCache: CVMetalTextureCache?
    private var neutralChroma: (any MTLTexture)?
    private var cachedLookup: (table: [Float], buffer: any MTLBuffer)?
    private static let logger = Logger(subsystem: "com.dobby.lidar", category: "multicam-preview")

    init(device: any MTLDevice) {
        self.device = device
        queue.async { [self] in prepare() }
    }

    /// Prepares immutable graphics resources only. It never opens a camera or
    /// changes capture ownership, and concurrent callers share one compilation.
    static func prewarm() {
        PipelineCache.shared.prewarm()
    }

    func invalidate() {
        state.withLock { value in
            value.generation &+= 1
            value.lastKey = nil
            value.presentedSessionID = nil
        }
    }

    func needsFrame(sessionID: UUID, timestamp: TimeInterval, revision: UInt64 = 0, canvasSize: CGSize) -> Bool {
        let decision = state.withLock { value -> (Bool, CameraFramePerformanceMetrics.DropReason?) in
            if value.sessionID != sessionID {
                value.sessionID = sessionID; value.generation &+= 1
                value.lastKey = nil; value.lastRejectedKey = nil
                value.presentedSessionID = nil
            }
            let key = Key(sessionID: sessionID, timestamp: timestamp, revision: revision,
                width: canvasSize.width, height: canvasSize.height, generation: value.generation)
            guard value.ready, !value.busy else {
                // Count each affected source/revision once, not every 60Hz poll.
                guard value.lastRejectedKey != key else { return (false, nil) }
                value.lastRejectedKey = key
                return (false, value.busy ? .rendererBusy : .rendererUnavailable)
            }
            return (value.lastKey != key, nil)
        }
        if let reason = decision.1 { CameraFramePerformanceMetrics.shared.drop(reason, sessionID: sessionID) }
        return decision.0
    }

    func render(frame: MultiCameraFrame, geometry: MultiCameraPreviewGeometry.Mapping,
                canvasSize: CGSize, drawable: any CAMetalDrawable) {
        submit(inputs: MultiCameraRenderInputs(frame), geometry: geometry, canvasSize: canvasSize,
               target: RenderTarget(drawable))
    }

    func render(preview: MultiCameraPreviewFrame, geometry: MultiCameraPreviewGeometry.Mapping,
                canvasSize: CGSize, drawable: any CAMetalDrawable,
                onPresented: (@Sendable (UUID) -> Void)? = nil) {
        submit(inputs: MultiCameraRenderInputs(preview), geometry: geometry, canvasSize: canvasSize,
               target: RenderTarget(drawable, onPresented: onPresented))
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
            if value.sessionID != inputs.sessionID {
                value.sessionID = inputs.sessionID; value.generation &+= 1
                value.lastKey = nil; value.lastRejectedKey = nil
                value.presentedSessionID = nil
            }
            guard value.ready, !value.busy else { return nil }
            let key = Key(sessionID: inputs.sessionID, timestamp: inputs.timestamp, revision: inputs.revision,
                width: canvasSize.width, height: canvasSize.height, generation: value.generation)
            guard key != value.lastKey else { return nil }
            value.busy = true
            return key
        }
        guard let key else { target.complete(false); return }
        let metrics = CameraFramePerformanceMetrics.shared
        let enqueuedAt = metrics.isEnabled ? ProcessInfo.processInfo.systemUptime : nil
        if let enqueuedAt { metrics.queued(sourceTimestamp: inputs.timestamp, hostTimestamp: enqueuedAt, sessionID: inputs.sessionID) }
        queue.async { [self, inputs, target] in
            if let enqueuedAt {
                metrics.latency(.previewQueueWait, seconds: ProcessInfo.processInfo.systemUptime - enqueuedAt,
                                sessionID: inputs.sessionID)
            }
            autoreleasepool { encode(frame: inputs, geometry: geometry, canvasSize: canvasSize,
                                      target: target, key: key) }
        }
    }

    private func prepare() {
        guard let commandQueue = device.makeCommandQueue() else {
            Self.logger.error("Multi-camera preview could not create its Metal command queue")
            return
        }
        guard let resources = PipelineCache.shared.resources(device: device, pixelFormat: .bgra8Unorm) else { return }
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
        self.pipeline = resources.pipeline
        self.textureCache = cache
        self.neutralChroma = neutralChroma
        state.withLock { $0.ready = true }
    }

    private func encode(frame: MultiCameraRenderInputs, geometry: MultiCameraPreviewGeometry.Mapping,
                        canvasSize: CGSize, target: RenderTarget, key: Key) {
        guard isCurrent(key), let pipeline, let commandQueue, let textureCache, let neutralChroma,
              let wide = VideoTextures.make(frame.wideImage, cache: textureCache),
              let command = commandQueue.makeCommandBuffer() else { finish(key, presented: false, target: target); return }
        var uniforms = Uniforms(frame: frame, geometry: geometry, canvasSize: canvasSize, wideFormat: wide.format)
        let table = frame.wideCalibration.distortionLookupTable
        let lookup: any MTLBuffer
        if let cachedLookup, cachedLookup.table == table { lookup = cachedLookup.buffer }
        else {
            guard let created = table.withUnsafeBytes({ bytes -> (any MTLBuffer)? in
                guard let base = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
            }) else { finish(key, presented: false, target: target); return }
            cachedLookup = (table, created); lookup = created
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            finish(key, presented: false, target: target); return
        }
        encoder.setRenderPipelineState(pipeline)
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0 else {
            encoder.endEncoding(); finish(key, presented: false, target: target); return
        }
        let sx = CGFloat(target.texture.width) / canvasSize.width
        let sy = CGFloat(target.texture.height) / canvasSize.height
        let rect = geometry.photoRect.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !rect.isNull, rect.width > 0, rect.height > 0 else {
            encoder.endEncoding(); finish(key, presented: false, target: target); return
        }
        let x = max(0, Int(floor(rect.minX * sx))), y = max(0, Int(floor(rect.minY * sy)))
        let right = min(target.texture.width, Int(ceil(rect.maxX * sx)))
        let bottom = min(target.texture.height, Int(ceil(rect.maxY * sy)))
        guard right > x, bottom > y else {
            encoder.endEncoding(); finish(key, presented: false, target: target); return
        }
        encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: right - x, height: bottom - y))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBuffer(lookup, offset: 0, index: 1)
        encoder.setFragmentTexture(wide.luma, index: 0)
        encoder.setFragmentTexture(wide.chroma ?? neutralChroma, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        // Retain all CVMetalTexture wrappers and their pixel buffers through GPU
        // completion. A resize/session change cannot present an obsolete frame.
        let retainedLookup = RetainedMetalBuffer(lookup)
        let metrics = CameraFramePerformanceMetrics.shared
        let submittedAt = metrics.isEnabled ? ProcessInfo.processInfo.systemUptime : nil
        command.addCompletedHandler { [self, frame, wide, retainedLookup, target] command in
            _ = (frame, wide, retainedLookup)
            let present = command.status == .completed && isCurrent(key)
            if let submittedAt {
                let now = ProcessInfo.processInfo.systemUptime
                metrics.event(.previewCompleted, timestamp: now, sessionID: frame.sessionID)
                metrics.latency(.previewGPUCompletion, seconds: now - submittedAt, sessionID: frame.sessionID)
            }
            if present {
                if let onPresented = target.onPresented, needsPresentationReceipt(key) {
                    target.present { [weak self] in
                        self?.didPresent(key, callback: onPresented)
                    }
                } else {
                    target.present()
                }
                if metrics.isEnabled {
                    metrics.presented(sourceTimestamp: frame.timestamp,
                        hostTimestamp: ProcessInfo.processInfo.systemUptime, sessionID: frame.sessionID)
                }
            }
            finish(key, presented: present, target: target)
        }
        guard isCurrent(key) else { finish(key, presented: false, target: target); return }
        if let submittedAt { metrics.event(.previewSubmitted, timestamp: submittedAt, sessionID: frame.sessionID) }
        command.commit()
    }

    private func isCurrent(_ key: Key) -> Bool { state.withLock { $0.generation == key.generation } }

    /// A GPU completion or a request to present is not evidence that the user
    /// has seen the image. Only an actually displayed, still-current drawable
    /// can retire an initial native preview. At most one callback per generation.
    private func didPresent(_ key: Key, callback: @Sendable (UUID) -> Void) {
        let notify = state.withLock { value in
            guard value.generation == key.generation, value.sessionID == key.sessionID,
                  value.presentedSessionID != key.sessionID else { return false }
            value.presentedSessionID = key.sessionID
            return true
        }
        if notify { callback(key.sessionID) }
    }

    private func needsPresentationReceipt(_ key: Key) -> Bool {
        state.withLock { value in
            value.generation == key.generation && value.sessionID == key.sessionID
                && value.presentedSessionID != key.sessionID
        }
    }
    private func finish(_ key: Key, presented: Bool, target: RenderTarget) {
        state.withLock { value in
            value.busy = false
            if presented, value.generation == key.generation { value.lastKey = key }
        }
        if !presented {
            CameraFramePerformanceMetrics.shared.drop(isCurrent(key) ? .rendererUnavailable : .staleFrame,
                sessionID: key.sessionID)
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
        let onPresented: (@Sendable (UUID) -> Void)?
        private let drawable: (any CAMetalDrawable)?
        private let completion: (@Sendable (Bool) -> Void)?
        init(_ drawable: any CAMetalDrawable, onPresented: (@Sendable (UUID) -> Void)? = nil) {
            self.drawable = drawable; texture = drawable.texture; completion = nil
            self.onPresented = onPresented
        }
        init(texture: any MTLTexture, completion: @escaping @Sendable (Bool) -> Void) {
            self.texture = texture; drawable = nil; self.completion = completion
            onPresented = nil
        }
        func present(afterDisplay: (@Sendable () -> Void)? = nil) {
            if let afterDisplay {
                drawable?.addPresentedHandler { presented in
                    guard presented.presentedTime.isFinite, presented.presentedTime > 0 else { return }
                    afterDisplay()
                }
            }
            drawable?.present()
        }
        func complete(_ success: Bool) { completion?(success) }
    }

    /// Metal libraries and render pipeline states are immutable and shareable.
    /// The cache owns a background serial worker: no caller compiles or waits
    /// for compilation on the main actor. Mutable texture caches and command
    /// queues deliberately remain specific to each compositor instance.
    private final class PipelineCache: @unchecked Sendable {
        private struct CacheKey: Hashable {
            let deviceID: UInt64
            let pixelFormat: UInt
        }
        struct Resources: @unchecked Sendable {
            let library: any MTLLibrary
            let pipeline: any MTLRenderPipelineState
        }
        static let shared = PipelineCache()
        private let worker = DispatchQueue(label: "com.dobby.lidar.preview-pipeline", qos: .userInitiated)
        // Accessed only on worker. Successful entries last for this process.
        private var entries: [CacheKey: Resources] = [:]

        func prewarm() {
            worker.async { [self] in
                guard let device = MTLCreateSystemDefaultDevice() else { return }
                _ = load(device: device, pixelFormat: .bgra8Unorm)
            }
        }

        func resources(device: any MTLDevice, pixelFormat: MTLPixelFormat) -> Resources? {
            // Called from the compositor's private preparation queue, never UI.
            worker.sync { load(device: device, pixelFormat: pixelFormat) }
        }

        private func load(device: any MTLDevice, pixelFormat: MTLPixelFormat) -> Resources? {
            let key = CacheKey(deviceID: device.registryID, pixelFormat: pixelFormat.rawValue)
            if let existing = entries[key] { return existing }
            do {
                let library = try device.makeLibrary(source: MultiCameraPreviewCompositor.shaderSource, options: nil)
                guard let vertex = library.makeFunction(name: "cameraPreviewVertex"),
                      let fragment = library.makeFunction(name: "cameraPreviewFragment") else {
                    MultiCameraPreviewCompositor.logger.error("Camera preview Metal entry functions are missing")
                    return nil
                }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = pixelFormat
                let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                let resources = Resources(library: library, pipeline: pipeline)
                entries[key] = resources
                return resources
            } catch {
                MultiCameraPreviewCompositor.logger.error("Camera preview graphics preparation failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    private struct Uniforms {
        var canvasToSensor: simd_float3x3
        var canvasAndWide: SIMD4<Float>
        var photoRect: SIMD4<Float>
        var distortion: SIMD4<Float>
        var formats: SIMD4<UInt32>

        init(frame: MultiCameraRenderInputs, geometry: MultiCameraPreviewGeometry.Mapping,
             canvasSize: CGSize, wideFormat: UInt32) {
            let a = geometry.canvasToSensor
            canvasToSensor = .init(columns: (SIMD3(Float(a.a), Float(a.b), 0),
                SIMD3(Float(a.c), Float(a.d), 0), SIMD3(Float(a.tx), Float(a.ty), 1)))
            canvasAndWide = SIMD4(Float(canvasSize.width), Float(canvasSize.height),
                Float(CVPixelBufferGetWidth(frame.wideImage)), Float(CVPixelBufferGetHeight(frame.wideImage)))
            let rect = geometry.photoRect
            photoRect = SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.maxX), Float(rect.maxY))
            let center = frame.wideCalibration.distortionCenter
            let farCorner = max(center, SIMD2(canvasAndWide.z, canvasAndWide.w) - center)
            distortion = SIMD4(center.x, center.y, simd_length(farCorner),
                               Float(frame.wideCalibration.distortionLookupTable.count))
            formats = SIMD4(wideFormat, 0, 0, 0)
        }
    }

    /// Kept internal so validation compiles the SAME runtime shader used by the
    /// app; a successful Swift build alone cannot validate Metal source strings.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct U {
        float3x3 canvasToSensor;
        float4 canvasAndWide, photoRect, distortion;
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
    fragment float4 cameraPreviewFragment(V in [[stage_in]], constant U& u [[buffer(0)]],
        const device float* table [[buffer(1)]], texture2d<float> wideY [[texture(0)]],
        texture2d<float> wideUV [[texture(1)]]) {
        float2 canvas = in.uv * u.canvasAndWide.xy;
        bool photo = all(canvas >= u.photoRect.xy) && all(canvas <= u.photoRect.zw);
        if (!photo) return float4(0,0,0,1);
        float2 sensor = (u.canvasToSensor * float3(canvas,1)).xy;
        float2 widePixel = sensor * u.canvasAndWide.zw;
        float2 source = distorted(widePixel,u,table) / u.canvasAndWide.zw;
        if (!inside(sensor) || !inside(source)) return float4(0,0,0,1);
        return float4(clamp(rgb(wideY,wideUV,source,u.formats.x),0.0,1.0),1);
    }
    """
}

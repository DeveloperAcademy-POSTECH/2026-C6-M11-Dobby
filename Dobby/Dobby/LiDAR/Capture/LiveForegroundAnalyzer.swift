import ARKit
import CoreImage
import Foundation
import Vision

/// Preview-only foreground outlines, without clothing models, depth or capture quality.
nonisolated final class LiveForegroundAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dobby.lidar.live-foreground", qos: .userInitiated)
    private let cancellationQueue = DispatchQueue(label: "com.dobby.lidar.live-foreground-cancel", qos: .utility)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var orientation: ImageOrientation = .right
    private var identifier: UUID?
    private var readinessEpoch = UUID()
    private var busy = false
    private var isSuspended = false
    private var interactionGate = LivePreviewInteractionGate()
    private var activeJobID: UUID?
    private var activeRequest: VNGenerateForegroundInstanceMaskRequest?
    private var lastSubmissionTime: TimeInterval = -.infinity
    /// Submission ceiling, not a promise about Vision or device latency.
    private let minimumInterval: TimeInterval = 0.20

    init() {}

    func setOrientation(_ value: ImageOrientation) {
        lock.lock()
        guard value != orientation else { lock.unlock(); return }
        orientation = value
        readinessEpoch = UUID()
        lastSubmissionTime = -.infinity
        let request = activeRequest
        lock.unlock()
        request?.cancel()
    }

    func isCurrent(_ readiness: LiveCaptureReadiness) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return identifier != nil && !isSuspended && readiness.analysisEpoch == readinessEpoch
            && readiness.imageOrientation == orientation
    }

    func reset(sessionID: UUID?) {
        lock.lock()
        identifier = sessionID
        isSuspended = false
        interactionGate.reset(sessionID: sessionID)
        readinessEpoch = UUID()
        lastSubmissionTime = -.infinity
        let request = activeRequest
        // Cancelling Vision does not end its physical request immediately.
        // Keep busy until the worker exits to prevent a second request.
        lock.unlock()
        request?.cancel()
    }

    func invalidateReadiness() {
        lock.lock()
        readinessEpoch = UUID()
        let request = activeRequest
        lock.unlock()
        request?.cancel()
    }

    func suspend(sessionID: UUID) {
        lock.lock()
        guard identifier == sessionID else { lock.unlock(); return }
        isSuspended = true
        readinessEpoch = UUID()
        let request = activeRequest
        lock.unlock()
        request?.cancel()
    }

    func resume(sessionID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard identifier == sessionID, isSuspended else { return }
        isSuspended = false
        readinessEpoch = UUID()
        lastSubmissionTime = -.infinity
    }

    /// Only preview Vision yields; RGB/depth capture and photo measurement keep
    /// running. Do not publish a clearing result: the existing advisory outline
    /// retains its normal source-age limit while the camera takes priority.
    func prioritizeCameraInteraction(sessionID: UUID, duration: TimeInterval) {
        lock.lock()
        guard identifier == sessionID,
              interactionGate.prioritize(sessionID: sessionID, duration: duration,
                                         now: ProcessInfo.processInfo.systemUptime) else {
            lock.unlock()
            return
        }
        cancelInteractionAnalysisWhileLocked()
    }

    func setExposureAdjustmentActive(_ active: Bool, sessionID: UUID) {
        lock.lock()
        guard identifier == sessionID,
              interactionGate.setExposureAdjustmentActive(active, sessionID: sessionID,
                                                          now: ProcessInfo.processInfo.systemUptime) else {
            lock.unlock()
            return
        }
        cancelInteractionAnalysisWhileLocked()
    }

    /// Consumes the lock acquired by the caller. Never wait for Vision on the
    /// touch path or enqueue cancellation behind the running perform request.
    private func cancelInteractionAnalysisWhileLocked() {
        readinessEpoch = UUID()
        let cancellation = activeRequest.map(RequestCancellation.init)
        activeRequest = nil
        // Cancellation does not finish the job. Keep busy and activeJobID until
        // finish executes, even if another session or gesture starts meanwhile.
        lock.unlock()
        if let cancellation {
            cancellationQueue.async { cancellation.request.cancel() }
        }
    }

    func submit(frame: ARFrame, sessionID: UUID,
                completion: @escaping @Sendable (UUID, LiveCaptureReadiness) -> Void) {
        lock.lock()
        guard identifier == sessionID, !busy,
              interactionGate.allowsAnalysis(sessionID: sessionID, captureSuspended: isSuspended,
                                              now: ProcessInfo.processInfo.systemUptime),
              frame.timestamp.isFinite, frame.timestamp >= 0,
              frame.timestamp - lastSubmissionTime >= minimumInterval else {
            lock.unlock()
            return
        }
        busy = true
        let job = AnalysisJob(id: UUID(), sessionID: sessionID, readinessEpoch: readinessEpoch,
            timestamp: frame.timestamp, orientation: orientation,
            imageSize: .init(width: CVPixelBufferGetWidth(frame.capturedImage),
                             height: CVPixelBufferGetHeight(frame.capturedImage)))
        activeJobID = job.id
        lastSubmissionTime = frame.timestamp
        lock.unlock()

        // Retain one buffer until the small raster is rendered. No ARFrame,
        // original-size RGB copy or depth map enters the foreground request.
        let source = SourceBuffer(buffer: frame.capturedImage)
        queue.async { [self, source] in
            guard isCurrent(job) else { finish(nil, job: job, completion: completion); return }
            let image = autoreleasepool { render(source.buffer, job: job) }
            guard let image else {
                finish(.status(.analysisFailed, timestamp: job.timestamp), job: job, completion: completion)
                return
            }
            // The first block releases the ARKit buffer before this next serial
            // block starts Vision. Only the bounded image and source identity survive.
            enqueueAnalysis(image, job: job, completion: completion)
        }
    }

    private func enqueueAnalysis(_ image: CGImage, job: AnalysisJob,
                                 completion: @escaping @Sendable (UUID, LiveCaptureReadiness) -> Void) {
        // This scope cannot capture SourceBuffer or its outer render closure.
        let raster = PreviewRaster(image: image)
        queue.async { [self, raster] in analyze(raster.image, job: job, completion: completion) }
    }

    private func isCurrent(_ job: AnalysisJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeJobID == job.id && identifier == job.sessionID
            && interactionGate.allowsAnalysis(sessionID: job.sessionID, captureSuspended: isSuspended,
                                               now: ProcessInfo.processInfo.systemUptime)
            && readinessEpoch == job.readinessEpoch && orientation == job.orientation
    }

    private func render(_ buffer: CVPixelBuffer, job: AnalysisJob) -> CGImage? {
        guard let rawSize = LivePreviewRasterGeometry.analysisSize(for: job.imageSize,
            maximumDimension: LiveForegroundPreviewSelectionPolicy.maximumRasterDimension) else { return nil }
        let exif: Int32
        switch job.orientation {
        case .up: exif = 1
        case .right: exif = 6
        case .down: exif = 3
        case .left: exif = 8
        }
        let quarterTurn = job.orientation == .right || job.orientation == .left
        let uprightSize = quarterTurn ? PixelSize(width: rawSize.height, height: rawSize.width) : rawSize
        let scale = Double(rawSize.width) / Double(job.imageSize.width)
        let input = CIImage(cvPixelBuffer: buffer).oriented(forExifOrientation: exif)
            .transformed(by: .init(scaleX: scale, y: scale))
        return context.createCGImage(input,
            from: CGRect(x: input.extent.minX, y: input.extent.minY,
                         width: CGFloat(uprightSize.width), height: CGFloat(uprightSize.height)),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
    }

    private func analyze(_ image: CGImage, job: AnalysisJob,
                         completion: @escaping @Sendable (UUID, LiveCaptureReadiness) -> Void) {
        guard isCurrent(job) else { finish(nil, job: job, completion: completion); return }
        let request = VNGenerateForegroundInstanceMaskRequest()
        // Advisory outlines may take longer rather than competing with the
        // camera's interactive rendering. Frozen-photo measurement is separate.
        request.preferBackgroundProcessing = true
        lock.lock()
        let canRegister = activeJobID == job.id && identifier == job.sessionID
            && interactionGate.allowsAnalysis(sessionID: job.sessionID, captureSuspended: isSuspended,
                                               now: ProcessInfo.processInfo.systemUptime)
            && readinessEpoch == job.readinessEpoch && orientation == job.orientation
        if canRegister { activeRequest = request }
        lock.unlock()
        guard canRegister else { finish(nil, job: job, completion: completion); return }
        let result: LiveCaptureReadiness = autoreleasepool {
            do {
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                try handler.perform([request])
                guard isCurrent(job) else { return .status(.searching, timestamp: job.timestamp) }
                guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                    return .status(.searching, timestamp: job.timestamp)
                }
                // Never choose the largest object or ignore a second instance.
                guard observation.allInstances.count == 1, let instance = observation.allInstances.first else {
                    return .status(.multipleObjects, timestamp: job.timestamp)
                }
                let buffer = try observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: instance), from: handler)
                let upright = try Self.copyMask(buffer, expectedSize: .init(width: image.width, height: image.height))
                let raw = try GarmentMaskOrientation.originalMask(fromUpright: upright, orientation: job.orientation)
                return LiveForegroundPreviewSelectionPolicy.select(masks: [raw], imageSize: job.imageSize)
                    .readiness(timestamp: job.timestamp)
            } catch {
                // Cancelled/old jobs are discarded in finish. Current failures
                // have no outline and do not masquerade as recognized clothing.
                return .status(.analysisFailed, timestamp: job.timestamp)
            }
        }
        finish(result, job: job, completion: completion)
    }

    private func finish(_ result: LiveCaptureReadiness?, job: AnalysisJob,
                        completion: @escaping @Sendable (UUID, LiveCaptureReadiness) -> Void) {
        lock.lock()
        let canPublish = activeJobID == job.id && identifier == job.sessionID
            && interactionGate.allowsAnalysis(sessionID: job.sessionID, captureSuspended: isSuspended,
                                               now: ProcessInfo.processInfo.systemUptime)
            && readinessEpoch == job.readinessEpoch && orientation == job.orientation
        if activeJobID == job.id {
            activeRequest = nil
            activeJobID = nil
            busy = false
        }
        lock.unlock()
        guard canPublish, var result else { return }
        result.imageOrientation = job.orientation
        result.analysisEpoch = job.readinessEpoch
        completion(job.sessionID, result)
    }

    private static func copyMask(_ buffer: CVPixelBuffer, expectedSize: PixelSize) throws -> GarmentMask {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard expectedSize.isValid,
              max(width, height) <= LiveForegroundPreviewSelectionPolicy.maximumRasterDimension,
              width == expectedSize.width, height == expectedSize.height,
              format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw GarmentMaskAssociationError.invalidMask
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerPixel = format == kCVPixelFormatType_OneComponent32Float ? MemoryLayout<Float>.stride : 1
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), stride >= width * bytesPerPixel else {
            throw GarmentMaskAssociationError.invalidMask
        }
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let foreground: Bool
                if format == kCVPixelFormatType_OneComponent32Float {
                    let value = row.assumingMemoryBound(to: Float.self)[x]
                    foreground = value.isFinite && value >= 0.5
                } else {
                    foreground = row.assumingMemoryBound(to: UInt8.self)[x] >= 128
                }
                values[y * width + x] = foreground ? 1 : 0
            }
        }
        return .init(size: expectedSize, values: values)
    }

    private struct AnalysisJob: Sendable {
        let id: UUID
        let sessionID: UUID
        let readinessEpoch: UUID
        let timestamp: TimeInterval
        let orientation: ImageOrientation
        let imageSize: PixelSize
    }

    /// Read only on the render queue. Vision receives an independent small CGImage.
    private struct SourceBuffer: @unchecked Sendable { let buffer: CVPixelBuffer }
    /// Fully rendered, immutable pixels; the buffer pool is no longer involved.
    private struct PreviewRaster: @unchecked Sendable { let image: CGImage }
    /// VNRequest supports cancellation while another queue performs it. Retain
    /// that exact request only; never carry ARKit image buffers to this queue.
    private struct RequestCancellation: @unchecked Sendable {
        let request: VNGenerateForegroundInstanceMaskRequest
    }
}

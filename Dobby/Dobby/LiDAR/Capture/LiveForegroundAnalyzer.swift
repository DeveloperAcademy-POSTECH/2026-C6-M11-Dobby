import ARKit
import CoreImage
import Foundation
import ImageIO
import Vision

/// Owns a value copy of one RGB/depth frame. The CGImage is immutable and is
/// independent of ARKit's pixel-buffer pool before model work starts.
nonisolated struct LiveRecognitionCaptureTicket: @unchecked Sendable {
    let identity: PreparedCaptureHandoffIdentity
    let frame: MeasurementFrame
    let image: CGImage
    let landmarks: GarmentLandmarkSet
    let cameraTransform: simd_float4x4
    let tracking: CaptureTrackingStatus
    let trackingStable: Bool
}

/// Bounded semantic garment recognition and foreground segmentation of one RGB frame.
/// A foreground mask alone never publishes garment recognition or readiness.
nonisolated final class LiveForegroundAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dobby.lidar.live-foreground", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let recognizer: (any GarmentImageRecognizing)?
    private var orientation: ImageOrientation = .right
    private var identifier: UUID?
    private var readinessEpoch = UUID()
    private var busy = false
    private var isSuspended = false
    private var activeJobID: UUID?
    private var analysisTask: Task<Void, Never>?
    private var lastSubmissionTime: TimeInterval = -.infinity
    private var previousPose: simd_float4x4?
    private var previousPoseTime: TimeInterval?

    // Owned exclusively by the serial analysis queue. Only small evaluated
    // results cross to the main actor; ROI sampling and sorting stay here.
    private var evaluator = LiveReadinessEvaluator()
    private var evaluatorEpoch: UUID?

    private let minimumInterval: TimeInterval = 0.35

    init(recognizer: (any GarmentImageRecognizing)? = nil) {
        self.recognizer = recognizer
    }

    func setOrientation(_ value: ImageOrientation) {
        lock.lock()
        guard value != orientation else { lock.unlock(); return }
        orientation = value
        readinessEpoch = UUID()
        lastSubmissionTime = -.infinity
        let task = analysisTask
        lock.unlock()
        task?.cancel()
    }

    func isCurrent(_ readiness: LiveCaptureReadiness) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return identifier != nil && !isSuspended && readiness.analysisEpoch == readinessEpoch
    }

    func reset(sessionID: UUID?) {
        lock.lock()
        identifier = sessionID
        isSuspended = false
        readinessEpoch = UUID()
        lastSubmissionTime = -.infinity
        previousPose = nil
        previousPoseTime = nil
        let task = analysisTask
        // An old Vision request still owns its buffer until it finishes. Keep
        // busy true so a new session cannot start a second physical request.
        lock.unlock()
        task?.cancel()
    }

    /// Immediately invalidate in-flight evidence after motion or stale frames,
    /// without restarting the camera or starting a second analysis request.
    func invalidateReadiness() {
        lock.lock()
        readinessEpoch = UUID()
        let task = analysisTask
        lock.unlock()
        task?.cancel()
    }

    /// A shutter owns the next frozen inference. Keep the camera delivering
    /// frames, but stop preview requests from queueing ahead of that work.
    func suspend(sessionID: UUID) {
        lock.lock()
        guard identifier == sessionID else { lock.unlock(); return }
        isSuspended = true
        readinessEpoch = UUID()
        let task = analysisTask
        lock.unlock()
        task?.cancel()
    }

    func resume(sessionID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard identifier == sessionID, isSuspended else { return }
        isSuspended = false
        readinessEpoch = UUID()
        lastSubmissionTime = -.infinity
        previousPose = nil
        previousPoseTime = nil
    }

    func submit(
        frame: ARFrame,
        sessionID: UUID,
        completion: @escaping @Sendable (UUID, LiveCaptureReadiness, LiveRecognitionCaptureTicket?) -> Void
    ) {
        lock.lock()
        guard identifier == sessionID, !isSuspended, !busy,
              frame.timestamp - lastSubmissionTime >= minimumInterval else {
            lock.unlock()
            return
        }
        busy = true
        let jobID = UUID()
        activeJobID = jobID
        let epoch = readinessEpoch
        let imageOrientation = orientation
        lastSubmissionTime = frame.timestamp
        var trackingStable = false
        if case .normal = frame.camera.trackingState { trackingStable = true }
        let pose = frame.camera.transform
        if let previousPose, let previousPoseTime {
            let elapsed = frame.timestamp - previousPoseTime
            if elapsed > 0, elapsed <= 2 {
                // Initial UX thresholds, not claims of sensor precision. ARKit
                // can track normally while the user is still moving the camera.
                let translation = simd_distance(pose.columns.3, previousPose.columns.3)
                let a = Self.rotationMatrix(pose)
                let b = Self.rotationMatrix(previousPose)
                let rotation = simd_transpose(b) * a
                let trace = rotation.columns.0.x + rotation.columns.1.y + rotation.columns.2.z
                let cosine = min(Float(1), max(Float(-1), (trace - 1) / 2))
                let angle = acos(Double(cosine))
                trackingStable = trackingStable
                    && Double(translation) / elapsed < 0.10
                    && angle / elapsed < 12 * .pi / 180
            }
        }
        previousPose = pose
        previousPoseTime = frame.timestamp
        lock.unlock()

        // Retain at most one RGB buffer, never an ARFrame. Depth is a small,
        // stride-aware value copy from this exact frame, before returning to ARKit.
        let buffer = frame.capturedImage
        let job = AnalysisJob(
            id: jobID,
            sessionID: sessionID,
            readinessEpoch: epoch,
            timestamp: frame.timestamp,
            frameID: UUID(),
            capturedAt: Date(),
            image: buffer,
            ownedImage: nil,
            imageSize: PixelSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
            depth: frame.sceneDepth.flatMap(Self.copyDepth),
            intrinsics: Self.copyIntrinsics(frame),
            cameraTransform: pose,
            tracking: Self.trackingStatus(for: frame.camera.trackingState),
            trackingStable: trackingStable,
            orientation: imageOrientation
        )
        queue.async { [self] in
            guard isCurrent(job) else {
                finish(emptyEvidence(for: job), job: job, completion: completion)
                return
            }
            // A bounded raw RGB copy retains the complete field of view and
            // exact aspect ratio. Normalized points/masks still match this
            // frame's full-size RGB and copied depth; capture keeps original RGB.
            let rendered: (original: CGImage, analysis: CGImage)? = autoreleasepool {
                guard let buffer = job.image else { return nil }
                let raw = CIImage(cvPixelBuffer: buffer)
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                guard let original = context.createCGImage(raw,
                    from: CGRect(x: 0, y: 0, width: job.imageSize.width, height: job.imageSize.height),
                    format: .RGBA8, colorSpace: colorSpace, deferred: false) else { return nil }
                guard let size = LivePreviewRasterGeometry.analysisSize(for: job.imageSize) else { return nil }
                let scale = Double(size.width) / Double(job.imageSize.width)
                let resized = CIImage(cgImage: original).transformed(by: .init(scaleX: scale, y: scale))
                guard let analysis = context.createCGImage(resized,
                    from: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                    format: .RGBA8, colorSpace: colorSpace, deferred: false) else { return nil }
                return (original, analysis)
            }
            guard let rendered, let recognizer else {
                var evidence = self.emptyEvidence(for: job)
                evidence.analysisFailed = rendered == nil
                self.finish(evidence, job: job, completion: completion)
                return
            }
            let task = Task { [job = job.owning(rendered.original)] in
                let recognition: Result<GarmentForegroundRecognition, Error>
                do { recognition = .success(try await recognizer.recognizeForeground(rendered.analysis, orientation: job.orientation)) }
                catch { recognition = .failure(error) }
                self.queue.async {
                    guard self.isCurrent(job) else {
                        self.finish(self.emptyEvidence(for: job), job: job, completion: completion)
                        return
                    }
                    let evidence = autoreleasepool { self.analyze(job, recognition: recognition) }
                    self.finish(evidence, job: job, recognition: try? recognition.get(), completion: completion)
                }
            }
            self.lock.lock()
            let canRegister = self.activeJobID == job.id && self.identifier == job.sessionID
                && self.readinessEpoch == job.readinessEpoch && !self.isSuspended
            if canRegister { self.analysisTask = task }
            self.lock.unlock()
            if !canRegister { task.cancel() }
        }
    }

    private func isCurrent(_ job: AnalysisJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return identifier == job.sessionID && !isSuspended && readinessEpoch == job.readinessEpoch
    }

    /// Called only on the serial analysis queue. The epoch protects camera
    /// restart, motion invalidation and orientation changes while ML was running.
    private func finish(_ evidence: LiveCaptureEvidence, job: AnalysisJob,
                        recognition: GarmentForegroundRecognition? = nil,
                        completion: @escaping @Sendable (UUID, LiveCaptureReadiness, LiveRecognitionCaptureTicket?) -> Void) {
        lock.lock()
        let canEvaluate = identifier == job.sessionID && !isSuspended && readinessEpoch == job.readinessEpoch
        if activeJobID == job.id {
            analysisTask = nil
            if !canEvaluate { busy = false; activeJobID = nil }
        }
        lock.unlock()
        guard canEvaluate else { return }
        if evaluatorEpoch != job.readinessEpoch {
            evaluator.reset()
            evaluatorEpoch = job.readinessEpoch
        }
        var result = evaluator.evaluate(evidence)
        result.imageOrientation = job.orientation
        result.analysisEpoch = job.readinessEpoch
        let ticket = result.isReady ? captureTicket(job: job, recognition: recognition) : nil
        lock.lock()
        busy = false
        activeJobID = nil
        let canPublish = identifier == job.sessionID && !isSuspended && readinessEpoch == job.readinessEpoch
        lock.unlock()
        if canPublish { completion(job.sessionID, result, ticket) }
    }

    private func captureTicket(job: AnalysisJob, recognition: GarmentForegroundRecognition?) -> LiveRecognitionCaptureTicket? {
        guard let recognition, let image = job.ownedImage, let depth = job.depth,
              let intrinsics = job.intrinsics, let kind = recognition.recognition.garmentKind,
              recognition.recognition.modelVersion == kind.modelVersion,
              intrinsics.referenceSize == job.imageSize,
              image.width == job.imageSize.width, image.height == job.imageSize.height,
              depth.size.isValid, depth.values.count == depth.size.width * depth.size.height,
              depth.size.width * job.imageSize.height == depth.size.height * job.imageSize.width,
              job.trackingStable, job.tracking == .normal else { return nil }
        let frame = MeasurementFrame(sessionID: job.sessionID, frameID: job.frameID,
            timestamp: job.timestamp, capturedAt: job.capturedAt, imageSize: job.imageSize,
            intrinsics: intrinsics, depth: depth, source: .sceneDepth, orientation: job.orientation)
        let landmarks = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .model, modelVersion: recognition.recognition.modelVersion,
            points: recognition.selection.validatedPoints(recognition.recognition.points),
            mask: recognition.selection.mask, garmentKind: kind)
        let identity = PreparedCaptureHandoffIdentity(sessionID: job.sessionID, frameID: job.frameID,
            analysisEpoch: job.readinessEpoch, timestamp: job.timestamp, orientation: job.orientation,
            garmentKind: kind, modelVersion: recognition.recognition.modelVersion)
        return .init(identity: identity, frame: frame, image: image, landmarks: landmarks,
                     cameraTransform: job.cameraTransform, tracking: job.tracking, trackingStable: job.trackingStable)
    }

    private static func copyIntrinsics(_ frame: ARFrame) -> CameraIntrinsics? {
        let matrix = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        let result = CameraIntrinsics(fx: Double(matrix.columns.0.x), fy: Double(matrix.columns.1.y),
            cx: Double(matrix.columns.2.x), cy: Double(matrix.columns.2.y),
            referenceSize: .init(width: Int(size.width), height: Int(size.height)))
        guard result.referenceSize.isValid,
              [result.fx, result.fy, result.cx, result.cy].allSatisfy(\.isFinite),
              result.fx > 0, result.fy > 0 else { return nil }
        return result
    }

    private static func trackingStatus(for state: ARCamera.TrackingState) -> CaptureTrackingStatus {
        switch state {
        case .normal: .normal
        case .limited(.excessiveMotion): .excessiveMotion
        case .limited(.insufficientFeatures): .insufficientFeatures
        case .limited: .limited
        case .notAvailable: .unavailable
        }
    }

    private static func rotationMatrix(_ pose: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
            SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
            SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        ))
    }

    private func emptyEvidence(for job: AnalysisJob) -> LiveCaptureEvidence {
        .init(timestamp: job.timestamp, candidateCount: 0, bounds: nil, mask: nil,
              imageSize: job.imageSize, depth: job.depth, trackingStable: job.trackingStable)
    }

    private func analyze(_ job: AnalysisJob,
                         recognition: Result<GarmentForegroundRecognition, Error>) -> LiveCaptureEvidence {
        var evidence = emptyEvidence(for: job)
        do {
            let result = try recognition.get()
            let prediction = result.recognition
            guard prediction.detectionConfidence.isFinite,
                  (0.25...1).contains(prediction.detectionConfidence),
                  !prediction.modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return evidence
            }
            let selection = result.selection
            evidence.candidateCount = 1
            evidence.mask = selection.mask
            evidence.bounds = selection.bounds
            evidence.recognitionModelVersion = prediction.modelVersion
            evidence.garmentKind = prediction.garmentKind
        } catch BottomLandmarkError.noDetection {
            // The generic foreground may be a hand, bag or furniture. Do not
            // draw a garment silhouette when the model found no garment.
        } catch BottomLandmarkError.multipleGarments {
            evidence.candidateCount = 2
        } catch GarmentModelError.noDetection {
        } catch GarmentModelError.multipleGarments {
            evidence.candidateCount = 2
        } catch let error as AutoGarmentRecognitionError {
            evidence.unsupportedGarment = error == .unsupported
            evidence.analysisFailed = !error.isRecognitionRejection
        } catch GarmentMaskAssociationError.multipleForegrounds {
            evidence.candidateCount = 2
        } catch GarmentMaskAssociationError.noForeground {
        } catch GarmentMaskAssociationError.unmatchedGarment {
        } catch {
            evidence.analysisFailed = true
        }
        return evidence
    }

    /// Also used for a bounded shutter-time eligibility check. These copied
    /// samples never replace the depth owned by the accepted live ticket.
    static func copyDepth(_ source: ARDepthData) -> DepthMap? {
        let buffer = source.depthMap
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= 2048, height <= 2048,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width * MemoryLayout<Float>.stride else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                let value = row[x]
                if value.isFinite, value > 0 { values[y * width + x] = value }
            }
        }
        let size = PixelSize(width: width, height: height)
        return DepthMap(size: size, values: values, confidence: copyConfidence(source.confidenceMap, size: size))
    }

    private static func copyConfidence(_ buffer: CVPixelBuffer?, size: PixelSize) -> [UInt8]? {
        guard let buffer, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(buffer) == size.width, CVPixelBufferGetHeight(buffer) == size.height,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= size.width else { return nil }
        var values = [UInt8](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<size.width {
                guard row[x] <= 2 else { return nil }
                values[y * size.width + x] = row[x]
            }
        }
        return values
    }
}

private nonisolated struct AnalysisJob: @unchecked Sendable {
    var id: UUID
    var sessionID: UUID
    var readinessEpoch: UUID
    var timestamp: TimeInterval
    var frameID: UUID
    var capturedAt: Date
    /// Release the ARKit pool buffer after rendering the owned preview raster.
    var image: CVPixelBuffer?
    var ownedImage: CGImage?
    var imageSize: PixelSize
    var depth: DepthMap?
    var intrinsics: CameraIntrinsics?
    var cameraTransform: simd_float4x4
    var tracking: CaptureTrackingStatus
    var trackingStable: Bool
    var orientation: ImageOrientation

    func owning(_ image: CGImage) -> Self {
        var copy = self
        copy.image = nil
        copy.ownedImage = image
        return copy
    }
}

import ARKit
import CoreImage
import Foundation
import ImageIO
import Vision

/// Bounded semantic garment recognition and foreground segmentation of one RGB frame.
/// A foreground mask alone never publishes garment recognition or readiness.
nonisolated final class LiveForegroundAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dobby.lidar.live-foreground", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let foreground = GarmentForegroundMaskAnalyzer()
    private let recognizer: (any GarmentImageRecognizing)?
    private var orientation: ImageOrientation = .right
    private var identifier: UUID?
    private var readinessEpoch = UUID()
    private var busy = false
    private var lastSubmissionTime: TimeInterval = -.infinity
    private var previousPose: simd_float4x4?
    private var previousPoseTime: TimeInterval?

    // Owned exclusively by the serial analysis queue. Only small evaluated
    // results cross to the main actor; ROI sampling and sorting stay here.
    private var evaluator = LiveReadinessEvaluator()
    private var evaluatorEpoch: UUID?

    private let minimumInterval: TimeInterval = 0.6

    init(recognizer: (any GarmentImageRecognizing)? = nil) {
        self.recognizer = recognizer
    }

    func setOrientation(_ value: ImageOrientation) {
        lock.lock(); defer { lock.unlock() }
        guard value != orientation else { return }
        orientation = value
        readinessEpoch = UUID()
        lastSubmissionTime = -.infinity
    }

    func isCurrent(_ readiness: LiveCaptureReadiness) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return identifier != nil && readiness.analysisEpoch == readinessEpoch
    }

    func reset(sessionID: UUID?) {
        lock.lock(); defer { lock.unlock() }
        identifier = sessionID
        readinessEpoch = UUID()
        lastSubmissionTime = -.infinity
        previousPose = nil
        previousPoseTime = nil
        // An old Vision request still owns its buffer until it finishes. Keep
        // busy true so a new session cannot start a second physical request.
    }

    /// Immediately invalidate in-flight evidence after motion or stale frames,
    /// without restarting the camera or starting a second analysis request.
    func invalidateReadiness() {
        lock.lock(); defer { lock.unlock() }
        readinessEpoch = UUID()
    }

    func submit(
        frame: ARFrame,
        sessionID: UUID,
        completion: @escaping @Sendable (UUID, LiveCaptureReadiness) -> Void
    ) {
        lock.lock()
        guard identifier == sessionID, !busy,
              frame.timestamp - lastSubmissionTime >= minimumInterval else {
            lock.unlock()
            return
        }
        busy = true
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
            sessionID: sessionID,
            readinessEpoch: epoch,
            timestamp: frame.timestamp,
            image: buffer,
            imageSize: PixelSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
            depth: frame.sceneDepth.flatMap(Self.copyDepth),
            trackingStable: trackingStable,
            orientation: imageOrientation
        )
        queue.async { [self] in
            guard isCurrent(job) else {
                finish(emptyEvidence(for: job), job: job, completion: completion)
                return
            }
            // Render an owned raw RGB copy before crossing an async model call.
            // Only this one job is in flight, including its segmentation step.
            let image: CGImage?
            image = autoreleasepool {
                let raw = CIImage(cvPixelBuffer: job.image)
                return context.createCGImage(raw,
                    from: CGRect(x: 0, y: 0, width: job.imageSize.width, height: job.imageSize.height),
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
            }
            guard let image, let recognizer else {
                var evidence = self.emptyEvidence(for: job)
                evidence.analysisFailed = image == nil
                self.finish(evidence, job: job, completion: completion)
                return
            }
            Task {
                let recognition: Result<GarmentImageRecognition, Error>
                do { recognition = .success(try await recognizer.recognizeImage(image, orientation: job.orientation)) }
                catch { recognition = .failure(error) }
                self.queue.async {
                    guard self.isCurrent(job) else {
                        self.finish(self.emptyEvidence(for: job), job: job, completion: completion)
                        return
                    }
                    let evidence = autoreleasepool { self.analyze(job, image: image, recognition: recognition) }
                    self.finish(evidence, job: job, completion: completion)
                }
            }
        }
    }

    private func isCurrent(_ job: AnalysisJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return identifier == job.sessionID && readinessEpoch == job.readinessEpoch
    }

    /// Called only on the serial analysis queue. The epoch protects camera
    /// restart, motion invalidation and orientation changes while ML was running.
    private func finish(_ evidence: LiveCaptureEvidence, job: AnalysisJob,
                        completion: @escaping @Sendable (UUID, LiveCaptureReadiness) -> Void) {
        lock.lock()
        let canEvaluate = identifier == job.sessionID && readinessEpoch == job.readinessEpoch
        if !canEvaluate { busy = false }
        lock.unlock()
        guard canEvaluate else { return }
        if evaluatorEpoch != job.readinessEpoch {
            evaluator.reset()
            evaluatorEpoch = job.readinessEpoch
        }
        var result = evaluator.evaluate(evidence)
        result.imageOrientation = job.orientation
        result.analysisEpoch = job.readinessEpoch
        lock.lock()
        busy = false
        let canPublish = identifier == job.sessionID && readinessEpoch == job.readinessEpoch
        lock.unlock()
        if canPublish { completion(job.sessionID, result) }
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

    private func analyze(_ job: AnalysisJob, image: CGImage,
                         recognition: Result<GarmentImageRecognition, Error>) -> LiveCaptureEvidence {
        var evidence = emptyEvidence(for: job)
        do {
            let prediction = try recognition.get()
            guard prediction.detectionConfidence.isFinite,
                  (0.25...1).contains(prediction.detectionConfidence),
                  !prediction.modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return evidence
            }
            let selection = try foreground.analyze(image, points: prediction.points)
            evidence.candidateCount = 1
            evidence.mask = selection.mask
            evidence.bounds = selection.bounds
            evidence.recognitionModelVersion = prediction.modelVersion
        } catch BottomLandmarkError.noDetection {
            // The generic foreground may be a hand, bag or furniture. Do not
            // draw a garment silhouette when the model found no garment.
        } catch BottomLandmarkError.multipleGarments {
            evidence.candidateCount = 2
        } catch GarmentMaskAssociationError.multipleForegrounds {
            evidence.candidateCount = 2
        } catch GarmentMaskAssociationError.noForeground {
        } catch GarmentMaskAssociationError.unmatchedGarment {
        } catch {
            evidence.analysisFailed = true
        }
        return evidence
    }

    private static func copyDepth(_ source: ARDepthData) -> DepthMap? {
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
    var sessionID: UUID
    var readinessEpoch: UUID
    var timestamp: TimeInterval
    /// ARKit owns the pool; this bounded retained buffer is read-only while analyzed.
    var image: CVPixelBuffer
    var imageSize: PixelSize
    var depth: DepthMap?
    var trackingStable: Bool
    var orientation: ImageOrientation
}

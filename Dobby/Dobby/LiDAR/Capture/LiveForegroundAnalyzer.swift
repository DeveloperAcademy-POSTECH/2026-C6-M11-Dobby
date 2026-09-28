import ARKit
import CoreImage
import Foundation
import ImageIO
import Vision

/// Generic foreground segmentation, deliberately separate from the future garment ML adapter.
/// Analysis is sampled, never queued per frame, and cannot delay a shutter request with Vision work.
nonisolated final class LiveForegroundAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dobby.lidar.live-foreground", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
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
            trackingStable: trackingStable
        )
        queue.async { [self] in
            let evidence = autoreleasepool { analyze(job) }
            lock.lock()
            let canEvaluate = identifier == job.sessionID && readinessEpoch == job.readinessEpoch
            if !canEvaluate { busy = false }
            lock.unlock()
            guard canEvaluate else { return }

            if evaluatorEpoch != job.readinessEpoch {
                evaluator.reset()
                evaluatorEpoch = job.readinessEpoch
            }
            let result = evaluator.evaluate(evidence)

            lock.lock()
            busy = false
            let canPublish = identifier == job.sessionID && readinessEpoch == job.readinessEpoch
            lock.unlock()
            if canPublish { completion(job.sessionID, result) }
        }
    }

    private static func rotationMatrix(_ pose: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
            SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
            SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        ))
    }

    private func analyze(_ job: AnalysisJob) -> LiveCaptureEvidence {
        var evidence = LiveCaptureEvidence(
            timestamp: job.timestamp,
            candidateCount: 0,
            bounds: nil,
            mask: nil,
            imageSize: job.imageSize,
            depth: job.depth,
            trackingStable: job.trackingStable
        )
        do {
            let size = try Self.analysisSize(for: job.imageSize)
            let scale = Double(size.width) / Double(job.imageSize.width)
            let input = CIImage(cvPixelBuffer: job.image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let image = context.createCGImage(input,
                from: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
                throw AnalysisError.invalidImage
            }
            // Sensor-raster coordinates remain unrotated. Display orientation is
            // applied only when the camera UI draws the resulting bounds.
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                return evidence
            }

            let histogram = Self.instanceHistogram(observation.instanceMask)
            let ranked = observation.allInstances.sorted {
                let left = histogram?[$0] ?? 0
                let right = histogram?[$1] ?? 0
                return left == right ? $0 < $1 : left > right
            }
            // Bound work in cluttered scenes. A full-image mask is used for
            // geometry; instanceMask's low-resolution square is never treated
            // as if it were already aligned to the rectangular camera image.
            var largest: MaskSummary?
            var meaningfulCount = 0
            for instance in ranked.prefix(4) {
                let scaledMask = try observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: instance), from: handler)
                let summary = try Self.summarize(scaledMask, expectedSize: size)
                guard summary.foregroundCount >= Int(ceil(Double(size.width * size.height) * 0.02)) else {
                    continue
                }
                meaningfulCount += 1
                if summary.foregroundCount > (largest?.foregroundCount ?? 0) { largest = summary }
            }
            if ranked.count > 4 {
                let lowResolutionArea = CVPixelBufferGetWidth(observation.instanceMask)
                    * CVPixelBufferGetHeight(observation.instanceMask)
                let unexaminedCandidate = ranked.dropFirst(4).contains {
                    // A conservative clutter check; do not give a green signal
                    // when a substantial instance was omitted by the work limit.
                    guard let histogram else { return true }
                    return Double(histogram[$0] ?? 0) >= Double(lowResolutionArea) * 0.01
                }
                if unexaminedCandidate { meaningfulCount = max(2, meaningfulCount + 1) }
            }
            evidence.candidateCount = meaningfulCount
            evidence.mask = largest?.mask
            evidence.bounds = largest?.bounds
        } catch {
            evidence.analysisFailed = true
        }
        return evidence
    }

    private static func analysisSize(for original: PixelSize) throws -> PixelSize {
        guard original.isValid else { throw AnalysisError.invalidImage }
        // Preserve the exact full-frame aspect ratio, including the mask's
        // relation to the original image and depth, without letterboxing.
        var a = original.width
        var b = original.height
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        let unitWidth = original.width / a
        let unitHeight = original.height / a
        let multiplier = min(a, 512 / max(unitWidth, unitHeight))
        guard multiplier > 0 else { throw AnalysisError.invalidImage }
        return PixelSize(width: unitWidth * multiplier, height: unitHeight * multiplier)
    }

    private static func instanceHistogram(_ buffer: CVPixelBuffer) -> [Int: Int]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width else { return nil }
        var histogram: [Int: Int] = [:]
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where row[x] != 0 { histogram[Int(row[x]), default: 0] += 1 }
        }
        return histogram
    }

    private static func summarize(_ buffer: CVPixelBuffer, expectedSize: PixelSize) throws -> MaskSummary {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard width == expectedSize.width, height == expectedSize.height,
              format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw AnalysisError.invalidMask
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AnalysisError.invalidMask }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytesPerPixel = format == kCVPixelFormatType_OneComponent32Float ? MemoryLayout<Float>.stride : 1
        guard stride >= width * bytesPerPixel else { throw AnalysisError.invalidMask }
        var values = [UInt8](repeating: 0, count: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let included: Bool
                if format == kCVPixelFormatType_OneComponent32Float {
                    let value = row.assumingMemoryBound(to: Float.self)[x]
                    included = value.isFinite && value >= 0.5
                } else {
                    included = row.assumingMemoryBound(to: UInt8.self)[x] >= 128
                }
                if included {
                    values[y * width + x] = 1
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                    count += 1
                }
            }
        }
        let bounds: NormalizedRect? = count > 0 ? NormalizedRect(
            x: Double(minX) / Double(width), y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height)
        ) : nil
        return MaskSummary(mask: GarmentMask(size: expectedSize, values: values), bounds: bounds, foregroundCount: count)
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
}

private nonisolated struct MaskSummary {
    var mask: GarmentMask
    var bounds: NormalizedRect?
    var foregroundCount: Int
}

private nonisolated enum AnalysisError: Error {
    case invalidImage, invalidMask
}

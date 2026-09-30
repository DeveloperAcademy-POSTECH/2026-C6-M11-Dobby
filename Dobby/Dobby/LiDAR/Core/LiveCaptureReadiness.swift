import Foundation

/// Normalized bounds in the original, unrotated RGB image; origin is top left.
nonisolated struct NormalizedRect: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000_001 && y + height <= 1.000_001
    }

    fileprivate var area: Double { width * height }
    fileprivate var centerX: Double { x + width / 2 }
    fileprivate var centerY: Double { y + height / 2 }

    fileprivate func intersectionOverUnion(with other: Self) -> Double {
        let intersection = max(0, min(x + width, other.x + other.width) - max(x, other.x))
            * max(0, min(y + height, other.y + other.height) - max(y, other.y))
        return intersection / max(Double.leastNonzeroMagnitude, area + other.area - intersection)
    }
}

/// The mask and depth must belong to this exact RGB frame and cover its complete field of view.
/// A model version is supplied only after semantic landmarks have been matched
/// to the single foreground mask from this same image.
nonisolated struct LiveCaptureEvidence: Sendable {
    var timestamp: TimeInterval
    var candidateCount: Int
    var bounds: NormalizedRect?
    var mask: GarmentMask?
    var imageSize: PixelSize
    var depth: DepthMap?
    var trackingStable: Bool
    var analysisFailed: Bool = false
    var recognitionModelVersion: String? = nil
}

nonisolated enum LiveReadinessState: String, Codable, Sendable {
    case searching, analyzing, multipleObjects, clipped, tooSmall
    case noDepth, lowDepth, unstable, steadying, ready, analysisFailed
}

/// A matched garment silhouette plus advisory capture quality, not a guarantee
/// of landmark position or centimetre accuracy.
/// Coverage denominators are foreground depth pixels, never the full image or bounding box.
nonisolated struct LiveCaptureReadiness: Codable, Sendable, Equatable {
    var state: LiveReadinessState
    var timestamp: TimeInterval
    var bounds: NormalizedRect? = nil
    var depthCoverage: Double? = nil
    var highConfidenceCoverage: Double? = nil
    /// Boundary pixels with valid, medium-or-high confidence depth / all boundary pixels.
    var boundaryCoverage: Double? = nil
    var medianDepthMeters: Double? = nil
    /// Binary silhouette in full, unrotated RGB coordinates. Never a bounding box.
    var silhouette: GarmentMask? = nil
    var recognitionModelVersion: String? = nil
    var imageOrientation: ImageOrientation? = nil
    /// Runtime identity rejects completions queued before an analysis reset.
    var analysisEpoch: UUID? = nil

    var garmentRecognized: Bool {
        silhouette != nil && !(recognitionModelVersion?.isEmpty ?? true)
    }

    var isReady: Bool { state == .ready }
}

nonisolated struct LiveReadinessConfiguration: Sendable {
    var minimumForegroundArea = 0.06
    var minimumImageEdgeMargin = 0.02
    var minimumForegroundDepthSamples = 30
    var minimumDepthMeters = 0.15
    var maximumDepthMeters = 3.0
    var minimumDepthCoverage = 0.85
    var minimumHighConfidenceCoverage = 0.60
    var minimumBoundaryCoverage = 0.70
    var minimumConsecutiveObservations = 2
    var minimumStableDuration: TimeInterval = 0.35
    var maximumObservationGap: TimeInterval = 2.0
    var minimumBoundsIntersectionOverUnion = 0.80
    var maximumCenterMovement = 0.025
    var maximumMedianDepthChangeMeters = 0.04

    fileprivate var isValid: Bool {
        let fractions = [minimumForegroundArea, minimumImageEdgeMargin, minimumDepthCoverage,
                         minimumHighConfidenceCoverage, minimumBoundaryCoverage,
                         minimumBoundsIntersectionOverUnion, maximumCenterMovement]
        return fractions.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && minimumForegroundArea > 0 && minimumImageEdgeMargin < 0.5
            && minimumForegroundDepthSamples > 0 && minimumForegroundDepthSamples <= 1_048_576
            && minimumDepthMeters.isFinite && minimumDepthMeters > 0
            && maximumDepthMeters.isFinite && maximumDepthMeters > minimumDepthMeters
            && minimumConsecutiveObservations >= 2 && minimumConsecutiveObservations <= 1_000
            && minimumStableDuration.isFinite && minimumStableDuration >= 0
            && maximumObservationGap.isFinite && maximumObservationGap > minimumStableDuration
            && maximumMedianDepthChangeMeters.isFinite && maximumMedianDepthChangeMeters >= 0
    }
}

/// Run on the capture analysis worker. Each fresh frame advances one temporal observation.
/// A single bad, missing, reordered, or moving observation immediately removes readiness.
nonisolated struct LiveReadinessEvaluator: Sendable {
    var configuration: LiveReadinessConfiguration
    private var lastTimestamp: TimeInterval?
    private var previousBounds: NormalizedRect?
    private var previousMedianDepth: Double?
    private var streakStart: TimeInterval?
    private var streakCount = 0

    init(configuration: LiveReadinessConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func reset() {
        lastTimestamp = nil
        resetStreak()
    }

    mutating func evaluate(_ evidence: LiveCaptureEvidence) -> LiveCaptureReadiness {
        var result = LiveCaptureReadiness(
            state: .analyzing, timestamp: evidence.timestamp.isFinite ? evidence.timestamp : 0,
            bounds: evidence.bounds
        )
        guard configuration.isValid, evidence.timestamp.isFinite, evidence.timestamp >= 0,
              evidence.imageSize.isValid, evidence.candidateCount >= 0 else {
            return reject(.analysisFailed, result)
        }
        if let lastTimestamp {
            guard evidence.timestamp > lastTimestamp else { return reject(.analyzing, result) }
            if evidence.timestamp - lastTimestamp > configuration.maximumObservationGap { resetStreak() }
        }
        lastTimestamp = evidence.timestamp
        guard !evidence.analysisFailed else { return reject(.analysisFailed, result) }
        guard evidence.trackingStable else { return reject(.unstable, result) }
        guard evidence.candidateCount > 0 else { return reject(.searching, result) }
        guard evidence.candidateCount == 1 else { return reject(.multipleObjects, result) }
        guard let modelVersion = evidence.recognitionModelVersion,
              !modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reject(.searching, result)
        }
        guard let bounds = evidence.bounds, bounds.isValid,
              let mask = evidence.mask, validMask(mask, imageSize: evidence.imageSize) else {
            return reject(.analysisFailed, result)
        }

        var foregroundCount = 0
        var minX = mask.size.width, minY = mask.size.height, maxX = -1, maxY = -1
        for index in mask.values.indices where mask.values[index] == 1 {
            foregroundCount += 1
            let x = index % mask.size.width, y = index / mask.size.width
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
        guard foregroundCount > 0 else { return reject(.searching, result) }
        let maskBounds = NormalizedRect(
            x: Double(minX) / Double(mask.size.width), y: Double(minY) / Double(mask.size.height),
            width: Double(maxX - minX + 1) / Double(mask.size.width),
            height: Double(maxY - minY + 1) / Double(mask.size.height)
        )
        // Allow normal pixel quantization, but never silently use a mask from another ROI.
        guard bounds.intersectionOverUnion(with: maskBounds) >= 0.70 else {
            return reject(.analysisFailed, result)
        }
        result.silhouette = mask
        result.recognitionModelVersion = modelVersion
        let margin = configuration.minimumImageEdgeMargin
        guard min(bounds.x, maskBounds.x) >= margin,
              min(bounds.y, maskBounds.y) >= margin,
              max(bounds.x + bounds.width, maskBounds.x + maskBounds.width) <= 1 - margin,
              max(bounds.y + bounds.height, maskBounds.y + maskBounds.height) <= 1 - margin else {
            return reject(.clipped, result)
        }
        guard Double(foregroundCount) / Double(mask.values.count) >= configuration.minimumForegroundArea else {
            return reject(.tooSmall, result)
        }
        guard let depth = evidence.depth else { return reject(.noDepth, result) }
        guard validDepth(depth, imageSize: evidence.imageSize) else { return reject(.noDepth, result) }

        let width = depth.size.width, height = depth.size.height
        var foreground = [Bool](repeating: false, count: depth.values.count)
        for y in 0..<height {
            let maskY = min(mask.size.height - 1, Int((Double(y) + 0.5) / Double(height) * Double(mask.size.height)))
            for x in 0..<width {
                let maskX = min(mask.size.width - 1, Int((Double(x) + 0.5) / Double(width) * Double(mask.size.width)))
                foreground[y * width + x] = mask.values[maskY * mask.size.width + maskX] == 1
            }
        }
        var roiCount = 0, validCount = 0, highCount = 0, boundaryCount = 0, validBoundaryCount = 0
        var validDepths = [Double]()
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard foreground[index] else { continue }
                roiCount += 1
                let value = Double(depth.values[index])
                let isValid = value.isFinite && value >= configuration.minimumDepthMeters
                    && value <= configuration.maximumDepthMeters
                let confidence = depth.confidence?[index]
                let isBoundary = x == 0 || y == 0 || x == width - 1 || y == height - 1
                    || !foreground[index - 1] || !foreground[index + 1]
                    || !foreground[index - width] || !foreground[index + width]
                if isBoundary {
                    boundaryCount += 1
                    if isValid, let confidence, confidence >= 1 { validBoundaryCount += 1 }
                }
                if isValid {
                    validCount += 1
                    validDepths.append(value)
                    if confidence == 2 { highCount += 1 }
                }
            }
        }
        guard roiCount > 0 else { return reject(.lowDepth, result) }
        result.depthCoverage = Double(validCount) / Double(roiCount)
        if depth.confidence != nil {
            result.highConfidenceCoverage = Double(highCount) / Double(roiCount)
            if boundaryCount > 0 { result.boundaryCoverage = Double(validBoundaryCount) / Double(boundaryCount) }
        }
        if !validDepths.isEmpty {
            validDepths.sort()
            let middle = validDepths.count / 2
            result.medianDepthMeters = validDepths.count.isMultiple(of: 2)
                ? (validDepths[middle - 1] + validDepths[middle]) / 2 : validDepths[middle]
        }
        guard roiCount >= configuration.minimumForegroundDepthSamples,
              let coverage = result.depthCoverage, coverage >= configuration.minimumDepthCoverage,
              let highCoverage = result.highConfidenceCoverage, highCoverage >= configuration.minimumHighConfidenceCoverage,
              let boundaryCoverage = result.boundaryCoverage, boundaryCoverage >= configuration.minimumBoundaryCoverage,
              let medianDepth = result.medianDepthMeters else { return reject(.lowDepth, result) }

        let consistent: Bool
        if let previousBounds, let previousMedianDepth {
            consistent = bounds.intersectionOverUnion(with: previousBounds) >= configuration.minimumBoundsIntersectionOverUnion
                && hypot(bounds.centerX - previousBounds.centerX, bounds.centerY - previousBounds.centerY) <= configuration.maximumCenterMovement
                && abs(medianDepth - previousMedianDepth) <= configuration.maximumMedianDepthChangeMeters
        } else { consistent = false }
        if consistent {
            streakCount += 1
        } else {
            streakCount = 1
            streakStart = evidence.timestamp
        }
        previousBounds = bounds
        previousMedianDepth = medianDepth
        result.state = streakCount >= configuration.minimumConsecutiveObservations
            && evidence.timestamp - (streakStart ?? evidence.timestamp) >= configuration.minimumStableDuration
            ? .ready : .steadying
        return result
    }

    private mutating func reject(_ state: LiveReadinessState, _ result: LiveCaptureReadiness) -> LiveCaptureReadiness {
        resetStreak()
        var result = result
        result.state = state
        return result
    }

    private mutating func resetStreak() {
        previousBounds = nil
        previousMedianDepth = nil
        streakStart = nil
        streakCount = 0
    }

    private func sameAspect(_ first: PixelSize, _ second: PixelSize) -> Bool {
        first.width * second.height == first.height * second.width
    }

    private func validMask(_ mask: GarmentMask, imageSize: PixelSize) -> Bool {
        mask.size.isValid && sameAspect(mask.size, imageSize)
            && mask.values.count <= 4_194_304 && mask.values.count == mask.size.width * mask.size.height
            && mask.values.allSatisfy { $0 <= 1 }
    }

    private func validDepth(_ depth: DepthMap, imageSize: PixelSize) -> Bool {
        guard depth.size.isValid, sameAspect(depth.size, imageSize),
              depth.values.count <= 1_048_576,
              depth.values.count == depth.size.width * depth.size.height else { return false }
        if let confidence = depth.confidence {
            return confidence.count == depth.values.count && confidence.allSatisfy { $0 <= 2 }
        }
        return true
    }
}

import Foundation

/// Orthogonal garment-plane support, not local depth-axis spread or a physical
/// tape-measure accuracy claim. Optional on PointQuality for old archive decoding.
nonisolated struct GarmentPlaneQuality: Codable, Sendable, Equatable {
    var interiorCount: Int
    var candidateCount: Int
    var inlierCount: Int
    var orthogonalRMSMeters: Double
    var minorVarianceSquareMeters: Double
    var majorVarianceSquareMeters: Double
    var horizontalCoverage: Double
    var verticalCoverage: Double
    var viewingRayCosine: Double
}

/// Camera optical coordinates, +x right, +y down, +z forward, in metres.
nonisolated struct GarmentPlane: Sendable {
    var normal: Point3D
    var offset: Double
    var quality: GarmentPlaneQuality
}

/// Frozen raw RGB/depth geometry. Display/device/garment rotations never enter
/// unprojection. Only the lateral-clipping policy uses the composed upright angle.
nonisolated enum GarmentPlaneGeometry {
    static let algorithmVersion = "garment-plane-2"
    static let maximumSamples = 4096
    static let minimumSamples = 60
    static let minimumDepthMeters = 0.15
    static let maximumDepthMeters = 3.0
    static let inlierToleranceMeters = 0.010
    static let minimumInlierFraction = 0.75
    static let maximumOrthogonalRMSMeters = 0.008
    static let minimumRayCosine = 0.35
    private static let maximumBufferPixels = 4_194_304

    static func fit(frame: MeasurementFrame, mask: GarmentMask,
                    uprightOrientation: ImageOrientation) throws -> GarmentPlane {
        do { return try fitDetailed(frame: frame, mask: mask, uprightOrientation: uprightOrientation) }
        catch let error as ContextualMeasurementError { throw error.failure }
    }

    static func fitDetailed(frame: MeasurementFrame, mask: GarmentMask,
                            uprightOrientation: ImageOrientation) throws -> GarmentPlane {
        try validate(frame: frame, mask: mask)
        let foreground = mask.values.reduce(0) { $0 + ($1 == 1 ? 1 : 0) }
        let fraction = Double(foreground) / Double(mask.values.count)
        guard fraction >= 0.10, fraction <= 0.85 else {
            throw failure(.invalidMask, .maskCoverage, evidence: ["foregroundFraction": fraction, "minimum": 0.10, "maximum": 0.85])
        }
        guard !touchesUprightLateralEdge(mask, orientation: uprightOrientation) else {
            throw failure(.invalidMask, .maskClipped)
        }
        let width = frame.depth.size.width, height = frame.depth.size.height
        var step = max(1, Int(ceil(sqrt(Double(width * height) / Double(maximumSamples)))))
        while ((width + step - 1) / step) * ((height + step - 1) / step) > maximumSamples { step += 1 }
        var samples: [Sample] = []
        samples.reserveCapacity(maximumSamples)
        var interiorCount = 0, inRangeInteriorCount = 0
        var interiorBounds = Bounds()
        // AVDepthData has metric depth but no ARKit per-pixel confidence map.
        // Keep unknown confidence absent; the same geometric support checks
        // below still determine whether these depth samples form a usable plane.
        let confidence = frame.depth.confidence
        for y in stride(from: 1, to: height - 1, by: step) {
            for x in stride(from: 1, to: width - 1, by: step) {
                guard isInterior(x: x, y: y, depthSize: frame.depth.size, mask: mask) else { continue }
                interiorCount += 1
                let location = ImagePoint(x: Double(x) / Double(width), y: Double(y) / Double(height))
                interiorBounds.include(location)
                let index = y * width + x, z = Double(frame.depth.values[y * width + x])
                guard z.isFinite, (minimumDepthMeters...maximumDepthMeters).contains(z) else { continue }
                inRangeInteriorCount += 1
                if let confidence, !(1...2).contains(confidence[index]) { continue }
                let position = scale(ray(location, frame: frame), z)
                guard finite(position) else { continue }
                samples.append(.init(position: position, raw: location))
            }
        }
        guard interiorCount > 0 else { throw failure(.invalidMask, .maskHasNoInterior) }
        guard samples.count >= minimumSamples else {
            let reason: MeasurementFailureReason = inRangeInteriorCount >= minimumSamples
                ? .lowSensorConfidence : .planeTooFewSamples
            throw failure(.insufficientGarmentPlane, reason,
                          evidence: ["samples": Double(samples.count), "required": Double(minimumSamples), "interior": Double(interiorCount), "inRange": Double(inRangeInteriorCount)])
        }
        let validFraction = Double(samples.count) / Double(interiorCount)
        guard validFraction >= 0.25 else {
            throw failure(.insufficientGarmentPlane, .planeLowValidFraction, evidence: ["fraction": validFraction, "minimum": 0.25])
        }

        var random = DeterministicRandom()
        var bestIndices: [Int] = []
        var bestSquaredError = Double.infinity
        for _ in 0..<128 {
            let i = random.index(samples.count), j = random.index(samples.count), k = random.index(samples.count)
            guard i != j, i != k, j != k else { continue }
            let a = samples[i].position, b = samples[j].position, c = samples[k].position
            let product = cross(subtract(b, a), subtract(c, a)), magnitude = length(product)
            guard magnitude > 0.0001 else { continue }
            let normal = scale(product, 1 / magnitude), offset = -dot(normal, a)
            var indices: [Int] = [], squaredError = 0.0
            for index in samples.indices {
                let error = abs(dot(normal, samples[index].position) + offset)
                if error <= inlierToleranceMeters { indices.append(index); squaredError += error * error }
            }
            if indices.count > bestIndices.count || (indices.count == bestIndices.count && squaredError < bestSquaredError) {
                bestIndices = indices; bestSquaredError = squaredError
            }
        }
        let required = max(minimumSamples, Int(ceil(Double(samples.count) * minimumInlierFraction)))
        guard bestIndices.count >= required else { throw failure(.insufficientGarmentPlane, .planeInsufficientInliers, evidence: ["inliers": Double(bestIndices.count), "required": Double(required)]) }
        var indices = bestIndices
        var fitted = try principalPlane(samples: samples, indices: indices)
        for _ in 0..<3 {
            let next = samples.indices.filter {
                abs(dot(fitted.normal, samples[$0].position) + fitted.offset) <= inlierToleranceMeters
            }
            guard next.count >= required else { throw failure(.insufficientGarmentPlane, .planeInsufficientInliers, evidence: ["inliers": Double(next.count), "required": Double(required)]) }
            if next == indices { break }
            indices = next
            fitted = try principalPlane(samples: samples, indices: indices)
        }
        // Preserve the reference order: final support statistics use final inliers,
        // but the returned plane is fitted, not a further support-only refit.
        indices = samples.indices.filter {
            abs(dot(fitted.normal, samples[$0].position) + fitted.offset) <= inlierToleranceMeters
        }
        guard indices.count >= required else { throw failure(.insufficientGarmentPlane, .planeInsufficientInliers, evidence: ["inliers": Double(indices.count), "required": Double(required)]) }
        let support = try principalPlane(samples: samples, indices: indices)
        guard support.minorVariance >= 0.000225,
              support.minorVariance / max(support.majorVariance, 1e-12) >= 0.005
        else { throw failure(.insufficientGarmentPlane, .planeNarrowSupport, evidence: ["minorVariance": support.minorVariance, "majorVariance": support.majorVariance]) }
        var inlierBounds = Bounds(), squaredError = 0.0
        for index in indices {
            inlierBounds.include(samples[index].raw)
            let error = dot(fitted.normal, samples[index].position) + fitted.offset
            squaredError += error * error
        }
        guard interiorBounds.extentX > 0, interiorBounds.extentY > 0 else { throw failure(.insufficientGarmentPlane, .planeNarrowSupport) }
        let horizontalCoverage = inlierBounds.extentX / interiorBounds.extentX
        let verticalCoverage = inlierBounds.extentY / interiorBounds.extentY
        guard horizontalCoverage >= 0.6, verticalCoverage >= 0.6 else { throw failure(.insufficientGarmentPlane, .planeLowCoverage, evidence: ["horizontal": horizontalCoverage, "vertical": verticalCoverage, "minimum": 0.6]) }
        let rms = sqrt(squaredError / Double(indices.count))
        let viewCosine = abs(dot(fitted.normal, scale(support.center, 1 / length(support.center))))
        guard rms.isFinite, rms <= maximumOrthogonalRMSMeters else {
            throw failure(.insufficientGarmentPlane, .planeHighResidual,
                          evidence: rms.isFinite ? ["rmsMeters": rms, "maximum": maximumOrthogonalRMSMeters] : nil)
        }
        guard viewCosine.isFinite, viewCosine >= minimumRayCosine else {
            throw failure(.insufficientGarmentPlane, .planeViewingAngle,
                          evidence: viewCosine.isFinite ? ["cosine": viewCosine, "minimum": minimumRayCosine] : nil)
        }
        return .init(normal: fitted.normal, offset: fitted.offset,
                     quality: .init(interiorCount: interiorCount, candidateCount: samples.count,
                         inlierCount: indices.count, orthogonalRMSMeters: rms,
                         minorVarianceSquareMeters: support.minorVariance,
                         majorVarianceSquareMeters: support.majorVariance,
                         horizontalCoverage: horizontalCoverage, verticalCoverage: verticalCoverage,
                         viewingRayCosine: viewCosine))
    }

    static func intersection(point: ImagePoint, frame: MeasurementFrame, plane: GarmentPlane) throws -> Point3D {
        do { return try intersectionDetailed(point: point, frame: frame, plane: plane) }
        catch let error as ContextualMeasurementError { throw error.failure }
    }

    static func intersectionDetailed(point: ImagePoint, frame: MeasurementFrame, plane: GarmentPlane) throws -> Point3D {
        guard point.isValid else { throw failure(.outOfBounds, .pointOutsideImage, scope: .landmark) }
        guard calibrationIsValid(frame) else { throw failure(.invalidCalibration, .invalidCalibration, stage: .input) }
        let direction = ray(point, frame: frame), normalLength = length(plane.normal)
        guard finite(plane.normal), plane.offset.isFinite, normalLength > 0.000001 else {
            throw failure(.insufficientGarmentPlane, .planeDegenerate)
        }
        let denominator = dot(plane.normal, direction)
        let cosine = abs(denominator) / (normalLength * length(direction))
        guard cosine.isFinite, cosine >= minimumRayCosine else { throw failure(.insufficientGarmentPlane, .planeViewingAngle, scope: .landmark, evidence: cosine.isFinite ? ["cosine": cosine, "minimum": minimumRayCosine] : nil) }
        let position = scale(direction, -plane.offset / denominator)
        guard finite(position), (minimumDepthMeters...maximumDepthMeters).contains(position.z) else {
            throw failure(.insufficientGarmentPlane, .planeIntersectionRange, scope: .landmark)
        }
        return position
    }

    static func project(_ position: Point3D, frame: MeasurementFrame) -> ImagePoint? {
        guard calibrationIsValid(frame), finite(position), position.z > 0 else { return nil }
        let k = frame.intrinsics
        let point = ImagePoint(x: (k.fx * position.x / position.z + k.cx) / Double(frame.imageSize.width),
                               y: (k.fy * position.y / position.z + k.cy) / Double(frame.imageSize.height))
        return point.isValid ? point : nil
    }

    static func viewingAngleDegrees(at position: Point3D, plane: GarmentPlane) -> Double {
        let cosine = abs(dot(plane.normal, position)) / (length(plane.normal) * length(position))
        return acos(min(1, max(0, cosine))) * 180 / .pi
    }

    private static func validate(frame: MeasurementFrame, mask: GarmentMask) throws {
        guard calibrationIsValid(frame) else { throw failure(.invalidCalibration, .invalidCalibration, stage: .input) }
        let size = frame.depth.size
        guard size.isValid, size.width >= 3, size.height >= 3,
              size.width <= maximumBufferPixels / size.height,
              frame.depth.values.count == size.width * size.height,
              size.width * frame.imageSize.height == size.height * frame.imageSize.width
        else { throw failure(.invalidDepthMap, .malformedDepth, stage: .input) }
        if let confidence = frame.depth.confidence {
            guard confidence.count == frame.depth.values.count, confidence.allSatisfy({ $0 <= 2 }) else {
                throw failure(.invalidDepthMap, .malformedConfidence, stage: .input)
            }
        } else if frame.source != .avFoundationLiDAR {
            // The AVFoundation provider explicitly has no confidence channel.
            // Do not hide a missing ARKit channel or reinterpret it as high quality.
            throw failure(.invalidDepthMap, .missingDepthConfidence, stage: .input)
        }
        guard mask.size.isValid, mask.size.width <= maximumBufferPixels / mask.size.height,
              mask.values.count == mask.size.width * mask.size.height,
              mask.size.width * frame.imageSize.height == mask.size.height * frame.imageSize.width,
              mask.values.allSatisfy({ $0 <= 1 }) else { throw failure(.invalidMask, .malformedMask, stage: .input) }
    }

    private static func failure(_ failure: MeasurementFailure, _ reason: MeasurementFailureReason,
                                stage: MeasurementFailureStage = .garmentPlane,
                                scope: MeasurementFailureScope = .capture,
                                evidence: [String: Double]? = nil) -> ContextualMeasurementError {
        .init(failure: failure, context: .init(stage: stage, reason: reason, scope: scope,
                                             recovery: .retake, evidence: evidence))
    }

    private static func calibrationIsValid(_ frame: MeasurementFrame) -> Bool {
        let k = frame.intrinsics
        return frame.imageSize.isValid && frame.timestamp.isFinite && k.referenceSize == frame.imageSize
            && k.fx.isFinite && k.fy.isFinite && k.cx.isFinite && k.cy.isFinite && k.fx > 0 && k.fy > 0
            && k.cx >= 0 && k.cx < Double(frame.imageSize.width) && k.cy >= 0 && k.cy < Double(frame.imageSize.height)
            && [-k.cx / k.fx, (Double(frame.imageSize.width) - k.cx) / k.fx,
                -k.cy / k.fy, (Double(frame.imageSize.height) - k.cy) / k.fy].allSatisfy({ ($0 * maximumDepthMeters).isFinite })
    }

    private static func touchesUprightLateralEdge(_ mask: GarmentMask, orientation: ImageOrientation) -> Bool {
        let width = mask.size.width, height = mask.size.height
        switch orientation {
        case .up, .down:
            return (0..<height).contains { mask.values[$0 * width] == 1 || mask.values[$0 * width + width - 1] == 1 }
        case .left, .right:
            return (0..<width).contains { mask.values[$0] == 1 || mask.values[(height - 1) * width + $0] == 1 }
        }
    }

    private static func isInterior(x: Int, y: Int, depthSize: PixelSize, mask: GarmentMask) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 {
                let mx = Int(floor(Double(x + dx) / Double(depthSize.width) * Double(mask.size.width)))
                let my = Int(floor(Double(y + dy) / Double(depthSize.height) * Double(mask.size.height)))
                if mask.values[my * mask.size.width + mx] != 1 { return false }
            }
        }
        return true
    }

    private static func ray(_ point: ImagePoint, frame: MeasurementFrame) -> Point3D {
        let k = frame.intrinsics
        return .init(x: (point.x * Double(frame.imageSize.width) - k.cx) / k.fx,
                     y: (point.y * Double(frame.imageSize.height) - k.cy) / k.fy, z: 1)
    }

    static func finite(_ point: Point3D) -> Bool { point.x.isFinite && point.y.isFinite && point.z.isFinite }
    static func dot(_ a: Point3D, _ b: Point3D) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    static func length(_ p: Point3D) -> Double { hypot(hypot(p.x, p.y), p.z) }
    static func scale(_ p: Point3D, _ s: Double) -> Point3D { .init(x: p.x * s, y: p.y * s, z: p.z * s) }
    static func subtract(_ a: Point3D, _ b: Point3D) -> Point3D { .init(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func add(_ a: Point3D, _ b: Point3D) -> Point3D { .init(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func cross(_ a: Point3D, _ b: Point3D) -> Point3D {
        .init(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
    }

    private struct Sample { var position: Point3D; var raw: ImagePoint }
    private struct Bounds {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var extentX: Double { maxX - minX }
        var extentY: Double { maxY - minY }
        mutating func include(_ point: ImagePoint) {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
    }
    private struct DeterministicRandom {
        var state: UInt64 = 0x6d61_736b_706c_616e
        mutating func index(_ count: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(count))
        }
    }
    private struct PrincipalPlane {
        var normal: Point3D
        var offset: Double
        var center: Point3D
        var minorVariance: Double
        var majorVariance: Double
    }
    private static func principalPlane(samples: [Sample], indices: [Int]) throws -> PrincipalPlane {
        guard indices.count >= 3 else { throw failure(.insufficientGarmentPlane, .planeTooFewSamples) }
        var center = Point3D(x: 0, y: 0, z: 0)
        for index in indices { center = add(center, samples[index].position) }
        center = scale(center, 1 / Double(indices.count))
        var covariance = [Double](repeating: 0, count: 9)
        for index in indices {
            let delta = subtract(samples[index].position, center), d = [delta.x, delta.y, delta.z]
            for row in 0..<3 { for column in 0..<3 { covariance[row * 3 + column] += d[row] * d[column] } }
        }
        for index in covariance.indices { covariance[index] /= Double(indices.count) }
        // Symmetric 3x3 Jacobi TLS; no depth-as-a-function-of-image-axis fit.
        var vectors: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for _ in 0..<32 {
            var p = 0, q = 1
            for (a, b) in [(0, 2), (1, 2)] where abs(covariance[a * 3 + b]) > abs(covariance[p * 3 + q]) { p = a; q = b }
            let off = covariance[p * 3 + q]
            if abs(off) < 1e-14 { break }
            let tau = (covariance[q * 3 + q] - covariance[p * 3 + p]) / (2 * off)
            let t = (tau >= 0 ? 1.0 : -1.0) / (abs(tau) + sqrt(1 + tau * tau))
            let c = 1 / sqrt(1 + t * t), s = t * c
            covariance[p * 3 + p] -= t * off; covariance[q * 3 + q] += t * off
            covariance[p * 3 + q] = 0; covariance[q * 3 + p] = 0
            for k in 0..<3 where k != p && k != q {
                let a = covariance[k * 3 + p], b = covariance[k * 3 + q]
                covariance[k * 3 + p] = c * a - s * b; covariance[p * 3 + k] = covariance[k * 3 + p]
                covariance[k * 3 + q] = s * a + c * b; covariance[q * 3 + k] = covariance[k * 3 + q]
            }
            for k in 0..<3 {
                let a = vectors[k * 3 + p], b = vectors[k * 3 + q]
                vectors[k * 3 + p] = c * a - s * b; vectors[k * 3 + q] = s * a + c * b
            }
        }
        let order = (0..<3).sorted { covariance[$0 * 3 + $0] < covariance[$1 * 3 + $1] }
        let smallest = order[0]
        var normal = Point3D(x: vectors[smallest], y: vectors[3 + smallest], z: vectors[6 + smallest])
        normal = scale(normal, 1 / length(normal))
        if normal.z < 0 { normal = scale(normal, -1) }
        guard finite(normal), finite(center) else { throw failure(.insufficientGarmentPlane, .planeDegenerate) }
        return .init(normal: normal, offset: -dot(normal, center), center: center,
                     minorVariance: max(0, covariance[order[1] * 3 + order[1]]),
                     majorVariance: max(0, covariance[order[2] * 3 + order[2]]))
    }
}

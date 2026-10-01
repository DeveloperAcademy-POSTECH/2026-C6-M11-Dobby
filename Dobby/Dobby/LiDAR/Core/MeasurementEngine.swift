import Foundation

/// Resolves a frozen RGB/depth frame and its matching landmarks into 3D lengths.
/// Optional garment-axis projection removes sideways endpoint drift in that same space.
/// Positions use optical coordinates: x right, y down, z forward, all in metres.
/// `valid` describes input support, not a guaranteed physical error in centimetres.
nonisolated struct LiDARMeasurementEngine {
    static let algorithmVersion = "lidar-unprojection-1.1.0"
    private let options: MeasurementOptions

    init(options: MeasurementOptions = .init()) {
        self.options = options
    }

    func measure(
        frame: MeasurementFrame,
        landmarks: GarmentLandmarkSet,
        definitions: [MeasurementDefinition]
    ) -> GarmentMeasurementResult {
        let globalFailure = validate(frame: frame, landmarks: landmarks)
        let groupedPoints = Dictionary(grouping: landmarks.points, by: \.id)
        let groupedDefinitions = Dictionary(grouping: definitions, by: \.id)
        var resolved: [String: PointResolution] = [:]
        var pointFailures: [String: MeasurementFailure] = [:]

        // Resolve dependencies once per frame. A bad derived point only invalidates
        // measurements that depend on it, not unrelated direct measurements.
        func resolveID(_ id: String, visiting: inout Set<String>) -> Result<PointResolution, PointResolutionError> {
            if let value = resolved[id] { return .success(value) }
            if let failure = pointFailures[id] { return .failure(.init(reason: failure)) }
            guard !visiting.contains(id) else {
                pointFailures[id] = .invalidDefinition
                return .failure(.init(reason: .invalidDefinition))
            }
            // This limit belongs to the current traversal, not to the requested
            // landmark. Do not poison a later, shallower request with its failure.
            guard visiting.count < 64 else {
                return .failure(.init(reason: .invalidDefinition, canCache: false))
            }
            guard let candidates = groupedPoints[id], !candidates.isEmpty else {
                pointFailures[id] = .missingLandmark
                return .failure(.init(reason: .missingLandmark))
            }
            guard candidates.count == 1 else {
                pointFailures[id] = .duplicateLandmark
                return .failure(.init(reason: .duplicateLandmark))
            }
            let landmark = candidates[0]
            let resolution: Result<PointResolution, PointResolutionError>
            if let sourceIDs = landmarks.effectiveDerivedSourceIDs(for: id) {
                if let failure = validateLandmark(landmark, origin: landmarks.origin) {
                    resolution = .failure(.init(reason: failure))
                } else if sourceIDs.count < 2 || sourceIDs.count > 64
                    || sourceIDs.contains(where: { $0.isEmpty }) || Set(sourceIDs).count != sourceIDs.count {
                    resolution = .failure(.init(reason: .invalidDefinition))
                } else {
                    visiting.insert(id)
                    var sources: [PointResolution] = []
                    var failure: PointResolutionError?
                    for sourceID in sourceIDs {
                        switch resolveID(sourceID, visiting: &visiting) {
                        case .success(let value): sources.append(value)
                        case .failure(let error):
                            if failure == nil { failure = error }
                        }
                    }
                    visiting.remove(id)
                    if let failure {
                        resolution = .failure(failure)
                    } else {
                        resolution = spatialAverage(landmark, sourceIDs: sourceIDs, sources: sources,
                                                    frame: frame, origin: landmarks.origin)
                            .mapError { .init(reason: $0) }
                    }
                }
            } else {
                resolution = resolve(landmark, frame: frame, set: landmarks).mapError { .init(reason: $0) }
            }
            switch resolution {
            case .success(let value): resolved[id] = value
            case .failure(let error):
                if error.canCache { pointFailures[id] = error.reason }
            }
            return resolution
        }

        let values = definitions.map { definition -> MeasurementValue in
            func unavailable(_ failure: MeasurementFailure, points: [ResolvedLandmark] = []) -> MeasurementValue {
                .init(id: definition.id, title: definition.title, meters: nil,
                      status: .unavailable, failure: failure, points: points)
            }
            if let globalFailure { return unavailable(globalFailure) }
            guard !definition.id.isEmpty, groupedDefinitions[definition.id]?.count == 1,
                  definition.landmarkIDs.count >= 2, definition.landmarkIDs.count <= 64,
                  definition.landmarkIDs.allSatisfy({ !$0.isEmpty }),
                  zip(definition.landmarkIDs, definition.landmarkIDs.dropFirst()).allSatisfy({ $0 != $1 })
            else { return unavailable(.invalidDefinition) }

            var points: [ResolvedLandmark] = []
            var uncertain = false
            var firstFailure: MeasurementFailure?
            for id in definition.landmarkIDs {
                var visiting: Set<String> = []
                switch resolveID(id, visiting: &visiting) {
                case .failure(let error):
                    if firstFailure == nil { firstFailure = error.reason }
                case .success(let value):
                    points.append(value.landmark)
                    uncertain = uncertain || value.uncertain
                }
            }
            if let firstFailure { return unavailable(firstFailure, points: points) }
            if let projection = definition.projection {
                let axisIDs = projection.referenceAxisLandmarkIDs
                guard points.count == 2, axisIDs.count == 2,
                      axisIDs.allSatisfy({ !$0.isEmpty }), axisIDs[0] != axisIDs[1]
                else { return unavailable(.invalidDefinition, points: points) }
                var axis: [PointResolution] = []
                for id in axisIDs {
                    var visiting: Set<String> = []
                    switch resolveID(id, visiting: &visiting) {
                    case .failure(let error):
                        if firstFailure == nil { firstFailure = error.reason }
                    case .success(let value): axis.append(value)
                    }
                }
                if let firstFailure { return unavailable(firstFailure, points: points) }
                switch projectedEndpoint(start: points[0], end: points[1], axis: axis,
                                         axisIDs: axisIDs, frame: frame) {
                case .failure(let failure): return unavailable(failure, points: points)
                case .success(let end):
                    points[1] = end
                    uncertain = uncertain || axis.contains(where: \.uncertain)
                }
            }
            let meters = zip(points, points.dropFirst()).reduce(0.0) { sum, pair in
                let a = pair.0.position, b = pair.1.position
                // hypot scales its operands before squaring, preserving representable
                // distances that would otherwise overflow or underflow along an axis.
                return sum + hypot(hypot(a.x - b.x, a.y - b.y), a.z - b.z)
            }
            guard meters.isFinite, meters > 0 else { return unavailable(.invalidDefinition, points: points) }
            return .init(id: definition.id, title: definition.title, meters: meters,
                         status: uncertain ? .uncertain : .valid, failure: nil, points: points)
        }
        return .init(sessionID: frame.sessionID, frameID: frame.frameID,
                     algorithmVersion: Self.algorithmVersion, source: frame.source, values: values)
    }

    private func projectedEndpoint(
        start: ResolvedLandmark, end: ResolvedLandmark, axis: [PointResolution],
        axisIDs: [String], frame: MeasurementFrame
    ) -> Result<ResolvedLandmark, MeasurementFailure> {
        let a = axis[0].landmark.position, b = axis[1].landmark.position
        let direction = Point3D(x: b.x - a.x, y: b.y - a.y, z: b.z - a.z)
        let length = hypot(hypot(direction.x, direction.y), direction.z)
        // A degenerate axis cannot define a direction. Never fall back to a straight total length.
        guard length.isFinite, length > 0.000_001 else { return .failure(.invalidDefinition) }
        let unit = Point3D(x: direction.x / length, y: direction.y / length, z: direction.z / length)
        let delta = Point3D(x: end.position.x - start.position.x,
                            y: end.position.y - start.position.y,
                            z: end.position.z - start.position.z)
        let alongAxis = delta.x * unit.x + delta.y * unit.y + delta.z * unit.z
        let position = Point3D(x: end.position.x - alongAxis * unit.x,
                               y: end.position.y - alongAxis * unit.y,
                               z: end.position.z - alongAxis * unit.z)
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite, position.z > 0
        else { return .failure(.invalidCalibration) }
        let k = frame.intrinsics
        let imagePoint = ImagePoint(
            x: (k.fx * position.x / position.z + k.cx) / Double(frame.imageSize.width),
            y: (k.fy * position.y / position.z + k.cy) / Double(frame.imageSize.height)
        )
        guard imagePoint.isValid else { return .failure(.outOfBounds) }
        let qualities = [start.quality, end.quality] + axis.map { $0.landmark.quality }
        let residuals = qualities.compactMap(\.planeResidualMeters)
        let quality = PointQuality(
            validSamples: qualities.map(\.validSamples).min() ?? 0,
            candidateSamples: qualities.map(\.candidateSamples).max() ?? 0,
            confidenceAvailable: qualities.allSatisfy(\.confidenceAvailable),
            depthSpreadMeters: qualities.map(\.depthSpreadMeters).max() ?? 0,
            planeResidualMeters: residuals.count == qualities.count ? residuals.max() : nil,
            method: .axisProjection
        )
        var sourceIDs: [String] = []
        for id in [start.id, end.id] + axisIDs where !sourceIDs.contains(id) { sourceIDs.append(id) }
        return .success(.init(id: end.id, imagePoint: imagePoint, position: position,
                              quality: quality, sourceLandmarkIDs: sourceIDs))
    }

    private func validate(frame: MeasurementFrame, landmarks: GarmentLandmarkSet) -> MeasurementFailure? {
        guard frame.sessionID == landmarks.sessionID, frame.frameID == landmarks.frameID else { return .frameMismatch }
        guard (1...12).contains(options.sampleRadius),
              options.minimumSamples >= 3,
              options.minimumSamples <= square(2 * options.sampleRadius + 1),
              options.minimumDepthMeters.isFinite, options.minimumDepthMeters > 0,
              options.maximumDepthMeters.isFinite, options.maximumDepthMeters > options.minimumDepthMeters,
              options.minimumSensorConfidence <= 2,
              options.minimumModelConfidence.isFinite, (0...1).contains(options.minimumModelConfidence),
              options.maximumPlaneResidualMeters.isFinite, options.maximumPlaneResidualMeters > 0,
              options.maximumDepthSpreadMeters.isFinite, options.maximumDepthSpreadMeters > 0
        else { return .invalidOptions }
        let k = frame.intrinsics
        guard frame.imageSize.isValid, k.referenceSize == frame.imageSize,
              frame.timestamp.isFinite,
              k.fx.isFinite, k.fy.isFinite, k.cx.isFinite, k.cy.isFinite,
              k.fx > 0, k.fy > 0,
              k.cx >= 0, k.cx < Double(frame.imageSize.width),
              k.cy >= 0, k.cy < Double(frame.imageSize.height)
        else { return .invalidCalibration }
        // Finite positive intrinsics alone do not guarantee representable camera rays.
        // Reject corrupted calibration before it can put infinities in a saved result.
        let extremeRays = [
            -k.cx / k.fx, (Double(frame.imageSize.width) - k.cx) / k.fx,
            -k.cy / k.fy, (Double(frame.imageSize.height) - k.cy) / k.fy
        ]
        guard extremeRays.allSatisfy({ ($0 * options.maximumDepthMeters).isFinite })
        else { return .invalidCalibration }
        let depth = frame.depth
        guard depth.size.isValid, sameAspect(depth.size, frame.imageSize),
              depth.values.count == depth.size.width * depth.size.height
        else { return .invalidDepthMap }
        if let confidence = depth.confidence {
            guard confidence.count == depth.values.count, confidence.allSatisfy({ $0 <= 2 }) else { return .invalidDepthMap }
        }
        if let mask = landmarks.mask {
            guard mask.size.isValid, sameAspect(mask.size, frame.imageSize),
                  mask.values.count == mask.size.width * mask.size.height,
                  mask.values.allSatisfy({ $0 <= 1 }) else { return .invalidMask }
        }
        return nil
    }

    private func sameAspect(_ first: PixelSize, _ second: PixelSize) -> Bool {
        first.width * second.height == first.height * second.width
    }

    private func resolve(
        _ landmark: GarmentLandmark,
        frame: MeasurementFrame,
        set: GarmentLandmarkSet
    ) -> Result<PointResolution, MeasurementFailure> {
        if let failure = validateLandmark(landmark, origin: set.origin) { return .failure(failure) }
        let target = landmark.point
        let map = frame.depth
        let targetX = target.x * Double(map.size.width)
        let targetY = target.y * Double(map.size.height)
        let centerX = Int(targetX), centerY = Int(targetY)
        let targetInsideMask: Bool
        if let mask = set.mask {
            let x = min(mask.size.width - 1, Int(target.x * Double(mask.size.width)))
            let y = min(mask.size.height - 1, Int(target.y * Double(mask.size.height)))
            targetInsideMask = mask.values[y * mask.size.width + x] == 1
        } else {
            targetInsideMask = true
        }
        var samples: [DepthSample] = []
        var candidateCount = 0
        for y in max(0, centerY - options.sampleRadius)...min(map.size.height - 1, centerY + options.sampleRadius) {
            for x in max(0, centerX - options.sampleRadius)...min(map.size.width - 1, centerX + options.sampleRadius) {
                candidateCount += 1
                let nx = (Double(x) + 0.5) / Double(map.size.width)
                let ny = (Double(y) + 0.5) / Double(map.size.height)
                if let mask = set.mask {
                    let mx = min(mask.size.width - 1, Int(nx * Double(mask.size.width)))
                    let my = min(mask.size.height - 1, Int(ny * Double(mask.size.height)))
                    if mask.values[my * mask.size.width + mx] == 0 { continue }
                }
                let index = y * map.size.width + x
                let z = Double(map.values[index])
                guard z.isFinite, z >= options.minimumDepthMeters, z <= options.maximumDepthMeters else { continue }
                let confidence = map.confidence?[index]
                if let confidence, confidence < options.minimumSensorConfidence { continue }
                let ray = cameraRay(.init(x: nx, y: ny), frame: frame)
                samples.append(.init(x: Double(x) + 0.5, y: Double(y) + 0.5,
                                     rayX: ray.x, rayY: ray.y, z: z, confidence: confidence))
            }
        }
        guard samples.count >= options.minimumSamples else { return .failure(.insufficientDepth) }

        // Separate depth surfaces before fitting; a plane must never bridge garment and background.
        let sorted = samples.sorted { $0.z < $1.z }
        let gap = max(0.012, median(sorted.map(\.z)) * 0.012)
        var clusters: [[DepthSample]] = []
        for sample in sorted {
            if let previous = clusters.last?.last, sample.z - previous.z <= gap {
                clusters[clusters.count - 1].append(sample)
            } else {
                clusters.append([sample])
            }
        }
        let supported = clusters.filter { $0.count >= options.minimumSamples }
        guard !supported.isEmpty else { return .failure(.insufficientDepth) }
        func nearestDistance(_ cluster: [DepthSample]) -> Double {
            cluster.map { square($0.x - targetX) + square($0.y - targetY) }.min() ?? .infinity
        }
        // Prefer a supported foreground surface adjacent to an outline point. A distant foreground
        // object does not displace a strongly supported surface directly beneath the point.
        var chosen = supported.min { nearestDistance($0) < nearestDistance($1) }!
        if let foreground = supported.first, nearestDistance(foreground) <= 2.25 {
            chosen = foreground
        }
        let centerDepth = median(chosen.map(\.z))
        let mad = median(chosen.map { abs($0.z - centerDepth) })
        let cutoff = max(0.004, 3.5 * 1.4826 * mad)
        chosen = chosen.filter { abs($0.z - centerDepth) <= cutoff }
        guard chosen.count >= options.minimumSamples else { return .failure(.insufficientDepth) }
        let ray = cameraRay(target, frame: frame)
        let spread = percentile(chosen.map(\.z), 0.9) - percentile(chosen.map(\.z), 0.1)
        var plane: PlaneEstimate?
        if options.useLocalPlane, isNearSupport(x: targetX, y: targetY, samples: chosen) {
            plane = fitPlane(samples: chosen, rayX: ray.x, rayY: ray.y, targetX: targetX, targetY: targetY)
        }
        let z = plane?.depth ?? median(chosen.map(\.z))
        let lowSensorConfidence = chosen.contains { ($0.confidence ?? 0) < 2 }
        let uncertain = map.confidence == nil || lowSensorConfidence || plane == nil || clusters.count > 1
            || (set.origin == .model && landmark.confidence == nil)
            // A mask hole may still be inside the sample convex hull. Interpolation can
            // supply an estimate, but cannot prove the landmark belongs to the garment.
            || !targetInsideMask
        let point = ResolvedLandmark(
            id: landmark.id, imagePoint: target,
            position: .init(x: ray.x * z, y: ray.y * z, z: z),
            quality: .init(validSamples: plane?.sampleCount ?? chosen.count,
                           candidateSamples: candidateCount,
                           confidenceAvailable: map.confidence != nil,
                           depthSpreadMeters: spread,
                           planeResidualMeters: plane?.residual,
                           method: plane == nil ? .robustMedian : .localPlane)
        )
        // A median from spatially distant support is not a substitute for the depth at the landmark.
        guard nearestDistance(chosen) <= square(Double(options.sampleRadius)) else { return .failure(.insufficientDepth) }
        // Excessive spread without a well-supported surface fit cannot supply trustworthy depth.
        if plane == nil && spread > options.maximumDepthSpreadMeters { return .failure(.insufficientDepth) }
        return .success(.init(landmark: point, uncertain: uncertain))
    }

    private func validateLandmark(_ landmark: GarmentLandmark, origin: LandmarkOrigin) -> MeasurementFailure? {
        guard landmark.point.isValid else { return .outOfBounds }
        guard landmark.isVisible else { return .occludedLandmark }
        if let confidence = landmark.confidence {
            guard confidence.isFinite, (0...1).contains(confidence),
                  origin != .model || confidence >= options.minimumModelConfidence
            else { return .lowLandmarkConfidence }
        }
        return nil
    }

    private func spatialAverage(
        _ landmark: GarmentLandmark, sourceIDs: [String], sources: [PointResolution],
        frame: MeasurementFrame, origin: LandmarkOrigin
    ) -> Result<PointResolution, MeasurementFailure> {
        let count = Double(sources.count)
        // Divide first so a representable mean does not overflow while summing.
        let position = sources.reduce(Point3D(x: 0, y: 0, z: 0)) { mean, source in
            let p = source.landmark.position
            return .init(x: mean.x + p.x / count, y: mean.y + p.y / count, z: mean.z + p.z / count)
        }
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite, position.z > 0
        else { return .failure(.invalidCalibration) }
        let k = frame.intrinsics
        let projected = ImagePoint(
            x: (k.fx * (position.x / position.z) + k.cx) / Double(frame.imageSize.width),
            y: (k.fy * (position.y / position.z) + k.cy) / Double(frame.imageSize.height)
        )
        guard projected.isValid else { return .failure(.outOfBounds) }
        let qualities = sources.map { $0.landmark.quality }
        // A derived point has no new sensor samples. Report the weakest support
        // and worst spread/residual of its contributors, without improving status.
        let residuals = qualities.compactMap(\.planeResidualMeters)
        let quality = PointQuality(
            validSamples: qualities.map(\.validSamples).min() ?? 0,
            candidateSamples: qualities.map(\.candidateSamples).max() ?? 0,
            confidenceAvailable: qualities.allSatisfy(\.confidenceAvailable),
            depthSpreadMeters: qualities.map(\.depthSpreadMeters).max() ?? 0,
            planeResidualMeters: residuals.count == qualities.count ? residuals.max() : nil,
            method: .spatialAverage
        )
        return .success(.init(
            landmark: .init(id: landmark.id, imagePoint: projected, position: position,
                            quality: quality, sourceLandmarkIDs: sourceIDs),
            uncertain: sources.contains(where: \.uncertain) || (origin == .model && landmark.confidence == nil)
        ))
    }

    private func cameraRay(_ point: ImagePoint, frame: MeasurementFrame) -> (x: Double, y: Double) {
        let k = frame.intrinsics
        return ((point.x * Double(frame.imageSize.width) - k.cx) / k.fx,
                (point.y * Double(frame.imageSize.height) - k.cy) / k.fy)
    }

    /// A plane has linear inverse axial depth over normalized camera rays: 1/z = a*x + b*y + c.
    /// Centering at the requested ray avoids solving the poorly scaled raw 3x3 normal equations.
    private func fitPlane(
        samples: [DepthSample], rayX: Double, rayY: Double, targetX: Double, targetY: Double
    ) -> PlaneEstimate? {
        var retained = samples
        for iteration in 0..<3 {
            guard retained.count >= options.minimumSamples else { return nil }
            let n = Double(retained.count)
            let meanX = retained.reduce(0.0) { $0 + $1.rayX - rayX } / n
            let meanY = retained.reduce(0.0) { $0 + $1.rayY - rayY } / n
            let meanD = retained.reduce(0.0) { $0 + 1 / $1.z } / n
            var xx = 0.0, xy = 0.0, yy = 0.0, xd = 0.0, yd = 0.0
            for sample in retained {
                let x = sample.rayX - rayX - meanX
                let y = sample.rayY - rayY - meanY
                let d = 1 / sample.z - meanD
                xx += x * x; xy += x * y; yy += y * y; xd += x * d; yd += y * d
            }
            let determinant = xx * yy - xy * xy
            let trace = xx + yy
            guard trace > 0, determinant > trace * trace * 0.001 else { return nil }
            let a = (xd * yy - yd * xy) / determinant
            let b = (yd * xx - xd * xy) / determinant
            let c = meanD - a * meanX - b * meanY
            guard c.isFinite, c > 0 else { return nil }
            let depth = 1 / c
            guard depth >= options.minimumDepthMeters, depth <= options.maximumDepthMeters else { return nil }
            var residuals: [Double] = []
            for sample in retained {
                let inverse = a * (sample.rayX - rayX) + b * (sample.rayY - rayY) + c
                guard inverse.isFinite, inverse > 0 else { return nil }
                residuals.append(sample.z - 1 / inverse)
            }
            let medianResidual = median(residuals)
            let mad = median(residuals.map { abs($0 - medianResidual) })
            let cutoff = max(0.002, 3.5 * 1.4826 * mad)
            let filtered = zip(retained, residuals).filter { abs($0.1 - medianResidual) <= cutoff }.map(\.0)
            if iteration < 2 && filtered.count < retained.count {
                retained = filtered
                continue
            }
            let rms = sqrt(residuals.reduce(0.0) { $0 + $1 * $1 } / n)
            let low = retained.map(\.z).min()!, high = retained.map(\.z).max()!
            guard rms <= options.maximumPlaneResidualMeters,
                  depth >= low - options.maximumPlaneResidualMeters,
                  depth <= high + options.maximumPlaneResidualMeters else { return nil }
            // Recheck spatial support after residual rejection, which can remove an entire side.
            guard isNearSupport(x: targetX, y: targetY, samples: retained) else { return nil }
            return .init(depth: depth, residual: rms, sampleCount: retained.count)
        }
        return nil
    }

    /// Permit only subpixel extension beyond the sample hull, needed at a garment's silhouette.
    private func isNearSupport(x: Double, y: Double, samples: [DepthSample]) -> Bool {
        let sorted = samples.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return false }
        func cross(_ o: DepthSample, _ a: DepthSample, _ b: DepthSample) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [DepthSample] = [], upper: [DepthSample] = []
        for sample in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower.last!, sample) <= 0 { lower.removeLast() }
            lower.append(sample)
        }
        for sample in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper.last!, sample) <= 0 { upper.removeLast() }
            upper.append(sample)
        }
        let hull = Array(lower.dropLast()) + Array(upper.dropLast())
        guard hull.count >= 3 else { return false }
        var inside = true
        var distanceSquared = Double.infinity
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let dx = b.x - a.x, dy = b.y - a.y
            if dx * (y - a.y) - dy * (x - a.x) < -1e-9 { inside = false }
            let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / (dx * dx + dy * dy)))
            distanceSquared = min(distanceSquared, square(x - a.x - t * dx) + square(y - a.y - t * dy))
        }
        return inside || distanceSquared <= 0.75 * 0.75
    }

    private func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position), upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    private func square<T: Numeric>(_ value: T) -> T { value * value }
}

/// Recursion-budget exhaustion is contextual and must remain non-cacheable
/// while it propagates through dependent points.
nonisolated private struct PointResolutionError: Error {
    var reason: MeasurementFailure
    var canCache = true
}

nonisolated private struct PointResolution {
    var landmark: ResolvedLandmark
    var uncertain: Bool
}

nonisolated private struct DepthSample {
    var x: Double
    var y: Double
    var rayX: Double
    var rayY: Double
    var z: Double
    var confidence: UInt8?
}

nonisolated private struct PlaneEstimate {
    var depth: Double
    var residual: Double
    var sampleCount: Int
}

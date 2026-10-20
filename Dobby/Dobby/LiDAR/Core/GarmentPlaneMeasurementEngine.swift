import Foundation

/// One accepted representative garment plane per frozen automatic capture.
/// Fitting failure never falls back to local/median endpoint sampling. A bad
/// endpoint or contour derivation affects only measurements that depend on it.
nonisolated struct GarmentPlaneMeasurementEngine {
    static let algorithmVersion = "garment-plane-neck-perpendicular-mask-1"
    private let options: MeasurementOptions

    init(options: MeasurementOptions = .init()) { self.options = options }

    func measure(frame: MeasurementFrame, landmarks: GarmentLandmarkSet,
                 definitions: [MeasurementDefinition]) -> GarmentMeasurementResult {
        let validator = LiDARMeasurementEngine(options: options)
        var globalFailure = validator.validate(frame: frame, landmarks: landmarks)
        var plane: GarmentPlane?
        if globalFailure == nil {
            if let mask = landmarks.mask {
                do {
                    plane = try GarmentPlaneGeometry.fit(frame: frame, mask: mask,
                        uprightOrientation: landmarks.recognitionDiagnostics?.selectedPoseOrientation ?? frame.orientation)
                } catch let failure as MeasurementFailure { globalFailure = failure }
                catch { globalFailure = .insufficientGarmentPlane }
            } else { globalFailure = .invalidMask }
        }
        let groupedPoints = Dictionary(grouping: landmarks.points, by: \.id)
        let groupedDefinitions = Dictionary(grouping: definitions, by: \.id)
        var resolved: [String: ResolvedLandmark] = [:]
        var failures: [String: MeasurementFailure] = [:]
        var uncertainIDs = Set<String>()

        func quality(_ position: Point3D, method: DepthSamplingMethod) -> PointQuality {
            let support = plane!.quality
            return .init(validSamples: support.inlierCount, candidateSamples: support.candidateCount,
                confidenceAvailable: true, depthSpreadMeters: 0, planeResidualMeters: nil, method: method,
                viewingAngleDegrees: GarmentPlaneGeometry.viewingAngleDegrees(at: position, plane: plane!),
                garmentPlaneQuality: support)
        }
        func sourceIDs(_ landmark: GarmentLandmark) -> [String]? {
            if let rule = landmark.contourRule { return rule.sourceLandmarkIDs }
            return landmarks.effectiveDerivedSourceIDs(for: landmark.id)
        }
        func resolve(_ id: String, visiting: inout Set<String>) -> Result<ResolvedLandmark, ResolutionError> {
            if let point = resolved[id] { return .success(point) }
            if let failure = failures[id] { return .failure(.init(reason: failure)) }
            guard !visiting.contains(id) else { failures[id] = .invalidDefinition; return .failure(.init(reason: .invalidDefinition)) }
            // Do not cache traversal-depth failure against an otherwise valid ID.
            guard visiting.count < 64 else { return .failure(.init(reason: .invalidDefinition, canCache: false)) }
            guard let candidates = groupedPoints[id], !candidates.isEmpty else {
                failures[id] = .missingLandmark; return .failure(.init(reason: .missingLandmark))
            }
            guard candidates.count == 1 else {
                failures[id] = .duplicateLandmark; return .failure(.init(reason: .duplicateLandmark))
            }
            let landmark = candidates[0]
            let resolution: Result<ResolvedLandmark, ResolutionError>
            if let sources = sourceIDs(landmark) {
                // Contour placeholders have no independent model prediction or
                // visibility. Resolve its actual model contributors first.
                if landmark.contourRule == nil,
                   let failure = validator.validateLandmark(landmark, origin: landmark.origin ?? landmarks.origin) {
                    resolution = .failure(.init(reason: failure))
                } else if sources.count < 2 || sources.count > 64 || sources.contains(where: \.isEmpty)
                    || Set(sources).count != sources.count || (landmark.contourRule != nil && landmark.derivedFrom != nil) {
                    resolution = .failure(.init(reason: .invalidDefinition))
                } else {
                    visiting.insert(id)
                    var contributors: [ResolvedLandmark] = [], firstFailure: ResolutionError?
                    for source in sources {
                        switch resolve(source, visiting: &visiting) {
                        case .success(let point): contributors.append(point)
                        case .failure(let error): if firstFailure == nil { firstFailure = error }
                        }
                    }
                    visiting.remove(id)
                    if let firstFailure { resolution = .failure(firstFailure) }
                    else {
                        do {
                            let position: Point3D, method: DepthSamplingMethod
                            if let rule = landmark.contourRule {
                                guard sources == rule.sourceLandmarkIDs, let mask = landmarks.mask,
                                      contributors.count == 3 else { throw MeasurementFailure.invalidDefinition }
                                switch rule {
                                case .neckPerpendicularMaskV1:
                                    guard id == "top_length_start" else { throw MeasurementFailure.invalidDefinition }
                                    position = try TopContourLength.start(neckLeft: contributors[0].position,
                                        neckRight: contributors[1].position, hem: contributors[2].position,
                                        mask: mask, frame: frame, plane: plane!)
                                case .waistParallelRightThighMaskV1:
                                    guard id == "thigh_right" else { throw MeasurementFailure.invalidDefinition }
                                    position = try BottomThighContour.right(waistLeft: contributors[0].position,
                                        waistRight: contributors[1].position, crotch: contributors[2].position,
                                        mask: mask, frame: frame)
                                }
                                method = .contourIntersection
                            } else {
                                position = GarmentPlaneGeometry.scale(contributors.reduce(.init(x: 0, y: 0, z: 0)) {
                                    GarmentPlaneGeometry.add($0, $1.position)
                                }, 1 / Double(contributors.count))
                                method = .spatialAverage
                            }
                            guard let imagePoint = GarmentPlaneGeometry.project(position, frame: frame) else { throw MeasurementFailure.outOfBounds }
                            resolution = .success(.init(id: id, imagePoint: imagePoint, position: position,
                                quality: quality(position, method: method), sourceLandmarkIDs: sources))
                        } catch let failure as MeasurementFailure { resolution = .failure(.init(reason: failure)) }
                        catch { resolution = .failure(.init(reason: .invalidDefinition)) }
                    }
                }
            } else if let failure = validator.validateLandmark(landmark, origin: landmark.origin ?? landmarks.origin) {
                resolution = .failure(.init(reason: failure))
            } else {
                do {
                    let position = try GarmentPlaneGeometry.intersection(point: landmark.point, frame: frame, plane: plane!)
                    resolution = .success(.init(id: id, imagePoint: landmark.point, position: position,
                                               quality: quality(position, method: .garmentPlane)))
                } catch let failure as MeasurementFailure { resolution = .failure(.init(reason: failure)) }
                catch { resolution = .failure(.init(reason: .insufficientGarmentPlane)) }
            }
            switch resolution {
            case .success(let point):
                resolved[id] = point
                if let sources = sourceIDs(landmark) {
                    if sources.contains(where: uncertainIDs.contains)
                        || (landmark.contourRule == nil && (landmark.origin ?? landmarks.origin) == .model && landmark.confidence == nil) {
                        uncertainIDs.insert(id)
                    }
                } else if (landmark.origin ?? landmarks.origin) == .model {
                    let assessment = landmarks.recognitionDiagnostics?.pointAssessments.first { $0.landmarkID == id }
                    if landmark.confidence == nil || landmarks.recognitionDiagnostics?.requiresReview == true
                        || assessment?.status == .outsideMask { uncertainIDs.insert(id) }
                }
            case .failure(let error): if error.canCache { failures[id] = error.reason }
            }
            return resolution
        }
        func pointFailures(_ ids: [String]) -> [LandmarkMeasurementFailure] {
            var pending = ids, visited = Set<String>(), result: [LandmarkMeasurementFailure] = [], cursor = 0
            while cursor < pending.count, visited.count < 256 {
                let id = pending[cursor]; cursor += 1
                guard visited.insert(id).inserted, resolved[id] == nil else { continue }
                if let failure = failures[id] { result.append(.init(landmarkID: id, reason: failure)) }
                if let candidates = groupedPoints[id], candidates.count == 1,
                   let sources = sourceIDs(candidates[0]), sources.count <= 64 { pending.append(contentsOf: sources) }
            }
            return result
        }

        let values = definitions.map { definition -> MeasurementValue in
            func unavailable(_ reason: MeasurementFailure, points: [ResolvedLandmark] = [],
                             failedIDs: [String]? = nil) -> MeasurementValue {
                .init(id: definition.id, title: definition.title, meters: nil, status: .unavailable,
                      failure: reason, points: points, pointFailures: failedIDs.map(pointFailures))
            }
            if let globalFailure { return unavailable(globalFailure) }
            guard !definition.id.isEmpty, groupedDefinitions[definition.id]?.count == 1,
                  (2...64).contains(definition.landmarkIDs.count),
                  definition.landmarkIDs.allSatisfy({ !$0.isEmpty }),
                  zip(definition.landmarkIDs, definition.landmarkIDs.dropFirst()).allSatisfy({ $0 != $1 })
            else { return unavailable(.invalidDefinition) }
            var points: [ResolvedLandmark] = [], failure: MeasurementFailure?
            for id in definition.landmarkIDs {
                var visiting = Set<String>()
                switch resolve(id, visiting: &visiting) {
                case .success(let point): points.append(point)
                case .failure(let error): if failure == nil { failure = error.reason }
                }
            }
            if let failure { return unavailable(failure, points: points, failedIDs: definition.landmarkIDs) }
            var uncertain = definition.landmarkIDs.contains(where: uncertainIDs.contains)
            // Retain explicit archive projection semantics; new canonical
            // definitions have no projection. No hidden total-length correction.
            if let projection = definition.projection {
                let axisIDs = projection.referenceAxisLandmarkIDs
                guard points.count == 2, axisIDs.count == 2, axisIDs.allSatisfy({ !$0.isEmpty }), axisIDs[0] != axisIDs[1]
                else { return unavailable(.invalidDefinition, points: points) }
                var axis: [ResolvedLandmark] = []
                for id in axisIDs {
                    var visiting = Set<String>()
                    switch resolve(id, visiting: &visiting) {
                    case .success(let point): axis.append(point)
                    case .failure(let error): if failure == nil { failure = error.reason }
                    }
                }
                if let failure { return unavailable(failure, points: points, failedIDs: definition.landmarkIDs + axisIDs) }
                uncertain = uncertain || axisIDs.contains(where: uncertainIDs.contains)
                let vector = GarmentPlaneGeometry.subtract(axis[1].position, axis[0].position)
                let magnitude = GarmentPlaneGeometry.length(vector)
                guard magnitude.isFinite, magnitude > 0.000001 else { return unavailable(.invalidDefinition, points: points) }
                let unit = GarmentPlaneGeometry.scale(vector, 1 / magnitude)
                let delta = GarmentPlaneGeometry.subtract(points[1].position, points[0].position)
                let position = GarmentPlaneGeometry.subtract(points[1].position,
                    GarmentPlaneGeometry.scale(unit, GarmentPlaneGeometry.dot(delta, unit)))
                guard let imagePoint = GarmentPlaneGeometry.project(position, frame: frame) else { return unavailable(.outOfBounds, points: points) }
                points[1] = .init(id: points[1].id, imagePoint: imagePoint, position: position,
                    quality: quality(position, method: .axisProjection),
                    sourceLandmarkIDs: Array(Set(definition.landmarkIDs + axisIDs)).sorted())
            }
            let meters = zip(points, points.dropFirst()).reduce(0.0) {
                $0 + GarmentPlaneGeometry.length(GarmentPlaneGeometry.subtract($1.0.position, $1.1.position))
            }
            guard meters.isFinite, meters > 0 else { return unavailable(.invalidDefinition, points: points) }
            return .init(id: definition.id, title: definition.title, meters: meters,
                         status: uncertain ? .uncertain : .valid, failure: nil, points: points)
        }
        return .init(sessionID: frame.sessionID, frameID: frame.frameID,
                     algorithmVersion: Self.algorithmVersion, source: frame.source, values: values)
    }

    private struct ResolutionError: Error {
        var reason: MeasurementFailure
        var canCache = true
    }
}

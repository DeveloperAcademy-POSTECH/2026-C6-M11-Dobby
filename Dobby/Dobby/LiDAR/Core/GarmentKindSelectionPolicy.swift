import Foundation

nonisolated enum GarmentKindEvidenceStatus: String, Codable, Sendable {
    case supported, rejected, uncertain
}

nonisolated enum GarmentKindEvidenceReason: String, Codable, Sendable {
    case invalidInput, unmatchedForeground, insufficientSemanticSupport
    case implausiblePose, solidTorso, pairedSleeveBranches, separatedLegs
    case unsupportedSilhouette, insufficientSilhouetteEvidence
}

/// Diagnostic evidence, not a class probability. Metrics have physical geometric
/// meanings and are never compared with another model's detection confidence.
nonisolated struct GarmentKindEvidence: Codable, Sendable {
    var kind: AutomaticGarmentKind
    var status: GarmentKindEvidenceStatus
    var reasons: [GarmentKindEvidenceReason]
    var metrics: [String: Double] = [:]

    static func unmatched(kind: AutomaticGarmentKind) -> Self {
        .init(kind: kind, status: .rejected, reasons: [.unmatchedForeground])
    }
}

nonisolated enum GarmentKindSelection: Codable, Sendable, Equatable {
    case selected(AutomaticGarmentKind)
    case ambiguous
    case noDetection
}

/// A conservative compatibility test for the two existing pose contracts. The
/// binary foreground and semantic points must come from the same raw RGB frame.
/// This neither moves landmarks nor modifies the mask used for depth measurement.
nonisolated enum GarmentKindSelectionPolicy {
    static func select(top: GarmentKindEvidence?, bottoms: GarmentKindEvidence?) -> GarmentKindSelection {
        guard top?.kind != .bottoms, bottoms?.kind != .top else { return .ambiguous }
        let supported = [top, bottoms].compactMap { $0 }.filter { $0.status == .supported }
        let uncertain = [top, bottoms].compactMap { $0 }.contains { $0.status == .uncertain }
        guard supported.count == 1, !uncertain else {
            return supported.isEmpty && !uncertain ? .noDetection : .ambiguous
        }
        return .selected(supported[0].kind)
    }

    static func evaluate(kind: AutomaticGarmentKind, points: [GarmentLandmark],
                         selection: GarmentMaskSelection, imageSize: PixelSize) -> GarmentKindEvidence {
        let mask = selection.mask
        guard imageSize.isValid, mask.size.isValid,
              mask.values.count <= 4_194_304,
              mask.values.count == mask.size.width * mask.size.height,
              mask.size.width * imageSize.height == mask.size.height * imageSize.width,
              mask.values.allSatisfy({ $0 <= 1 }),
              selection.matchedLandmarkCount >= 3,
              selection.observedLandmarkCount >= selection.matchedLandmarkCount,
              Set(points.map(\.id)).count == points.count else {
            return .init(kind: kind, status: .uncertain, reasons: [.invalidInput])
        }
        let expected = Set(kind == .top ? TopLandmarkSchema.expectedKeypoints : [
            "waist_left", "waist_right", "crotch", "hem_left_outer", "hem_left_inner",
            "hem_right_inner", "hem_right_outer"
        ])
        let direct = selection.validatedPoints(points).filter {
            $0.derivedFrom == nil && expected.contains($0.id) && $0.isVisible && $0.point.isValid
                && $0.confidence.map { $0.isFinite && $0 >= 0.5 && $0 <= 1 } == true
        }
        let anchors = Dictionary(uniqueKeysWithValues: direct.map { ($0.id, $0) })
        let metrics = ["associatedDirectPoints": Double(direct.count),
                       "strongDirectPoints": Double(direct.filter { ($0.confidence ?? 0) >= 0.7 }.count)]
        let sampler = MaskSampler(mask: mask)
        switch kind {
        case .top: return topEvidence(anchors: anchors, sampler: sampler, metrics: metrics)
        case .bottoms: return bottomEvidence(anchors: anchors, sampler: sampler, metrics: metrics)
        }
    }

    private static func topEvidence(anchors: [String: GarmentLandmark], sampler: MaskSampler,
                                    metrics: [String: Double]) -> GarmentKindEvidence {
        func result(_ status: GarmentKindEvidenceStatus, _ reasons: [GarmentKindEvidenceReason],
                    _ values: [String: Double] = [:]) -> GarmentKindEvidence {
            .init(kind: .top, status: status, reasons: reasons, metrics: metrics.merging(values) { _, new in new })
        }
        func strong(_ id: String) -> ImagePoint? {
            guard let value = anchors[id], (value.confidence ?? 0) >= 0.7 else { return nil }
            return value.point
        }
        // Match the existing partial-top subject policy. Missing sleeve/neck
        // points may invalidate dimensions, but do not require all eleven points
        // merely to establish that the independently observed body is a top.
        guard anchors.count >= 6, metrics["strongDirectPoints", default: 0] >= 4 else {
            // A sparse pose may describe isolated corners on an unrelated class.
            // It has no independent class witness and must not veto a supported
            // opposite candidate. A substantial but incomplete pose stays unknown.
            return result(.rejected, [.insufficientSemanticSupport])
        }
        let hemLeft = strong("hem_left"), hemRight = strong("hem_right")
        let lowerCenter: ImagePoint
        if let left = hemLeft, let right = hemRight { lowerCenter = midpoint(left, right) }
        else if let center = strong("hem_center"), hemLeft != nil || hemRight != nil { lowerCenter = center }
        else { return result(.uncertain, [.insufficientSemanticSupport]) }
        let upper: (ImagePoint, ImagePoint)?
        if let left = strong("armpit_left"), let right = strong("armpit_right") { upper = (left, right) }
        else if let left = strong("shoulder_left"), let right = strong("shoulder_right") { upper = (left, right) }
        else { upper = nil }
        guard let upper, let frame = PoseFrame(upper: upper, lowerCenter: lowerCenter, size: sampler.mask.size) else {
            return result(.uncertain, [.insufficientSemanticSupport])
        }
        guard frame.span >= 4, frame.length >= 4, frame.length / frame.span >= 0.2 else {
            return result(.rejected, [.implausiblePose])
        }
        let upperLeft = frame.project(upper.0), upperRight = frame.project(upper.1)
        // A missing hem endpoint supplies no measurement coordinate. Parallel
        // sampling edges only describe the classification region, centered on an
        // actual direct hem_center point, and never enter the landmark result.
        let lowerLeft = hemLeft.map(frame.project) ?? ImagePoint(x: upperLeft.x, y: 1)
        let lowerRight = hemRight.map(frame.project) ?? ImagePoint(x: upperRight.x, y: 1)
        guard upperLeft.x < upperRight.x, lowerLeft.x < lowerRight.x,
              min(lowerLeft.y, lowerRight.y) >= 0.55,
              abs(upperLeft.y - upperRight.y) <= 0.45,
              abs(lowerLeft.y - lowerRight.y) <= 0.45 else {
            return result(.rejected, [.implausiblePose])
        }
        let solid = sampler.frameCoverage(frame: frame, upperLeft: upperLeft, upperRight: upperRight,
                                          lowerLeft: lowerLeft, lowerRight: lowerRight)
        var leftBranches = 0, rightBranches = 0, bodySideGaps = 0
        for y in [-0.25, -0.05, 0.15, 0.35, 0.55] {
            let bodyLeft = upperLeft.x + max(0, y) * (lowerLeft.x - upperLeft.x)
            let bodyRight = upperRight.x + max(0, y) * (lowerRight.x - upperRight.x)
            for extensionWidth in [0.05, 0.12, 0.25, 0.4, 0.65] {
                if sampler.contains(frame.imagePoint(x: bodyLeft - extensionWidth, y: y)) { leftBranches += 1 }
                if sampler.contains(frame.imagePoint(x: bodyRight + extensionWidth, y: y)) { rightBranches += 1 }
            }
        }
        for y in [0.35, 0.55, 0.75] {
            let bodyLeft = upperLeft.x + y * (lowerLeft.x - upperLeft.x)
            let bodyRight = upperRight.x + y * (lowerRight.x - upperRight.x)
            for x in [bodyLeft - 0.12, bodyRight + 0.12] {
                if !sampler.contains(frame.imagePoint(x: x, y: y), radius: 0) { bodySideGaps += 1 }
            }
        }
        // When long sleeves lie alongside the body, the armpit gaps can close.
        // Independent paired sleeve lobes may instead extend below the body hem:
        // both outer regions stay foreground while the central body has ended.
        var lowerSleeveRows = 0
        for y in frame.sampleRows(from: 0.9, through: 1.5) {
            let bodyLeft = lowerLeft.x, bodyRight = lowerRight.x
            let left = [0.05, 0.12, 0.25, 0.4].contains {
                sampler.contains(frame.imagePoint(x: bodyLeft - $0, y: y), radius: 0)
            }
            let right = [0.05, 0.12, 0.25, 0.4].contains {
                sampler.contains(frame.imagePoint(x: bodyRight + $0, y: y), radius: 0)
            }
            let centerAbsent = [0.35, 0.5, 0.65].allSatisfy {
                !sampler.contains(frame.imagePoint(x: bodyLeft + $0 * (bodyRight - bodyLeft), y: y), radius: 0)
            }
            if left && right && centerAbsent { lowerSleeveRows += 1 }
        }
        let shapeMetrics = ["torsoForegroundFraction": solid,
                            "leftSleeveBranchSamples": Double(leftBranches),
                            "rightSleeveBranchSamples": Double(rightBranches),
                            "bodySideGapSamples": Double(bodySideGaps),
                            "lowerPairedSleeveRows": Double(lowerSleeveRows)]
        if solid < 0.6 || (bodySideGaps <= 1 && lowerSleeveRows < 2) {
            return result(.rejected, [.unsupportedSilhouette], shapeMetrics)
        }
        guard solid >= 0.9, leftBranches >= 2, rightBranches >= 2,
              bodySideGaps >= 4 || lowerSleeveRows >= 2 else {
            return result(.uncertain, [.insufficientSilhouetteEvidence], shapeMetrics)
        }
        return result(.supported, [.solidTorso, .pairedSleeveBranches], shapeMetrics)
    }

    private static func bottomEvidence(anchors: [String: GarmentLandmark], sampler: MaskSampler,
                                       metrics: [String: Double]) -> GarmentKindEvidence {
        func result(_ status: GarmentKindEvidenceStatus, _ reasons: [GarmentKindEvidenceReason],
                    _ values: [String: Double] = [:]) -> GarmentKindEvidence {
            .init(kind: .bottoms, status: status, reasons: reasons, metrics: metrics.merging(values) { _, new in new })
        }
        guard anchors.count >= 6, metrics["strongDirectPoints", default: 0] >= 4 else {
            return result(.rejected, [.insufficientSemanticSupport])
        }
        func strong(_ id: String) -> ImagePoint? {
            guard let value = anchors[id], (value.confidence ?? 0) >= 0.7 else { return nil }
            return value.point
        }
        let hems = ["hem_left_outer", "hem_left_inner", "hem_right_inner", "hem_right_outer"].compactMap { anchors[$0]?.point }
        guard let waistLeft = strong("waist_left"), let waistRight = strong("waist_right"),
              let crotch = strong("crotch"), hems.count >= 3 else {
            return result(.uncertain, [.insufficientSemanticSupport])
        }
        let hemMean = ImagePoint(x: hems.reduce(0) { $0 + $1.x } / Double(hems.count),
                                 y: hems.reduce(0) { $0 + $1.y } / Double(hems.count))
        guard let frame = PoseFrame(upper: (waistLeft, waistRight), lowerCenter: hemMean, size: sampler.mask.size) else {
            return result(.uncertain, [.insufficientSemanticSupport])
        }
        let waistL = frame.project(waistLeft), waistR = frame.project(waistRight), center = frame.project(crotch)
        let projectedHems = hems.map(frame.project)
        guard frame.span >= 4, frame.length >= 4, center.y > 0.05, center.y < 0.98,
              projectedHems.allSatisfy({ $0.y >= center.y + 0.02 && $0.y <= 1.6 }),
              abs(waistL.y - waistR.y) <= 0.45,
              center.x > waistL.x - 0.15, center.x < waistR.x + 0.15 else {
            return result(.rejected, [.implausiblePose])
        }
        if let a = anchors["hem_left_outer"], let b = anchors["hem_left_inner"],
           frame.project(a.point).x >= frame.project(b.point).x { return result(.rejected, [.implausiblePose]) }
        if let a = anchors["hem_left_inner"], let b = anchors["hem_right_inner"],
           frame.project(a.point).x >= frame.project(b.point).x { return result(.rejected, [.implausiblePose]) }
        if let a = anchors["hem_right_inner"], let b = anchors["hem_right_outer"],
           frame.project(a.point).x >= frame.project(b.point).x { return result(.rejected, [.implausiblePose]) }
        // Scan the actual mask below the direct crotch. Hem endpoints can be one
        // pixel outside the silhouette, and short legs can have a small notch.
        // A real background corridor between two foreground runs is necessary;
        // no missing endpoint is synthesized for measurements or classification.
        var separatedRows = 0, resolvedRows = 0, widestGapPixels = 0.0
        var resolvedGapCenters: [ImagePoint] = []
        for y in frame.sampleRows(from: center.y, through: 1.3) {
            let runs = sampler.runs(frame: frame, y: y, left: waistL.x - 0.45, right: waistR.x + 0.45)
            guard runs.count == 2 else { continue }
            let left = runs[0], right = runs[1]
            let gap = right.0 - left.1
            let corridorCenter = (right.0 + left.1) / 2
            guard left.1 < center.x + 0.25, right.0 > center.x - 0.25,
                  abs(corridorCenter - center.x) <= 0.25,
                  left.1 - left.0 >= 0.08, right.1 - right.0 >= 0.08,
                  gap * frame.span >= 1 else { continue }
            separatedRows += 1
            widestGapPixels = max(widestGapPixels, gap * frame.span)
            if gap * frame.span >= 2 {
                resolvedRows += 1
                resolvedGapCenters.append(frame.imagePoint(x: corridorCenter, y: y))
            }
        }
        // A hole within a skirt/rectangle also produces two foreground runs.
        // Certify two rows of this particular crotch corridor as background that
        // reaches the image exterior in the hem direction, beyond all observed
        // hem points. Exact mask pixels are read; neither mask nor points change.
        var exterior = ForwardBackgroundExit(mask: sampler.mask, frame: frame,
                                              hemY: projectedHems.map(\.y).max()!)
        var openRows = 0
        for center in resolvedGapCenters {
            if exterior.isOpen(center) { openRows += 1 }
            if openRows == 2 { break }
        }
        let shapeMetrics = ["separatedLegRows": Double(separatedRows),
                            "resolvedLegGapRows": Double(resolvedRows),
                            "widestLegGapPixels": widestGapPixels,
                            "exteriorLegGapRows": Double(openRows)]
        guard separatedRows >= 2, resolvedRows >= 2, openRows >= 2 else {
            return result(.rejected, [.unsupportedSilhouette], shapeMetrics)
        }
        return result(.supported, [.separatedLegs], shapeMetrics)
    }

    private static func midpoint(_ a: ImagePoint, _ b: ImagePoint) -> ImagePoint {
        .init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func intersection(_ a: ImagePoint, _ b: ImagePoint, y: Double) -> Double? {
        guard abs(b.y - a.y) > 0.000_001 else { return nil }
        return a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
    }

    private struct PoseFrame {
        let origin: ImagePoint, axis: ImagePoint, cross: ImagePoint
        let size: PixelSize
        let length: Double, span: Double

        init?(upper: (ImagePoint, ImagePoint), lower: (ImagePoint, ImagePoint), size: PixelSize) {
            self.init(upper: upper, lowerCenter: GarmentKindSelectionPolicy.midpoint(lower.0, lower.1), size: size)
        }

        init?(upper: (ImagePoint, ImagePoint), lowerCenter: ImagePoint, size: PixelSize) {
            let origin = Self.pixels(GarmentKindSelectionPolicy.midpoint(upper.0, upper.1), size: size)
            let end = Self.pixels(lowerCenter, size: size)
            let length = hypot(end.x - origin.x, end.y - origin.y)
            guard length.isFinite, length > 0 else { return nil }
            let axis = ImagePoint(x: (end.x - origin.x) / length, y: (end.y - origin.y) / length)
            var cross = ImagePoint(x: axis.y, y: -axis.x)
            let left = Self.pixels(upper.0, size: size), right = Self.pixels(upper.1, size: size)
            if (right.x - left.x) * cross.x + (right.y - left.y) * cross.y < 0 {
                cross.x = -cross.x; cross.y = -cross.y
            }
            let span = (right.x - left.x) * cross.x + (right.y - left.y) * cross.y
            guard span.isFinite, span > 0 else { return nil }
            self.origin = origin; self.axis = axis; self.cross = cross
            self.size = size; self.length = length; self.span = span
        }

        func project(_ point: ImagePoint) -> ImagePoint {
            let value = Self.pixels(point, size: size)
            return .init(x: ((value.x - origin.x) * cross.x + (value.y - origin.y) * cross.y) / span,
                         y: ((value.x - origin.x) * axis.x + (value.y - origin.y) * axis.y) / length)
        }

        func imagePoint(x: Double, y: Double) -> ImagePoint {
            .init(x: (origin.x + x * span * cross.x + y * length * axis.x) / Double(size.width),
                  y: (origin.y + x * span * cross.y + y * length * axis.y) / Double(size.height))
        }

        func sampleRows(from start: Double, through end: Double) -> [Double] {
            let count = min(512, max(2, Int(ceil((end - start) * length)) + 1))
            return (0..<count).map { start + Double($0) * (end - start) / Double(count - 1) }
        }

        private static func pixels(_ point: ImagePoint, size: PixelSize) -> ImagePoint {
            .init(x: point.x * Double(size.width), y: point.y * Double(size.height))
        }
    }

    private struct MaskSampler {
        let mask: GarmentMask
        func contains(_ point: ImagePoint, radius: Int = 1) -> Bool {
            guard point.isValid else { return false }
            let x = min(mask.size.width - 1, max(0, Int(point.x * Double(mask.size.width))))
            let y = min(mask.size.height - 1, max(0, Int(point.y * Double(mask.size.height))))
            for row in max(0, y - radius)...min(mask.size.height - 1, y + radius) {
                for column in max(0, x - radius)...min(mask.size.width - 1, x + radius) {
                    if mask.values[row * mask.size.width + column] == 1 { return true }
                }
            }
            return false
        }

        func frameCoverage(frame: PoseFrame, upperLeft: ImagePoint, upperRight: ImagePoint,
                           lowerLeft: ImagePoint, lowerRight: ImagePoint) -> Double {
            var matches = 0
            for y in [0.35, 0.65, 0.85] {
                let left = upperLeft.x + y * (lowerLeft.x - upperLeft.x)
                let right = upperRight.x + y * (lowerRight.x - upperRight.x)
                for fraction in [0.2, 0.35, 0.5, 0.65, 0.8] {
                    if contains(frame.imagePoint(x: left + fraction * (right - left), y: y)) { matches += 1 }
                }
            }
            return Double(matches) / 15
        }

        func runs(frame: PoseFrame, y: Double, left: Double, right: Double) -> [(Double, Double)] {
            // At most 512 rows × 512 columns, independent of full-resolution RGB.
            let count = min(512, max(2, Int(ceil((right - left) * frame.span)) + 1))
            let step = (right - left) / Double(count - 1)
            var runs: [(Double, Double)] = [], beginning: Double?
            for i in 0..<count {
                let x = left + Double(i) * step
                if contains(frame.imagePoint(x: x, y: y), radius: 0) {
                    if beginning == nil { beginning = x }
                } else if let start = beginning {
                    runs.append((start, x - step)); beginning = nil
                }
            }
            if let start = beginning { runs.append((start, right)) }
            return runs
        }
    }

    /// Directed exact-pixel search is confined to the candidate leg corridor.
    /// Strictly positive travel along the waist-to-hem axis prevents a closed
    /// cavity from escaping through the neckline or back toward the waistband.
    /// This conservative check may reject a gap requiring backward travel.
    private struct ForwardBackgroundExit {
        let mask: GarmentMask, frame: PoseFrame, hemY: Double
        let steps: [(x: Int, y: Int)]
        var state: [Int8]

        init(mask: GarmentMask, frame: PoseFrame, hemY: Double) {
            self.mask = mask; self.frame = frame; self.hemY = hemY
            let candidates = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
            steps = candidates.filter {
                Double($0.0) * frame.axis.x + Double($0.1) * frame.axis.y > 0.000_000_001
            }.sorted {
                let a = (Double($0.0) * frame.axis.x + Double($0.1) * frame.axis.y) / hypot(Double($0.0), Double($0.1))
                let b = (Double($1.0) * frame.axis.x + Double($1.1) * frame.axis.y) / hypot(Double($1.0), Double($1.1))
                return a > b
            }
            state = [Int8](repeating: 0, count: mask.values.count)
        }

        mutating func isOpen(_ point: ImagePoint) -> Bool {
            guard point.isValid else { return false }
            let x = min(mask.size.width - 1, Int(point.x * Double(mask.size.width)))
            let y = min(mask.size.height - 1, Int(point.y * Double(mask.size.height)))
            let beginning = y * mask.size.width + x
            guard mask.values[beginning] == 0 else { return false }
            if state[beginning] != 0 { return state[beginning] == 1 }
            var path: [(pixel: Int, next: Int)] = [(beginning, 0)]
            state[beginning] = 2
            while let current = path.last {
                guard current.next < steps.count else {
                    state[current.pixel] = -1; path.removeLast(); continue
                }
                path[path.count - 1].next += 1
                let step = steps[current.next]
                let sourceX = current.pixel % mask.size.width, sourceY = current.pixel / mask.size.width
                let nextX = sourceX + step.x, nextY = sourceY + step.y
                if nextX < 0 || nextX >= mask.size.width || nextY < 0 || nextY >= mask.size.height {
                    let edge = frame.project(.init(x: (Double(sourceX) + 0.5) / Double(mask.size.width),
                                                   y: (Double(sourceY) + 0.5) / Double(mask.size.height)))
                    if edge.y > hemY {
                        for entry in path { state[entry.pixel] = 1 }
                        return true
                    }
                    continue
                }
                let next = nextY * mask.size.width + nextX
                guard mask.values[next] == 0 else { continue }
                if state[next] == 1 {
                    for entry in path { state[entry.pixel] = 1 }
                    return true
                }
                guard state[next] == 0 else { continue }
                state[next] = 2; path.append((next, 0))
            }
            return false
        }
    }
}

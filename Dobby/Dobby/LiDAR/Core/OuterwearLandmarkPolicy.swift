import Foundation

nonisolated struct OuterwearLandmarkEvaluation: Sendable {
    var points: [GarmentLandmark]
    var selection: GarmentMaskSelection
    var diagnostics: GarmentRecognitionDiagnostics
    var requiresReview: Bool { diagnostics.requiresReview }
}

/// A separate contract for remote observations. It never manufactures detector
/// scores or changes the confidence gates used by the existing CoreML models.
nonisolated enum OuterwearLandmarkPolicy {
    static let totalLengthStartID = "top_length_start"
    static let frontLengthStartID = "front_length_start"

    static func evaluate(response: OuterwearLandmarkResponse, expectedRequestID: String,
                         imageSize: PixelSize, masks: [GarmentMask],
                         orientation: ImageOrientation) throws -> OuterwearLandmarkEvaluation {
        try response.validate(expectedRequestID: expectedRequestID)
        guard imageSize.isValid else { throw GarmentMaskAssociationError.invalidMask }
        var raw = try TopLandmarkSchema.expectedKeypoints.map {
            try landmark(id: $0, observation: response.points[$0]!, orientation: orientation)
        } + [try landmark(id: totalLengthStartID, observation: response.totalLengthStart, orientation: orientation)]
        if !response.isFrontOnly, let front = response.frontNeckSeamCenter {
            raw.append(try landmark(id: frontLengthStartID, observation: front, orientation: orientation))
        }
        let candidate = try singleMask(masks, imageSize: imageSize)
        let mask = candidate.mask
        func contains(_ point: ImagePoint) -> Bool {
            guard point.isValid else { return false }
            let x = Int(point.x * Double(mask.size.width)), y = Int(point.y * Double(mask.size.height))
            return mask.values[y * mask.size.width + x] == 1
        }
        let observed = raw.filter(\.isVisible)
        let associated = Set(observed.filter { contains($0.point) }.map(\.id))
        let bodyIDs: Set<String> = ["shoulder_left", "shoulder_right", "armpit_left", "armpit_right",
                                   "hem_left", "hem_center", "hem_right"]
        let body = observed.filter { associated.contains($0.id) && bodyIDs.contains($0.id)
            && response.points[$0.id]?.visibility != .estimated }
        guard body.count >= 3,
              let minX = body.map(\.point.x).min(), let maxX = body.map(\.point.x).max(),
              let minY = body.map(\.point.y).min(), let maxY = body.map(\.point.y).max(),
              maxX - minX >= 0.03, maxY - minY >= 0.03 else {
            throw OuterwearLandmarkError.unsupportedGeometry
        }
        try validateLayout(response: response)
        let estimatedIDs = Set(OuterwearComparisonGeometry.observations(response)
            .filter { $0.value.visibility == .estimated }.map(\.key))
        let acceptedEstimates = OuterwearCenterGapPolicy.accepted(response: response,
            mask: try GarmentMaskOrientation.uprightMask(fromOriginal: mask, orientation: orientation))
        var calculationResponse = response
        var calculationPoints = raw
        var calculationAssociated = associated.subtracting(estimatedIDs).union(acceptedEstimates)
        // Use the same bounded outline correction as the local pose models,
        // only after the original observations identify a supported garment.
        // Virtual gap centers must stay centered. The visible center hem keeps
        // its column-specific correction below, rather than snapping sideways
        // onto an opening, notch or another part of the silhouette.
        let snapped = try GarmentOutlineSnap.apply(points: raw.filter {
            !estimatedIDs.contains($0.id) && $0.id != "hem_center"
        }, mask: mask, imageSize: imageSize)
        var adjustments = snapped.adjustments
        for adjustment in adjustments {
            guard let index = calculationPoints.firstIndex(where: { $0.id == adjustment.landmarkID }) else { continue }
            calculationPoints[index].point = adjustment.adjustedPoint
            calculationAssociated.insert(adjustment.landmarkID)
            let upright = ImageCoordinateTransform.originalToDisplay(adjustment.adjustedPoint, orientation: orientation)
            switch adjustment.landmarkID {
            case totalLengthStartID:
                if response.isFrontOnly { calculationResponse.frontNeckSeamCenter?.point = upright }
                else { calculationResponse.backNeckSeamCenter.point = upright }
            case frontLengthStartID:
                calculationResponse.frontNeckSeamCenter?.point = upright
            default:
                calculationResponse.points[adjustment.landmarkID]?.point = upright
            }
        }
        if response.isFrontOnly, response.points["hem_center"]?.visibility == .visible,
           let original = response.points["hem_center"]?.point,
           let correction = OuterwearHemBoundaryRefinement.correction(response: response,
                mask: try GarmentMaskOrientation.uprightMask(fromOriginal: mask, orientation: orientation)),
           let index = calculationPoints.firstIndex(where: { $0.id == "hem_center" }) {
            let adjusted = correction.point
            let restored = ImageCoordinateTransform.displayToOriginal(adjusted, orientation: orientation)
            let originalRaw = calculationPoints[index].point
            calculationResponse.points["hem_center"]?.point = adjusted
            calculationPoints[index].point = restored
            calculationAssociated.insert("hem_center")
            let uprightHeight = orientation == .right || orientation == .left ? imageSize.width : imageSize.height
            adjustments.append(.init(landmarkID: "hem_center", originalPoint: originalRaw,
                adjustedPoint: restored, distancePixels: abs(adjusted.y - original.y) * Double(uprightHeight),
                limitPixels: correction.limitHeightFraction * Double(uprightHeight),
                method: OuterwearHemBoundaryRefinement.method))
        }
        let rejected = endpointRejections(response: calculationResponse, mask: mask,
            bounds: candidate.bounds, orientation: orientation, materialSupported: calculationAssociated)
        let usableIDs = calculationAssociated.subtracting(rejected)
        // Moving onto material cannot make an anatomically invalid endpoint
        // usable. Retain its original correction handle and record only moves
        // actually adopted as calculation inputs.
        adjustments.removeAll { rejected.contains($0.landmarkID) }
        // Assessments and rawPoints retain the AI observations; the explicit
        // adjustment record explains any different calculation endpoint.
        let assessments = raw.map { point in
            LandmarkMaskAssessment(landmarkID: point.id, status: !point.isVisible ? .notVisible
                : !associated.contains(point.id) ? .outsideMask
                : rejected.contains(point.id) ? .notVisible : .associated)
        }
        // Unavailable positions retain the original AI correction slots.
        let usable = calculationPoints.enumerated().map { index, point in
            var point = point
            point.isVisible = point.isVisible && usableIDs.contains(point.id)
            if !point.isVisible { point.point = raw[index].point }
            return point
        }
        let selection = GarmentMaskSelection(mask: mask, bounds: candidate.bounds,
            matchedLandmarkCount: usableIDs.count, observedLandmarkCount: observed.count,
            associatedLandmarkIDs: usableIDs, policy: .subject, pointAssessments: assessments)
        let evidence = GarmentKindEvidence(kind: .top, status: .supported, reasons: [.partialSilhouette],
            metrics: ["remoteVisiblePoints": Double(observed.count),
                      "remoteMaterialSupportedPoints": Double(associated.count),
                      "remoteRejectedEndpoints": Double(rejected.count),
                      "remoteBodyAnchors": Double(body.count)])
        var diagnostics = GarmentRecognitionDiagnostics(requestedOrientation: orientation,
            selectedPoseOrientation: orientation, associationPolicy: .subject, rawPoints: raw,
            pointAssessments: assessments,
            poseAttempts: [.init(orientation: orientation, rawPoints: raw, associationPolicy: .subject,
                                 pointAssessments: assessments)], kindEvidence: evidence)
        if !adjustments.isEmpty { diagnostics.automaticAdjustments = adjustments }
        let estimates = acceptedEstimates.subtracting(rejected).sorted().compactMap { id -> GarmentCenterEstimate? in
            guard let support = id == totalLengthStartID ? response.centerSupport?.frontNeckSeamCenter
                : response.centerSupport?.hemCenter else { return nil }
            return .init(landmarkID: id,
                point: ImageCoordinateTransform.displayToOriginal(support.midpoint, orientation: orientation),
                leftSupport: ImageCoordinateTransform.displayToOriginal(support.left, orientation: orientation),
                rightSupport: ImageCoordinateTransform.displayToOriginal(support.right, orientation: orientation))
        }
        if !estimates.isEmpty { diagnostics.centerEstimates = estimates }
        return .init(points: usable, selection: selection, diagnostics: diagnostics)
    }

    private static func landmark(id: String, observation: OuterwearLandmarkObservation,
                                 orientation: ImageOrientation) throws -> GarmentLandmark {
        guard let point = observation.point else {
            return .init(id: id, point: .init(x: 0.5, y: 0.5), confidence: nil, isVisible: false)
        }
        let original = ImageCoordinateTransform.displayToOriginal(point, orientation: orientation)
        // Reject a transformed exterior edge rather than clamp an invented point.
        guard original.isValid else { throw OuterwearLandmarkError.invalidCoordinate(id) }
        return .init(id: id, point: original, confidence: nil, isVisible: true)
    }

    private static func validateLayout(response: OuterwearLandmarkResponse) throws {
        func point(_ id: String) -> ImagePoint? { response.points[id]?.point }
        for pair in [("neck_left", "neck_right"), ("shoulder_left", "shoulder_right"),
                     ("armpit_left", "armpit_right"), ("hem_left", "hem_right")] {
            if let left = point(pair.0), let right = point(pair.1), left.x >= right.x {
                throw OuterwearLandmarkError.unsupportedGeometry
            }
        }
        let upper = [point("shoulder_left"), point("shoulder_right"),
                     point("armpit_left"), point("armpit_right")].compactMap { $0 }
        // A misplaced center endpoint must not reject the remaining dimensions.
        let hem = [point("hem_left"), point("hem_right")].compactMap { $0 }
        if !upper.isEmpty, !hem.isEmpty {
            let upperY = upper.reduce(0) { $0 + $1.y } / Double(upper.count)
            let hemY = hem.reduce(0) { $0 + $1.y } / Double(hem.count)
            guard hemY - upperY >= 0.03 else { throw OuterwearLandmarkError.unsupportedGeometry }
        }
    }

    /// These are rejection checks, not estimators of a replacement coordinate.
    /// Test in the uploaded upright image, sampling the very same mask after the
    /// inverse transform; global mask extrema can belong to a lower sleeve/tie.
    private static func endpointRejections(response: OuterwearLandmarkResponse, mask: GarmentMask,
        bounds: NormalizedRect, orientation: ImageOrientation, materialSupported: Set<String>) -> Set<String> {
        var rejected = Set<String>()
        let corners = [ImagePoint(x: bounds.x, y: bounds.y),
                       .init(x: bounds.x + bounds.width, y: bounds.y),
                       .init(x: bounds.x, y: bounds.y + bounds.height),
                       .init(x: bounds.x + bounds.width, y: bounds.y + bounds.height)]
            .map { ImageCoordinateTransform.originalToDisplay($0, orientation: orientation) }
        let garmentWidth = (corners.map(\.x).max()! - corners.map(\.x).min()!)
        let garmentHeight = (corners.map(\.y).max()! - corners.map(\.y).min()!)
        let uprightWidth = orientation == .right || orientation == .left ? mask.size.height : mask.size.width
        let uprightHeight = orientation == .right || orientation == .left ? mask.size.width : mask.size.height
        func point(_ id: String) -> ImagePoint? {
            materialSupported.contains(id) ? response.points[id]?.point : nil
        }
        let upper = [point("shoulder_left"), point("shoulder_right"),
                     point("armpit_left"), point("armpit_right")].compactMap { $0 }
        if let hem = point("hem_center") {
            // Allow a few segmentation pixels inside the edge. A continuous run
            // of body material substantially below this location is evidence
            // that it is an interior point, even when side hems look plausible.
            let tolerance = max(3, Int(ceil(garmentHeight * Double(uprightHeight) * 0.08)))
            if hasDownwardMaterial(hem, rows: tolerance, mask: mask, orientation: orientation,
                                   uprightWidth: uprightWidth, uprightHeight: uprightHeight)
                || upper.map(\.y).max().map({ hem.y <= $0 }) == true
                || point("hem_left").map({ hem.x < $0.x }) == true
                || point("hem_right").map({ hem.x > $0.x }) == true {
                rejected.insert("hem_center")
            }
        }

        func rejectImplausibleSeam(_ observation: OuterwearLandmarkObservation, id: String) {
            guard let seam = observation.point, materialSupported.contains(id) else { return }
            let neck = [point("neck_left"), point("neck_right")].compactMap { $0 }
            let shoulders = [point("shoulder_left"), point("shoulder_right")].compactMap { $0 }
            let anchors = neck + shoulders
            let marginX = max(3 / Double(uprightWidth), garmentWidth * 0.08)
            let marginY = max(3 / Double(uprightHeight), garmentHeight * 0.10)
            // One surviving side-neck point is not a left/right interval for
            // the center seam. Use both shoulders when the neck pair is partial.
            let horizontalAnchors = neck.count == 2 ? neck : shoulders
            // A V-neck attachment can lie below the side-neck/shoulder band.
            // Only a visible, material-supported armpit supplies this front-only
            // upper-body bound; its row itself is already too low for a neck seam.
            let frontArmpitY = (id == frontLengthStartID || response.isFrontOnly)
                ? [point("armpit_left"), point("armpit_right")].compactMap { $0?.y }.min() : nil
            let hems = [point("hem_left"), rejected.contains("hem_center") ? nil : point("hem_center"),
                        point("hem_right")].compactMap { $0 }
            let belowNeckRegion = frontArmpitY.map { seam.y >= $0 }
                ?? anchors.map(\.y).max().map { seam.y > $0 + marginY } ?? false
            if anchors.isEmpty || horizontalAnchors.count != 2
                || anchors.map(\.y).min().map({ seam.y < $0 - marginY }) == true
                || belowNeckRegion
                || horizontalAnchors.map(\.x).min().map({ seam.x < $0 - marginX }) == true
                || horizontalAnchors.map(\.x).max().map({ seam.x > $0 + marginX }) == true
                || hems.map(\.y).min().map({ seam.y >= $0 - marginY }) == true {
                rejected.insert(id)
            }
        }
        // Keep both original observations in diagnostics, but never pair a hem
        // seen on one face with the opposite face's neckline or inferred seam.
        if response.isFrontOnly {
            if response.view == .front {
                rejectImplausibleSeam(response.totalLengthStart, id: totalLengthStartID)
            } else { rejected.insert(totalLengthStartID) }
            return rejected
        }
        if response.view == .back {
            rejectImplausibleSeam(response.backNeckSeamCenter, id: totalLengthStartID)
        } else {
            rejected.insert(totalLengthStartID)
        }
        if let front = response.frontNeckSeamCenter {
            if response.view == .front {
                rejectImplausibleSeam(front, id: frontLengthStartID)
            } else {
                rejected.insert(frontLengthStartID)
            }
        }
        return rejected
    }

    private static func hasDownwardMaterial(_ point: ImagePoint, rows: Int, mask: GarmentMask,
        orientation: ImageOrientation, uprightWidth: Int, uprightHeight: Int) -> Bool {
        let startY = Int(point.y * Double(uprightHeight))
        // Reaching the image border without background is not an observed hem.
        guard startY + rows < uprightHeight else { return true }
        let centerX = Int(point.x * Double(uprightWidth))
        for row in 1...rows {
            var supported = 0, samples = 0
            for column in max(0, centerX - 1)...min(uprightWidth - 1, centerX + 1) {
                let sample = ImagePoint(x: (Double(column) + 0.5) / Double(uprightWidth),
                                        y: (Double(startY + row) + 0.5) / Double(uprightHeight))
                let raw = ImageCoordinateTransform.displayToOriginal(sample, orientation: orientation)
                guard raw.isValid else { continue }
                samples += 1
                let x = Int(raw.x * Double(mask.size.width)), y = Int(raw.y * Double(mask.size.height))
                supported += mask.values[y * mask.size.width + x] == 1 ? 1 : 0
            }
            // The first local gap ends this connected run. Never jump to a
            // distant garment part or the global lowest foreground pixel.
            if samples == 0 || supported * 2 <= samples { return false }
        }
        return true
    }

    /// Shared by crop preparation and response validation: never choose an
    /// arbitrary foreground just to make a remote request possible.
    static func singleMask(_ masks: [GarmentMask], imageSize: PixelSize) throws
        -> (mask: GarmentMask, bounds: NormalizedRect) {
        var candidates: [(GarmentMask, NormalizedRect)] = []
        for mask in masks {
            guard mask.size.isValid, mask.values.count <= 4_194_304,
                  mask.values.count == mask.size.width * mask.size.height,
                  mask.size.width * imageSize.height == mask.size.height * imageSize.width,
                  mask.values.allSatisfy({ $0 <= 1 }) else { throw GarmentMaskAssociationError.invalidMask }
            var count = 0, minX = mask.size.width, minY = mask.size.height, maxX = -1, maxY = -1
            for index in mask.values.indices where mask.values[index] == 1 {
                count += 1
                let x = index % mask.size.width, y = index / mask.size.width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            guard Double(count) / Double(mask.values.count) >= 0.02 else { continue }
            candidates.append((mask, .init(x: Double(minX) / Double(mask.size.width),
                y: Double(minY) / Double(mask.size.height),
                width: Double(maxX - minX + 1) / Double(mask.size.width),
                height: Double(maxY - minY + 1) / Double(mask.size.height))))
        }
        guard !candidates.isEmpty else { throw GarmentMaskAssociationError.noForeground }
        guard candidates.count == 1 else { throw GarmentMaskAssociationError.multipleForegrounds }
        return candidates[0]
    }
}

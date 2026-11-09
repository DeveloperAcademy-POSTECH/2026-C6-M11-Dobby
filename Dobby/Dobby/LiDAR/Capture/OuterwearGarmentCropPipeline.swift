import CoreGraphics
import Foundation

/// Production measurement uses experiment B's padded garment crop. Only the
/// remote input is cropped: output points and masks remain in raw RGB/depth space.
nonisolated enum OuterwearGarmentCropPipeline {
    static func recognize(_ image: CGImage, orientation: ImageOrientation, category: String,
                          requestID: UUID = UUID(), provider: any OuterwearLandmarkProviding,
                          masks: @Sendable (CGImage) throws -> [GarmentMask],
                          usesSideNeckLength: Bool = false,
                          localNeck: (any LocalNeckLandmarkProviding)? = nil) async throws
        -> GarmentForegroundRecognition {
        try Task.checkCancellation()
        let sourceSize = PixelSize(width: image.width, height: image.height)
        let quarterTurn = orientation == .right || orientation == .left
        let uprightSize = PixelSize(width: quarterTurn ? image.height : image.width,
                                    height: quarterTurn ? image.width : image.height)
        guard let upright = OuterwearLandmarkImageEncoder.uprightImage(image, orientation: orientation,
            width: uprightSize.width, height: uprightSize.height) else {
            throw OuterwearLandmarkClientError.invalidImage
        }
        // Segment this same frozen, upright raster once, before any AI upload.
        let candidate = try OuterwearLandmarkPolicy.singleMask(masks(upright), imageSize: uprightSize)
        try Task.checkCancellation()
        let crop = OuterwearComparisonCrop(region: .garment,
            rect: try OuterwearComparisonGeometry.aligned(
                OuterwearComparisonGeometry.padded(candidate.bounds), size: uprightSize))
        let raster = try OuterwearLandmarkImageEncoder.croppedImage(upright, rect: crop.rect)
        let originalMask = try GarmentMaskOrientation.originalMask(fromUpright: candidate.mask,
                                                                  orientation: orientation)
        try Task.checkCancellation()
        let local = try await provider.recognize(image: raster, orientation: .up,
                                                category: category, requestID: requestID)
        try Task.checkCancellation()
        var response = try OuterwearComparisonGeometry.restoring(local, crops: [crop])
        // First crop -> full upright, then the policy inverts rotation exactly
        // once. Depth, intrinsics, display photo and point IDs stay unchanged.
        var evaluation = try OuterwearLandmarkPolicy.evaluate(response: response,
            expectedRequestID: requestID.uuidString, imageSize: sourceSize,
            masks: [originalMask], orientation: orientation)
        var refinement: OuterwearCenterRefinementDiagnostics?
        var requests = 1
        let missingCenters = ["top_length_start", "hem_center"].filter { id in
            !evaluation.points.contains { $0.id == id && $0.isVisible }
        }
        // Every missing total endpoint gets the same bounded two-center pass.
        // First-pass latency and detection of an opening do not gate recovery.
        if !usesSideNeckLength, response.allowsCenterEstimates, !missingCenters.isEmpty,
           let refiner = provider as? any OuterwearCenterRefining {
            do {
                let crops = try OuterwearComparisonGeometry.refinementCrops(response: response,
                    bounds: candidate.bounds, size: uprightSize).filter { $0.region == .upper || $0.region == .hem }
                refinement = .init(crops: crops, localResponse: nil, adoptedLandmarkIDs: [])
                requests += 1
                let detailID = UUID()
                let detail = try await refiner.refineCenters(image: upright, context: crop.rect,
                    crops: crops, category: category, requestID: detailID)
                refinement?.localResponse = try detail.landmarkResponse(expectedRequestID: detailID.uuidString)
                let restored = try detail.restoring(crops: crops).landmarkResponse(expectedRequestID: detailID.uuidString)
                // Only same-contract, same-face observations can supplement B.
                if restored.modelVersion == response.modelVersion, restored.view == response.view {
                    for id in missingCenters {
                        var proposed = response
                        if id == "top_length_start" {
                            proposed.frontNeckSeamCenter = restored.frontNeckSeamCenter
                            proposed.centerSupport?.frontNeckSeamCenter = restored.centerSupport?.frontNeckSeamCenter
                        } else {
                            proposed.points[id] = restored.points[id]
                            proposed.centerSupport?.hemCenter = restored.centerSupport?.hemCenter
                        }
                        let checked = try OuterwearLandmarkPolicy.evaluate(response: proposed,
                            expectedRequestID: requestID.uuidString, imageSize: sourceSize,
                            masks: [originalMask], orientation: orientation)
                        if checked.points.contains(where: { $0.id == id && $0.isVisible }) {
                            response = proposed; evaluation = checked
                            refinement?.adoptedLandmarkIDs.append(id)
                        }
                    }
                }
            } catch {
                try Task.checkCancellation()
                // Keep successful first-pass measurements if optional detail
                // service is unavailable. Never persist raw upstream errors.
                refinement?.failure = "detail_unavailable"
            }
        }
        var neckRefinement: OuterwearNeckRefinementDiagnostics?
        let usesLocalNeck = localNeck != nil && usesSideNeckLength
            && response.modelVersion == GarmentLandmarkModelContract.lunaGapLengthVersion
            && response.view == .front && GarmentLandmarkSourceRoutingPolicy.outerwearCategories.contains(category)
        var localNeckDiagnostics: LocalNeckLandmarkDiagnostics?
        if usesLocalNeck, let localNeck {
            localNeckDiagnostics = .init(inputRect: crop.rect)
            do {
                let predictions = try await localNeck.neckPoints(in: raster)
                try Task.checkCancellation()
                guard Set(predictions.keys) == Set(LocalNeckLandmarks.ids),
                      predictions.values.allSatisfy(\.isValid) else { throw LocalNeckLandmarkError.invalidOutput }
                var proposed = response
                for id in LocalNeckLandmarks.ids {
                    let point = predictions[id]!
                    let restored = ImagePoint(x: crop.rect.x + point.x * crop.rect.width,
                        y: crop.rect.y + point.y * crop.rect.height)
                    localNeckDiagnostics?.predictedPoints[id] = restored
                    // No calibrated confidence is invented for the pilot. The
                    // existing estimate/mask policy must accept both necks.
                    proposed.points[id] = .init(point: restored, visibility: .estimated)
                }
                let checked = try OuterwearLandmarkPolicy.evaluate(response: proposed,
                    expectedRequestID: requestID.uuidString, imageSize: sourceSize,
                    masks: [originalMask], orientation: orientation, allowingNeckEstimates: true)
                if LocalNeckLandmarks.ids.allSatisfy({ id in checked.points.contains { $0.id == id && $0.isVisible } }) {
                    response = proposed; evaluation = checked
                    localNeckDiagnostics?.adoptedLandmarkIDs = LocalNeckLandmarks.ids
                } else { localNeckDiagnostics?.failure = "point_rejected" }
            } catch {
                try Task.checkCancellation()
                // Keep the first Luna observations if local inference is not
                // usable. Do not restart the three remote neck refinements.
                localNeckDiagnostics?.failure = "local_neck_unavailable"
            }
        }
        if !usesLocalNeck, usesSideNeckLength, response.allowsCenterEstimates, response.view == .front,
           let refiner = provider as? any OuterwearNeckRefining {
            do {
                // Keep the whole neckline and shoulder context, even if both necks
                // were missing or a coarse collar-tip prediction was incorrect.
                let neckCrop = try OuterwearComparisonGeometry.neckRefinementCrop(
                    response: response, bounds: candidate.bounds, size: uprightSize)
                neckRefinement = .init(crop: neckCrop)
                requests += 1
                let detailID = UUID()
                let detail = try await refiner.refineNeck(image: upright, context: crop.rect,
                    crop: neckCrop, category: category, requestID: detailID)
                try Task.checkCancellation()
                try detail.validate(expectedRequestID: detailID.uuidString)
                neckRefinement?.localResponse = detail
                if detail.modelVersion == response.modelVersion, detail.view == response.view {
                    for id in ["neck_left", "neck_right"] {
                        guard var observation = detail.points[id], let point = observation.point else { continue }
                        let rect = neckCrop.rect
                        observation.point = .init(x: rect.x + point.x * rect.width, y: rect.y + point.y * rect.height)
                        var proposed = response
                        proposed.points[id] = observation
                        guard let checked = try? OuterwearLandmarkPolicy.evaluate(response: proposed,
                            expectedRequestID: requestID.uuidString, imageSize: sourceSize,
                            masks: [originalMask], orientation: orientation, allowingNeckEstimates: true) else { continue }
                        if checked.points.contains(where: { $0.id == id && $0.isVisible }) {
                            response = proposed; evaluation = checked
                            neckRefinement?.adoptedLandmarkIDs.append(id)
                        }
                    }
                }
            } catch {
                try Task.checkCancellation()
                neckRefinement?.failure = "detail_unavailable"
            }
        }
        var sideRefinements: [OuterwearNeckRefinementDiagnostics]?
        if !usesLocalNeck, usesSideNeckLength, response.allowsCenterEstimates, response.view == .front,
           let refiner = provider as? any OuterwearNeckSideRefining {
            sideRefinements = []
            // Freeze both seeds before adopting either result. This keeps the
            // right crop independent of the left request's output and timing.
            let seeds = response
            for side in OuterwearNeckSide.allCases {
                try Task.checkCancellation()
                guard let localCrop = try OuterwearComparisonGeometry.neckSideCrop(
                    side: side, response: seeds, size: uprightSize) else { continue }
                var diagnostic = OuterwearNeckRefinementDiagnostics(crop: localCrop,
                    targetLandmarkID: side.landmarkID)
                do {
                    requests += 1
                    let detailID = UUID()
                    let detail = try await refiner.refineNeckSide(image: upright,
                        context: crop.rect, crop: localCrop, side: side,
                        category: category, requestID: detailID)
                    try Task.checkCancellation()
                    try detail.validate(expectedRequestID: detailID.uuidString)
                    diagnostic.localResponse = detail
                    if detail.modelVersion == response.modelVersion, detail.view == response.view,
                       !detail.points.contains(where: { $0.key != side.landmarkID && $0.value.point != nil }),
                       var observation = detail.points[side.landmarkID], let point = observation.point {
                        let rect = localCrop.rect
                        observation.point = .init(x: rect.x + point.x * rect.width,
                                                  y: rect.y + point.y * rect.height)
                        var proposed = response
                        proposed.points[side.landmarkID] = observation
                        if let checked = try? OuterwearLandmarkPolicy.evaluate(response: proposed,
                            expectedRequestID: requestID.uuidString, imageSize: sourceSize,
                            masks: [originalMask], orientation: orientation, allowingNeckEstimates: true),
                           checked.points.contains(where: { $0.id == side.landmarkID && $0.isVisible }) {
                            response = proposed; evaluation = checked
                            diagnostic.adoptedLandmarkIDs = [side.landmarkID]
                        } else { diagnostic.failure = "point_rejected" }
                    } else { diagnostic.failure = "point_unavailable" }
                } catch {
                    try Task.checkCancellation()
                    // A timeout/null/invalid response never removes a prior point.
                    diagnostic.failure = "detail_unavailable"
                }
                sideRefinements?.append(diagnostic)
            }
        }
        evaluation.diagnostics.remoteNeckRefinement = neckRefinement
        evaluation.diagnostics.localNeckLandmarks = localNeckDiagnostics
        evaluation.diagnostics.remoteNeckSideRefinements = sideRefinements
        evaluation.diagnostics.remoteCenterRefinement = refinement
        evaluation.diagnostics.remoteModel = response.model
        evaluation.diagnostics.remoteSchemaVersion = response.schemaVersion
        evaluation.diagnostics.remoteView = response.view.rawValue
        evaluation.diagnostics.remoteNeckStyle = response.neckStyle.rawValue
        evaluation.diagnostics.totalLengthConvention = response.allowsCenterEstimates ? GarmentLandmarkModelContract.frontGapConvention :
            response.isFrontOnly || (GarmentLandmarkModelContract.isViewLengthOuterwear(version: response.modelVersion, kind: .top) && response.view == .front)
                ? GarmentLandmarkModelContract.frontNeckSeamConvention : GarmentLandmarkModelContract.backNeckSeamConvention
        evaluation.diagnostics.remoteGarmentCrop = .init(sourceSize: sourceSize, uprightSize: uprightSize,
            rect: crop.rect, rasterSize: .init(width: raster.width, height: raster.height), localResponse: local)
        if usesSideNeckLength, response.modelVersion == GarmentLandmarkModelContract.lunaGapLengthVersion {
            evaluation.diagnostics.totalLengthConvention = GarmentLandmarkModelContract.sideNeckConvention
            evaluation.points = TopSideNeckLength.calculationPoints(evaluation.points)
        }
        return .init(recognition: .init(points: evaluation.points, detectionConfidence: nil,
            modelVersion: response.modelVersion, garmentKind: .top, diagnostics: evaluation.diagnostics),
            selection: evaluation.selection, poseRequests: requests, foregroundRequests: 1)
    }
}

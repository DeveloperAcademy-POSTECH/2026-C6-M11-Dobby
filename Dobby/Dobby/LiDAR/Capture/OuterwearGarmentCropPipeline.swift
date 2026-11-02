import CoreGraphics
import Foundation

/// Production measurement uses experiment B's padded garment crop. Only the
/// remote input is cropped: output points and masks remain in raw RGB/depth space.
nonisolated enum OuterwearGarmentCropPipeline {
    static func recognize(_ image: CGImage, orientation: ImageOrientation, category: String,
                          requestID: UUID = UUID(), provider: any OuterwearLandmarkProviding,
                          masks: @Sendable (CGImage) throws -> [GarmentMask]) async throws
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
        if response.allowsCenterEstimates, !missingCenters.isEmpty,
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
        return .init(recognition: .init(points: evaluation.points, detectionConfidence: nil,
            modelVersion: response.modelVersion, garmentKind: .top, diagnostics: evaluation.diagnostics),
            selection: evaluation.selection, poseRequests: requests, foregroundRequests: 1)
    }
}

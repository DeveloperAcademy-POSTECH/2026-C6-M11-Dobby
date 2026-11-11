import Foundation

/// Evidence from one frozen RGB image. These candidates never replace the
/// calculation inputs or certify physical point accuracy.
nonisolated struct GarmentPoseValidationAttempt: Codable, Sendable {
    var orientation: ImageOrientation
    var rawPoints: [GarmentLandmark]? = nil
    var associationPolicy: GarmentMaskAssociationPolicy? = nil
    var pointAssessments: [LandmarkMaskAssessment]? = nil
    var failure: String? = nil
}

nonisolated struct GarmentRecognitionDiagnostics: Codable, Sendable {
    var version: String = "garment-validation-2"
    var requestedOrientation: ImageOrientation
    var selectedPoseOrientation: ImageOrientation
    var associationPolicy: GarmentMaskAssociationPolicy
    var rawPoints: [GarmentLandmark]
    var pointAssessments: [LandmarkMaskAssessment]
    var poseAttempts: [GarmentPoseValidationAttempt]
    var kindEvidence: GarmentKindEvidence? = nil
    var classifiedCategory: String? = nil
    var classifierConfidence: Double? = nil
    var classifierScores: [GarmentClassificationScore]? = nil
    /// Preserve the first prediction for old archives. New captures record all
    /// verification passes in orientationResolution; selectedPoseOrientation is
    /// its final transform, inverted into raw RGB exactly once.
    var orientationPrediction: GarmentOrientationPrediction? = nil
    var orientationResolution: GarmentOrientationResolution? = nil
    var orientationModelVersion: String? = nil
    var automaticAdjustments: [GarmentAutomaticLandmarkAdjustment]? = nil
    /// Remote identity and the physical length convention travel with saved
    /// observations. Nil preserves decoding of existing CoreML archives.
    var remoteModel: String? = nil
    var remoteSchemaVersion: String? = nil
    var remoteView: String? = nil
    var remoteNeckStyle: String? = nil
    var totalLengthConvention: String? = nil
    /// Nil for pre-crop archives and CoreML. Retain the local AI observations
    /// separately from rawPoints, which always refer to the original RGB/depth.
    var remoteGarmentCrop: OuterwearGarmentCropDiagnostics? = nil
    /// Accepted virtual centers and their observed supports in raw RGB space.
    var centerEstimates: [GarmentCenterEstimate]? = nil
    var remoteCenterRefinement: OuterwearCenterRefinementDiagnostics? = nil
    var remoteNeckRefinement: OuterwearNeckRefinementDiagnostics? = nil
    /// Optional for archives created before independent left/right refinement.
    var remoteNeckSideRefinements: [OuterwearNeckRefinementDiagnostics]? = nil
    /// Separate local provenance for hybrid Luna body + on-device neck captures.
    var localNeckLandmarks: LocalNeckLandmarkDiagnostics? = nil

    /// Provider uncertainty, silhouette rejection and actual occlusion are
    /// different failures even though none is currently a usable endpoint.
    func remoteUnavailableReason(for id: String) -> MeasurementFailureReason? {
        guard remoteModel != nil || remoteGarmentCrop != nil else { return nil }
        if rawPoints.first(where: { $0.id == id })?.isVisible == true {
            return pointAssessments.first(where: { $0.landmarkID == id })?.status == .outsideMask
                ? .landmarkOutsideGarment : .landmarkGeometryRejected
        }
        if remoteNeckRefinement?.localResponse?.points[id] != nil,
           remoteNeckRefinement?.localResponse?.points[id]?.visibility == .uncertain { return .landmarkUncertain }
        if let response = remoteGarmentCrop?.localResponse {
            let observation = id == "top_length_start" ? response.totalLengthStart : response.points[id]
            if observation?.visibility == .uncertain { return .landmarkUncertain }
        }
        return nil
    }

    /// Subject identification can succeed without every boundary point fitting
    /// an independent silhouette. Retain the result, but do not call it precise.
    var requiresReview: Bool {
        associationPolicy == .subject || kindEvidence?.reasons.contains(.partialSilhouette) == true
    }
}

nonisolated struct OuterwearCenterRefinementDiagnostics: Codable, Sendable {
    var crops: [OuterwearComparisonCrop]
    var localResponse: OuterwearLandmarkResponse?
    var adoptedLandmarkIDs: [String]
    var failure: String? = nil
}

nonisolated struct OuterwearGarmentCropDiagnostics: Codable, Sendable {
    var sourceSize: PixelSize
    var uprightSize: PixelSize
    /// Pixel-aligned, normalized in the full upright image (before cropping).
    var rect: NormalizedRect
    /// Full-resolution crop before the network encoder's bounded resize.
    var rasterSize: PixelSize
    var localResponse: OuterwearLandmarkResponse
}

/// A failed physical contributor is retained independently of the photo marker.
/// Only final failures are exposed; successful recovery clears initial failures.
nonisolated struct LandmarkMeasurementFailure: Codable, Sendable, Equatable {
    var landmarkID: String
    var reason: MeasurementFailure
    var context: MeasurementFailureContext? = nil
}

nonisolated struct OuterwearNeckRefinementDiagnostics: Codable, Sendable {
    var crop: OuterwearComparisonCrop
    var localResponse: OuterwearNeckRefinementResponse?
    var adoptedLandmarkIDs: [String] = []
    var failure: String? = nil
    var targetLandmarkID: String? = nil
}

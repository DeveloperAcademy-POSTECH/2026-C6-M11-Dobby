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
    var version: String = "garment-validation-1"
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

    /// Subject identification can succeed without every boundary point fitting
    /// an independent silhouette. Retain the result, but do not call it precise.
    var requiresReview: Bool {
        associationPolicy == .subject || kindEvidence?.reasons.contains(.partialSilhouette) == true
    }
}

/// A failed physical contributor is retained independently of the photo marker.
/// Only final failures are exposed; successful recovery clears initial failures.
nonisolated struct LandmarkMeasurementFailure: Codable, Sendable, Equatable {
    var landmarkID: String
    var reason: MeasurementFailure
}

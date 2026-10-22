import Foundation

/// Adapter-specific reasons cross into Core without making Core import ARKit,
/// Core ML or matching translated error descriptions.
extension ARKitCaptureError: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? {
        switch self {
        case .unsupportedDevice: .cameraUnavailable
        case .cameraPermissionDenied: .cameraPermissionDenied
        case .sessionNotRunning: .cameraNotReady
        case .captureInProgress: .captureBusy
        case .invalidDepth: .invalidCaptureDepth
        case .invalidImage: .invalidCaptureImage
        case .invalidCalibration: .invalidCaptureCalibration
        case .sessionFailed: .cameraSessionFailure
        case .timedOut, .interrupted, .stopped: nil
        }
    }
}

extension AutoGarmentRecognitionError: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? {
        switch self {
        case .noDetection: .garmentNotRecognized
        case .ambiguous: .ambiguousGarment
        case .unsupported: .unsupportedGarment
        case .invalidProvenance: .invalidRecognitionResult
        case .missingClassifier, .incompatibleClassifier: .invalidModelConfiguration
        case .poseNotFound: .landmarksNotFound
        case .foregroundNotFound: .foregroundNotFound
        case .foregroundMismatch: .foregroundMismatch
        case .shapeUnverified: .garmentStructureUnverified
        }
    }
}

extension GarmentModelError: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? {
        switch self {
        case .missingResources, .incompatibleModel: .invalidModelConfiguration
        case .invalidRecognition: .invalidRecognitionResult
        case .noDetection: .landmarksNotFound
        case .multipleGarments: .multipleGarments
        }
    }
}

extension BottomModelError: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? {
        switch self {
        case .missingResources, .incompatibleModel: .invalidModelConfiguration
        case .invalidImage, .imageSizeMismatch, .bufferCreation: .invalidModelInput
        }
    }
}

extension GarmentForegroundValidationFailure: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? {
        (originalError as? any AutomaticMeasurementFailureCauseProviding)?.automaticMeasurementFailureCause
    }
}

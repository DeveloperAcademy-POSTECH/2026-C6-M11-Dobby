import Foundation

/// Camera orientation and garment orientation are different: a top can be
/// laid upside down in a correctly oriented RGB frame. Preserve a viable subject
/// in its original orientation before trying one half-turn. The subject attempt
/// reuses that orientation's already observed pose/mask rather than new inference.
nonisolated enum GarmentPoseOrientationRecovery {
    static func halfTurn(of orientation: ImageOrientation) -> ImageOrientation {
        switch orientation {
        case .up: .down
        case .down: .up
        case .right: .left
        case .left: .right
        }
    }

    static func perform<Value>(
        orientation: ImageOrientation,
        allowsHalfTurn: Bool,
        strictAttempt: (ImageOrientation) throws -> Value,
        subjectAttempt: (ImageOrientation) throws -> Value? = { _ in nil },
        partialResult: () throws -> Value? = { nil }
    ) throws -> Value {
        do { return try strictAttempt(orientation) }
        catch {
            guard isRecoverable(error) else { throw error }
            let primaryError = error
            if let subject = try subjectAttempt(orientation) { return subject }
            guard allowsHalfTurn else { throw primaryError }
            let turned = halfTurn(of: orientation)
            do { return try strictAttempt(turned) }
            catch {
                // Clutter, configuration and cancellation remain hard errors;
                // partial body support never overrides those checks.
                guard isRecoverable(error) else { throw error }
                if let subject = try subjectAttempt(turned) { return subject }
                if let partial = try partialResult() { return partial }
                throw primaryError
            }
        }
    }

    private static func isRecoverable(_ error: Error) -> Bool {
        if let error = error as? BottomLandmarkError, error == .noDetection { return true }
        if let error = error as? GarmentMaskAssociationError, error == .unmatchedGarment { return true }
        return false
    }
}

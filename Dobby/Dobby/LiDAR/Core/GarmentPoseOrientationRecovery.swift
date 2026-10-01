import Foundation

/// Camera orientation and garment orientation are different: a top can be
/// laid upside down in a correctly oriented RGB frame. Try one half-turn only
/// after strict recognition fails, preserving every successful primary result.
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
        partialResult: () throws -> Value? = { nil }
    ) throws -> Value {
        do { return try strictAttempt(orientation) }
        catch {
            guard allowsHalfTurn, isRecoverable(error) else { throw error }
            let primaryError = error
            do { return try strictAttempt(halfTurn(of: orientation)) }
            catch {
                // Clutter, configuration and cancellation remain hard errors;
                // partial body support never overrides those checks.
                guard isRecoverable(error) else { throw error }
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

import XCTest
@testable import Dobby

@MainActor
final class WorkflowFailureCauseAdapterTests: XCTestCase {
    func testAutomaticRecognitionErrorsRetainTheirSpecificObservedStage() {
        let scenarios: [(AutoGarmentRecognitionError, AutomaticMeasurementFailureCause)] = [
            (.noDetection, .garmentNotRecognized), (.ambiguous, .ambiguousGarment),
            (.unsupported, .unsupportedGarment), (.poseNotFound(.top), .landmarksNotFound),
            (.foregroundNotFound, .foregroundNotFound),
            (.foregroundMismatch(.top), .foregroundMismatch),
            (.shapeUnverified(.top), .garmentStructureUnverified),
            (.missingClassifier, .invalidModelConfiguration),
            (.incompatibleClassifier, .invalidModelConfiguration),
            (.invalidProvenance, .invalidRecognitionResult)
        ]
        for (error, cause) in scenarios {
            XCTAssertEqual(error.automaticMeasurementFailureCause, cause)
        }
    }

    func testCameraStopRemainsSilentWhileRealDepthFailureHasADepthReason() throws {
        let stopped = ARKitCaptureError.stopped
        XCTAssertEqual(stopped.automaticMeasurementFailureCode, .cancelled)
        XCTAssertNil(WorkflowFailureFeedback.make(for: .init(stage: .capture,
            code: stopped.automaticMeasurementFailureCode, message: stopped.localizedDescription,
            cause: stopped.automaticMeasurementFailureCause), hasCapturedPhoto: false))
        let depth = ARKitCaptureError.invalidDepth
        XCTAssertEqual(depth.automaticMeasurementFailureCause, .invalidCaptureDepth)
        let feedback = try XCTUnwrap(WorkflowFailureFeedback.make(for: .init(stage: .capture,
            code: depth.automaticMeasurementFailureCode, message: depth.localizedDescription,
            cause: depth.automaticMeasurementFailureCause), hasCapturedPhoto: false))
        XCTAssertTrue(feedback.title.contains("깊이"))
        XCTAssertFalse(feedback.title.contains("측정점"))
    }

    func testMissingPoseMultipleGarmentsAndMalformedModelRemainDistinct() {
        XCTAssertEqual(GarmentModelError.noDetection(.top).automaticMeasurementFailureCause, .landmarksNotFound)
        XCTAssertEqual(GarmentModelError.multipleGarments(.top).automaticMeasurementFailureCause, .multipleGarments)
        XCTAssertEqual(GarmentModelError.incompatibleModel(.top).automaticMeasurementFailureCause, .invalidModelConfiguration)
        XCTAssertEqual(BottomModelError.invalidImage.automaticMeasurementFailureCause, .invalidModelInput)
    }

    func testForegroundWrapperPreservesTypedOriginalReasonWithoutParsingItsString() throws {
        let wrapped = try XCTUnwrap(GarmentForegroundValidationFailure(
            GarmentMaskAssociationError.unmatchedGarment, attempts: []))
        XCTAssertEqual(wrapped.automaticMeasurementFailureCause, .foregroundMismatch)
        let feedback = try XCTUnwrap(WorkflowFailureFeedback.make(for: .init(stage: .landmarks,
            code: wrapped.automaticMeasurementFailureCode, message: wrapped.localizedDescription,
            cause: wrapped.automaticMeasurementFailureCause), hasCapturedPhoto: true))
        XCTAssertTrue(feedback.message.contains("측정점 후보는 있지만"))
        XCTAssertFalse(feedback.message.contains("측정점을 검출하지 못"))
    }
}

import XCTest
@testable import Dobby

/// These tests verify failure explanations, not real-camera model accuracy.
@MainActor
final class AutoGarmentFailureDiagnosisTests: XCTestCase {
    private func attempt(kind: AutomaticGarmentKind = .top, poseError: String? = nil,
                         evidence: GarmentKindEvidence? = nil) -> AutoGarmentClassificationAttempt {
        .init(orientation: .up, scores: [],
            route: .selected(kind: kind, category: kind == .top ? "Shirt" : "Long Pants", confidence: 0.8),
            evidence: evidence, poseError: poseError)
    }

    private func failure(_ attempts: [AutoGarmentClassificationAttempt],
                         decision: GarmentKindSelection = .noDetection,
                         unsupported: Bool = false) -> AutoGarmentRecognitionError {
        AutoGarmentLandmarkProvider.recognitionFailure(in: .init(decision: decision, top: nil, bottoms: nil,
            recognition: nil, classificationAttempts: attempts, isUnsupported: unsupported,
            poseRequests: nil, foregroundRequests: nil))
    }

    func testClassifierRejectionHasNoInventedPoseOrMaskFailure() {
        let weak = AutoGarmentClassificationAttempt(orientation: .up, scores: [],
            route: .uncertain(reason: .lowConfidence))
        XCTAssertEqual(failure([weak]), .noDetection)
        XCTAssertEqual(failure([weak], decision: .ambiguous), .ambiguous)
    }

    func testSupportedCategoryButMissingPoseExplainsMeasurementPoints() {
        let error = failure([attempt(poseError: "noDetection", evidence: .unmatched(kind: .top))])
        XCTAssertEqual(error, .poseNotFound(.top))
        XCTAssertTrue(error.errorDescription?.contains("측정점") == true)
        XCTAssertTrue(error.isRecognitionRejection)
    }

    func testForegroundAndAssociationFailuresAreDistinctFromClassification() {
        XCTAssertEqual(failure([attempt(poseError: "noForeground", evidence: .unmatched(kind: .top))]), .foregroundNotFound)
        XCTAssertEqual(failure([attempt(kind: .bottoms, poseError: "unmatchedForeground",
            evidence: .unmatched(kind: .bottoms))]), .foregroundMismatch(.bottoms))
    }

    func testStructuralFailureExplainsLongSleevesEvenWhenDecisionIsAmbiguous() {
        let evidence = GarmentKindEvidence(kind: .top, status: .uncertain, reasons: [.insufficientSilhouetteEvidence])
        let error = failure([attempt(evidence: evidence)], decision: .ambiguous)
        XCTAssertEqual(error, .shapeUnverified(.top))
        XCTAssertTrue(error.errorDescription?.contains("소매") == true)
    }

    func testDeeperStructuralEvidenceWinsOverAnEarlierPoseFailure() {
        let evidence = GarmentKindEvidence(kind: .top, status: .rejected, reasons: [.unsupportedSilhouette])
        XCTAssertEqual(failure([attempt(poseError: "noDetection", evidence: .unmatched(kind: .top)),
            attempt(evidence: evidence)]), .shapeUnverified(.top))
    }

    func testUnsupportedCategoryAndInvalidEvidenceStayConfigurationOrSupportFailures() {
        XCTAssertEqual(failure([], unsupported: true), .unsupported)
        let invalid = GarmentKindEvidence(kind: .top, status: .uncertain, reasons: [.invalidInput])
        let error = failure([attempt(evidence: invalid)])
        XCTAssertEqual(error, .invalidProvenance)
        XCTAssertEqual(error.automaticMeasurementFailureCode, .invalidConfiguration)
        XCTAssertFalse(error.isRecognitionRejection)
    }
}

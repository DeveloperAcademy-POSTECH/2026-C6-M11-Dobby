import Foundation
import XCTest
@testable import DobbyLiDARCore

final class WorkflowFailureFeedbackTests: XCTestCase {
    func testCancellationNeverCreatesAnAlertForAnyStageOrCause() {
        for stage in [AutomaticMeasurementStage.capture, .landmarks, .measurement] {
            let failure = AutomaticMeasurementWorkflowFailure(stage: stage, code: .cancelled,
                message: "카메라가 종료되어 촬영을 취소했습니다.", cause: .landmarksNotFound)
            XCTAssertNil(WorkflowFailureFeedback.make(for: failure, hasCapturedPhoto: true))
        }
    }

    func testPointsExistingButUnmatchedAreNotDescribedAsMissing() throws {
        for cause in [AutomaticMeasurementFailureCause.foregroundMismatch, .garmentStructureUnverified] {
            let feedback = try XCTUnwrap(WorkflowFailureFeedback.make(for: .init(stage: .landmarks,
                code: .providerFailure, message: "모델 후보점은 남아 있습니다.", cause: cause), hasCapturedPhoto: true))
            XCTAssertFalse(feedback.title.contains("측정점을 찾지 못"))
            XCTAssertFalse(feedback.message.contains("측정점을 검출하지 못"))
            XCTAssertTrue(feedback.message.contains("후보"))
            XCTAssertTrue(feedback.message.contains("이 사진"))
            XCTAssertTrue(feedback.diagnosticCode.hasSuffix(cause.rawValue))
        }
    }

    func testMissingPointsMultipleSubjectsAndInputFailureHaveDifferentReasons() throws {
        let causes: [AutomaticMeasurementFailureCause] = [.landmarksNotFound, .multipleGarments,
            .foregroundNotFound, .invalidModelInput, .invalidModelConfiguration]
        let feedback = try causes.map { cause in
            try XCTUnwrap(WorkflowFailureFeedback.make(for: .init(stage: .landmarks,
                code: .providerFailure, message: "원본 오류", cause: cause), hasCapturedPhoto: true))
        }
        XCTAssertEqual(Set(feedback.map(\.title)).count, causes.count)
        XCTAssertTrue(feedback[0].message.contains("측정점을 검출하지 못"))
        XCTAssertTrue(feedback[1].message.contains("여러 옷 또는 주변 물건"))
        XCTAssertTrue(feedback[2].message.contains("옷 영역을 분리하지 못"))
        XCTAssertTrue(feedback[3].message.contains("이미지 또는 좌표 데이터의 형식"))
        XCTAssertTrue(feedback[4].message.contains("모델 파일 또는 입력·출력 형식"))
    }

    func testUnknownFailureKeepsActualDescriptionAndDoesNotInventDepthOrMissingPoints() throws {
        let failure = AutomaticMeasurementWorkflowFailure(stage: .measurement,
            code: .providerFailure, message: "Unclassified backend error 706")
        let feedback = try XCTUnwrap(WorkflowFailureFeedback.make(for: failure, hasCapturedPhoto: true))
        XCTAssertTrue(feedback.message.contains(failure.message))
        XCTAssertTrue(feedback.message.contains("오류 코드: measurement.providerFailure"))
        XCTAssertFalse(feedback.message.contains("깊이가 부족"))
        XCTAssertFalse(feedback.message.contains("측정점을 검출하지 못"))
        XCTAssertFalse(feedback.message.contains("사진과 측정점은 유지"))
    }

    func testMissingCaptureDepthExplainsThatMovingPointsCannotRecoverTheData() throws {
        let feedback = try XCTUnwrap(WorkflowFailureFeedback.make(for: .init(stage: .capture,
            code: .providerFailure, message: "Depth buffer invalid", cause: .invalidCaptureDepth), hasCapturedPhoto: false))
        XCTAssertTrue(feedback.title.contains("깊이"))
        XCTAssertTrue(feedback.message.contains("점 이동만으로 깊이 데이터를 복구할 수는 없어요"))
        XCTAssertFalse(feedback.message.contains("이 사진에서 점을 직접 지정"))
    }

    func testTimeoutAndInterruptionCannotBecomePointDetectionFailures() throws {
        var titles = Set<String>()
        for stage in [AutomaticMeasurementStage.capture, .landmarks, .measurement] {
            let feedback = try XCTUnwrap(WorkflowFailureFeedback.make(for: .init(stage: stage,
                code: .timedOut, message: "타임아웃"), hasCapturedPhoto: stage != .capture))
            titles.insert(feedback.title)
            XCTAssertFalse(feedback.message.contains("측정점을 검출하지 못"))
        }
        XCTAssertEqual(titles.count, 3)
        let interrupted = try XCTUnwrap(WorkflowFailureFeedback.make(for: .init(stage: .landmarks,
            code: .interrupted, message: "세션 중단"), hasCapturedPhoto: true))
        XCTAssertEqual(interrupted.title, "촬영이 중단됐어요")
    }

    func testOldFailureJSONWithoutCauseDecodesAndNewCauseRoundTrips() throws {
        let oldJSON = Data(#"{"stage":"landmarks","code":"providerFailure","message":"기존 오류"}"#.utf8)
        let old = try JSONDecoder().decode(AutomaticMeasurementWorkflowFailure.self, from: oldJSON)
        XCTAssertNil(old.cause)
        XCTAssertEqual(old.message, "기존 오류")
        let current = AutomaticMeasurementWorkflowFailure(stage: .landmarks, code: .providerFailure,
            message: "연결 실패", cause: .foregroundMismatch)
        XCTAssertEqual(try JSONDecoder().decode(AutomaticMeasurementWorkflowFailure.self,
            from: JSONEncoder().encode(current)), current)
    }

    @MainActor
    func testWorkflowPreservesTypedCauseAndOriginalMessageThroughTerminalAndCodable() async throws {
        let scene = SyntheticFixtures.scene()
        let snapshot = CaptureSnapshot(frame: scene.frame, imageJPEG: Data([1, 2, 3]))
        let workflow = AutomaticMeasurementWorkflow(camera: FailureFeedbackCamera(snapshot: snapshot),
            landmarks: FailureFeedbackLandmarks(), definitions: [.testDistance])
        var terminal: AutomaticMeasurementTerminalEvent?
        workflow.onTerminal = { terminal = $0 }
        do {
            _ = try await workflow.run(orientation: .up)
            XCTFail("Expected a typed provider failure")
        } catch let failure as AutomaticMeasurementWorkflowFailure {
            XCTAssertEqual(failure.stage, .landmarks)
            XCTAssertEqual(failure.code, .providerFailure)
            XCTAssertEqual(failure.cause, .foregroundMismatch)
            XCTAssertEqual(failure.message, "Original adapter evidence")
            XCTAssertEqual(terminal?.failure, failure)
            XCTAssertEqual(terminal?.snapshot?.frame.frameID, snapshot.frame.frameID)
            XCTAssertEqual(try JSONDecoder().decode(AutomaticMeasurementWorkflowFailure.self,
                from: JSONEncoder().encode(failure)), failure)
        }
    }
}

@MainActor
private struct FailureFeedbackCamera: CaptureSnapshotProviding {
    let snapshot: CaptureSnapshot
    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot { snapshot }
}

private actor FailureFeedbackLandmarks: GarmentLandmarkProviding {
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        throw FailureFeedbackProviderError()
    }
}

private struct FailureFeedbackProviderError: LocalizedError, AutomaticMeasurementFailureClassifying,
    AutomaticMeasurementFailureCauseProviding {
    var errorDescription: String? { "Original adapter evidence" }
    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode { .providerFailure }
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? { .foregroundMismatch }
}

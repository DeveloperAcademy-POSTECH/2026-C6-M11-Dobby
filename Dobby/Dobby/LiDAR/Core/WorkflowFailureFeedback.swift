import Foundation

/// A reason observed by an adapter, never inferred from localized wording.
nonisolated enum AutomaticMeasurementFailureCause: String, Codable, Sendable, Equatable {
    case cameraPermissionDenied, cameraUnavailable, cameraNotReady, captureBusy
    case invalidCaptureDepth, invalidCaptureImage, invalidCaptureCalibration, cameraSessionFailure
    case garmentNotRecognized, ambiguousGarment, unsupportedGarment, landmarksNotFound
    case multipleGarments, foregroundNotFound, foregroundMismatch, garmentStructureUnverified
    case invalidModelInput, invalidModelConfiguration, invalidRecognitionResult
}

nonisolated protocol AutomaticMeasurementFailureCauseProviding: Error {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? { get }
}

extension AutomaticMeasurementWorkflowFailure: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? { cause }
}

extension RecordedMeasurementRunFailure: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? { workflowFailure.cause }
}

/// User cancellation has no failure presentation. Unknown errors keep their
/// actual message and code instead of claiming missing points or bad depth.
nonisolated struct WorkflowFailureFeedback: Sendable, Equatable {
    var title: String
    var message: String
    var diagnosticCode: String

    static func make(for failure: AutomaticMeasurementWorkflowFailure,
                     hasCapturedPhoto: Bool) -> Self? {
        guard failure.code != .cancelled else { return nil }
        let title: String
        let reason: String
        let recovery: String
        switch failure.code {
        case .cancelled: return nil
        case .timedOut:
            switch failure.stage {
            case .capture: title = "촬영 준비 시간이 초과됐어요"
            case .landmarks: title = "사진 분석 시간이 초과됐어요"
            case .measurement: title = "길이 계산 시간이 초과됐어요"
            }
            reason = "처리 제한 시간 안에 이번 단계를 마치지 못했어요."
            recovery = "잠시 기다린 뒤 다시 촬영해 주세요."
        case .interrupted:
            title = "촬영이 중단됐어요"
            reason = "카메라 사용 중단으로 자동 실측을 이어가지 못했어요."
            recovery = "앱으로 돌아온 뒤 다시 촬영해 주세요."
        case .busy:
            title = "이전 촬영을 마무리하고 있어요"
            reason = "아직 처리 중인 촬영이 있어 새 작업을 시작하지 못했어요."
            recovery = "잠시 기다린 뒤 다시 촬영해 주세요."
        case .frameMismatch, .invalidProvenance:
            title = "촬영 데이터를 연결하지 못했어요"
            reason = "사진·깊이·측정점의 촬영 정보가 서로 맞지 않아 길이를 계산하지 않았어요."
            recovery = "카메라를 다시 열고 새 사진을 촬영해 주세요."
        case .invalidConfiguration, .providerFailure:
            if let cause = failure.cause {
                (title, reason, recovery) = description(for: cause)
            } else if failure.code == .invalidConfiguration {
                title = "측정 구성을 확인하지 못했어요"
                reason = "모델 파일 또는 측정 설정을 처리하지 못했어요."
                recovery = "앱을 다시 열어 시도하고, 반복되면 아래 오류 코드를 전달해 주세요."
            } else {
                switch failure.stage {
                case .capture: title = "촬영을 완료하지 못했어요"
                case .landmarks: title = "자동 실측 분석을 완료하지 못했어요"
                case .measurement: title = "길이를 계산하지 못했어요"
                }
                reason = "자동 실측 처리 중 예상하지 못한 오류가 발생했어요."
                recovery = "다시 시도하고, 반복되면 아래 오류 코드를 전달해 주세요."
            }
        }
        let code = [failure.stage.rawValue, failure.code.rawValue, failure.cause?.rawValue]
            .compactMap { $0 }.joined(separator: ".")
        let details = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let photoAction = hasCapturedPhoto ? " 이 사진에서 점을 직접 지정해 측정할 수도 있어요." : ""
        let message = reason + (details.isEmpty ? "" : "\n\n상세: " + details)
            + "\n\n" + recovery + photoAction + "\n\n오류 코드: " + code
        return .init(title: title, message: message, diagnosticCode: code)
    }

    private static func description(for cause: AutomaticMeasurementFailureCause) -> (String, String, String) {
        switch cause {
        case .cameraPermissionDenied:
            ("카메라 접근 권한이 필요해요", "카메라 접근이 허용되지 않아 사진을 촬영하지 못했어요.", "설정에서 Dobby의 카메라 접근을 허용해 주세요.")
        case .cameraUnavailable:
            ("LiDAR 카메라를 사용할 수 없어요", "이 기기에서 필요한 LiDAR 카메라를 사용할 수 없어요.", "LiDAR를 지원하는 아이폰에서 다시 시도해 주세요.")
        case .cameraNotReady:
            ("카메라가 아직 준비되지 않았어요", "카메라 세션이 실행 중이지 않아 촬영하지 못했어요.", "카메라를 다시 열고 화면이 보이면 촬영해 주세요.")
        case .captureBusy:
            ("이미 촬영 중이에요", "이전 촬영이 진행 중이라 새 촬영을 시작하지 않았어요.", "현재 촬영이 끝난 뒤 다시 시도해 주세요.")
        case .invalidCaptureDepth:
            ("촬영한 깊이를 읽지 못했어요", "LiDAR 깊이 데이터의 형식을 확인하지 못해 길이를 계산하지 않았어요.", "카메라를 다시 열어 촬영해 주세요. 점 이동만으로 깊이 데이터를 복구할 수는 없어요.")
        case .invalidCaptureImage:
            ("촬영한 사진을 처리하지 못했어요", "촬영 이미지의 읽기 또는 저장에 실패했어요.", "다시 촬영해 주세요.")
        case .invalidCaptureCalibration:
            ("사진과 깊이 좌표가 맞지 않아요", "카메라 보정 정보를 연결하지 못해 길이를 계산하지 않았어요.", "카메라를 다시 열고 새 사진을 촬영해 주세요.")
        case .cameraSessionFailure:
            ("카메라에 오류가 발생했어요", "카메라 세션 오류로 촬영을 마치지 못했어요.", "카메라를 다시 열어 시도해 주세요.")
        case .garmentNotRecognized:
            ("옷 종류를 구분하지 못했어요", "촬영한 사진을 상의 또는 하의로 구분하지 못했어요.", "옷 한 벌 전체가 보이도록 다시 촬영해 주세요.")
        case .ambiguousGarment:
            ("옷 종류를 구분하기 어려워요", "상의와 하의 중 어떤 측정 모델을 사용할지 결정하지 못했어요.", "소매 또는 바짓단이 모두 보이도록 한 벌만 펼쳐 주세요.")
        case .unsupportedGarment:
            ("자동 실측을 지원하지 않는 옷이에요", "인식된 옷 종류에 사용할 자동 측정 모델이 없어요.", "상의·바지·반바지를 촬영하거나 사진에서 점을 직접 지정해 주세요.")
        case .landmarksNotFound:
            ("측정점을 찾지 못했어요", "사진에서 자동 실측에 필요한 측정점을 검출하지 못했어요.", "옷 끝까지 보이도록 다시 촬영하거나 사진에서 점을 직접 지정해 주세요.")
        case .multipleGarments:
            ("여러 대상이 인식됐어요", "여러 옷 또는 주변 물건이 인식되어 측정 대상을 정하지 않았어요.", "주변 물건을 치우고 옷 한 벌만 촬영해 주세요.")
        case .foregroundNotFound:
            ("옷 윤곽을 분리하지 못했어요", "사진에서 측정에 사용할 옷 영역을 분리하지 못했어요.", "옷과 구분되는 배경에서 다시 촬영해 주세요.")
        case .foregroundMismatch:
            ("측정점과 옷 윤곽을 연결하지 못했어요", "측정점 후보는 있지만 사진 속 옷 영역과의 연결을 확인하지 못했어요.", "소매를 펼치고 옷과 구분되는 배경에서 촬영하거나 사진에서 점을 직접 확인해 주세요.")
        case .garmentStructureUnverified:
            ("옷의 형태를 확인하지 못했어요", "측정점 후보와 윤곽에서 몸통·소매 또는 허리·양쪽 다리 구조를 확인하지 못했어요.", "소매나 두 바짓단 사이가 보이도록 펼쳐 다시 촬영해 주세요.")
        case .invalidModelInput:
            ("인식할 사진 데이터를 처리하지 못했어요", "모델에 전달할 이미지 또는 좌표 데이터의 형식이 맞지 않아요.", "새 사진으로 다시 시도하고, 반복되면 오류 코드를 전달해 주세요.")
        case .invalidModelConfiguration:
            ("옷 인식 모델을 준비하지 못했어요", "모델 파일 또는 입력·출력 형식이 앱의 측정 설정과 맞지 않아요.", "앱을 다시 열어 시도하고, 반복되면 오류 코드를 전달해 주세요.")
        case .invalidRecognitionResult:
            ("인식 결과를 사용할 수 없어요", "인식 결과의 형식 또는 출처를 검증하지 못해 자동 실측에 사용하지 않았어요.", "새 사진으로 다시 시도하고, 반복되면 오류 코드를 전달해 주세요.")
        }
    }
}

extension BottomLandmarkError: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? {
        switch self {
        case .noDetection: .landmarksNotFound
        case .multipleGarments: .multipleGarments
        case .invalidGeometry: .invalidModelInput
        case .invalidSchema, .invalidOutputShape: .invalidModelConfiguration
        case .invalidCandidate: .invalidRecognitionResult
        }
    }
}

extension GarmentMaskAssociationError: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? {
        switch self {
        case .invalidMask: .invalidModelInput
        case .noForeground: .foregroundNotFound
        case .multipleForegrounds: .multipleGarments
        case .unmatchedGarment: .foregroundMismatch
        }
    }
}

extension GarmentOrientationError: AutomaticMeasurementFailureCauseProviding {
    var automaticMeasurementFailureCause: AutomaticMeasurementFailureCause? {
        switch self {
        case .invalidImage, .inputBuffer: .invalidModelInput
        case .modelMissing, .invalidModelInput, .invalidProbabilities: .invalidModelConfiguration
        }
    }
}

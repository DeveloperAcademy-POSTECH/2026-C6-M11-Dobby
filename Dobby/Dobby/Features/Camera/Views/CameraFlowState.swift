//
//  CameraFlowState.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

/// View-owned demo routes, not OS authorization or domain model state.
enum CameraFlowState: Equatable {
    case preview
    case capturing
    case review
    case processing
    case result
    case handoff
    case failed(CameraFailure)
}

extension CameraFailure {
    var message: String {
        switch self {
        case .captureFailed:
            return "목 촬영 데이터를 준비하지 못했습니다."
        case .processingFailed:
            return "목 처리 결과를 준비하지 못했습니다."
        case .mismatchedCapture:
            return "현재 상품과 다른 촬영 데이터가 반환됐습니다."
        case .mismatchedResult:
            return "현재 촬영본과 일치하지 않는 처리 결과입니다."
        case .missingCapture:
            return "먼저 촬영본을 준비해주세요."
        case .operationInProgress:
            return "진행 중인 작업이 끝난 뒤 다시 시도해주세요."
        }
    }
}

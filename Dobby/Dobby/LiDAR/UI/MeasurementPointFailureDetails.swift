import SwiftUI

/// Candidate photo markers stay editable even when depth or model confidence
/// cannot support a number. Explain the failed contributor instead of hiding it.
struct MeasurementPointFailureDetails: View {
    let value: MeasurementValue

    var body: some View {
        ForEach(Array((value.pointFailures ?? []).enumerated()), id: \.offset) { _, failure in
            Text("\(MeasurementLandmarkName.title(failure.landmarkID)): \(failure.reason.message)")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("measurementPointFailure_\(failure.landmarkID)")
        }
    }
}

struct MeasurementRecognitionDetails: View {
    let diagnostics: GarmentRecognitionDiagnostics

    var body: some View {
        DisclosureGroup("촬영 당시 인식 확인 정보") {
            VStack(alignment: .leading, spacing: 8) {
                Text("모델 후보점 \(diagnostics.rawPoints.count)개 보존")
                Text("윤곽과 연결되지 않은 후보점도 사진에서 확인하고 수정할 수 있어요.")
                    .foregroundStyle(.secondary)
                Text("촬영 방향 \(diagnostics.requestedOrientation.rawValue) · 선택한 추론 방향 \(diagnostics.selectedPoseOrientation.rawValue)")
                ForEach(Array(diagnostics.pointAssessments.enumerated()), id: \.offset) { _, assessment in
                    if assessment.status == .outsideMask {
                        Text("\(MeasurementLandmarkName.title(assessment.landmarkID)): 윤곽 연결 불확실 · 점 유지")
                            .foregroundStyle(.orange)
                    }
                }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }.labCard().accessibilityIdentifier("recognitionValidationDetails")
    }
}

enum MeasurementLandmarkName {
    static func title(_ id: String) -> String {
        switch id {
        case "neck_left": "왼쪽 목점"
        case "neck_right": "오른쪽 목점"
        case "neck_center": "목 중앙점"
        case "top_length_start": "총장 상단점"
        case "waist_front_center": "앞허리 중앙점"
        case "shoulder_left": "왼쪽 어깨점"
        case "shoulder_right": "오른쪽 어깨점"
        case "armpit_left": "왼쪽 겨드랑이점"
        case "armpit_right": "오른쪽 겨드랑이점"
        case "sleeve_end_left": "왼쪽 소매 끝점"
        case "sleeve_end_right": "오른쪽 소매 끝점"
        case "hem_left": "왼쪽 밑단점"
        case "hem_right": "오른쪽 밑단점"
        case "hem_center": "밑단 중앙점"
        case "waist_left": "왼쪽 허리점"
        case "waist_right": "오른쪽 허리점"
        case "waist_center": "허리 중앙점"
        case "crotch": "가랑이점"
        case "hem_left_outer": "왼쪽 바짓단 바깥점"
        case "hem_left_inner": "왼쪽 바짓단 안쪽점"
        case "hem_right_outer": "오른쪽 바짓단 바깥점"
        case "hem_right_inner": "오른쪽 바짓단 안쪽점"
        default: id
        }
    }
}

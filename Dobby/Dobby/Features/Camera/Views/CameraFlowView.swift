//
//  CameraFlowView.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import SwiftUI

/// System permission followed by a mock capture flow; live preview/capture are later steps.
struct CameraFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: CameraModel
    @State private var permission: CameraPermission
    @State private var state: CameraFlowState = .preview

    init(model: CameraModel, permission: CameraPermission? = nil) {
        _model = State(initialValue: model)
        _permission = State(initialValue: permission ?? CameraPermission(authorizer: SystemCameraAuthorization()))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("목 데모 · 실제 촬영·측정 없음")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    CameraPermissionGate(permission: permission) { stageContent }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .navigationTitle("카메라 흐름")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("camera.closeDemo")
                }
            }
            .task(id: state) {
                await performPendingAction()
            }
        }
        .onDisappear { restartDemo() }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch state {
        case .preview:
            stage("실측 촬영", description: "옷이 잘리지 않게 카메라 안에 넣어주세요. 현재는 프리뷰 자리만 표시합니다.")
            Button("목 촬영본 만들기") { state = .capturing }
                .buttonStyle(.borderedProminent)
        case .capturing:
            ProgressView("목 촬영본 준비 중")
        case .review:
            stage("촬영본 확인", description: "현재 상품에 연결된 목 촬영본입니다. 이미지 파일은 생성되지 않았습니다.")
            Button("목 처리로 계속") { state = .processing }
                .buttonStyle(.borderedProminent)
            Button("데모 처음부터", action: restartDemo)
        case .processing:
            ProgressView("목 처리 중")
        case .result:
            stage("실측 결과 확인", description: "결과 연결을 확인했습니다. 실제 측정값과 신뢰도는 아직 없습니다.")
            if let result = model.draft.processingResult {
                LabeledContent("결과 출처", value: result.source.rawValue)
                LabeledContent("처리 상태", value: result.outcome.rawValue)
                Text("촬영 ID: \(result.captureID.uuidString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("완료 접점 확인") {
                    if model.canHandoff { state = .handoff }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canHandoff)
            }
            Button("데모 처음부터", action: restartDemo)
        case .handoff:
            stage("다음 단계 연결 준비", description: "같은 상품의 촬영본과 처리 결과를 전달할 위치입니다. 상세 촬영은 이번 범위에 포함되지 않습니다.")
            Button("데모 처음부터", action: restartDemo)
            Button("닫기") { dismiss() }
        case .failed(let failure):
            stage("데모 연결 오류", description: failure.message)
            Button("데모 처음부터", action: restartDemo)
        }
    }

    private func performPendingAction() async {
        let expectedState = state
        let sessionID = model.draft.sessionID
        guard expectedState == .capturing || expectedState == .processing else { return }
        do {
            if expectedState == .capturing {
                try await model.capture()
            } else {
                try await model.process()
            }
            try Task.checkCancellation()
            guard state == expectedState, model.draft.sessionID == sessionID else { return }
            state = expectedState == .capturing ? .review : .result
        } catch {
            guard state == expectedState,
                  model.draft.sessionID == sessionID else { return }
            if error is CancellationError || Task.isCancelled {
                state = expectedState == .capturing ? .preview : .review
            } else {
                state = .failed((error as? CameraFailure) ??
                    (expectedState == .capturing ? .captureFailed : .processingFailed))
            }
        }
    }

    private func restartDemo() {
        model.reset()
        state = .preview
    }

    private func stage(_ title: String, description: String) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.title2.bold())
            Text(description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

#Preview {
    CameraDemoEntryView(authorizer: MockCameraAuthorization())
}

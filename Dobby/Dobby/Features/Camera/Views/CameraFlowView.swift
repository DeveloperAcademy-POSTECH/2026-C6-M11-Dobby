//
//  CameraFlowView.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import SwiftUI
import AVFoundation

/// 상세 촬영 → 사진 선택의 구조 확인용 화면. Hi-Fi UI와 실제 촬영은 후속 작업.
/// 상위 NavigationStack에 삽입하며 화면 이동 중 같은 Model을 유지한다.
struct CameraFlowView: View {
    let model: ProductPhotoModel
    @State private var permission: CameraPermission
    let onComplete: (ProductPhotoOutput) -> Void
    @State private var captureRequested = false
    @State private var failureMessage: String?

    init(model: ProductPhotoModel, permission: CameraPermission,
         onComplete: @escaping (ProductPhotoOutput) -> Void) {
        self.model = model
        _permission = State(initialValue: permission)
        self.onComplete = onComplete
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("구조 확인용 목 데모 · 실제 촬영·측정 없음")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Text("전달받은 실측샷 1장 · 상세 사진 \(model.detailPhotos.count)장")
                CameraPermissionGate(permission: permission) {
                    VStack(spacing: 20) {
                        Text("카메라 프리뷰 자리")
                            .frame(maxWidth: .infinity, minHeight: 180)
                            .background(.quaternary)
                        Button("목 상세 사진 추가") { captureRequested = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(captureRequested || model.isCapturing)
                            .accessibilityIdentifier("camera.captureDetail")
                        if model.isCapturing { ProgressView("목 사진 준비 중") }
                    }
                }
                if let failureMessage {
                    Text(failureMessage).foregroundStyle(.red)
                    Text("기존 사진은 유지됩니다. 권한을 확인한 뒤 다시 촬영해 주세요.")
                }
                // 기존 사진 선택에는 카메라 권한이 필요하지 않다.
                NavigationLink("제품 사진 선택") {
                    ProductPhotoSelectionView(model: model, onComplete: onComplete)
                }
                .disabled(captureRequested || model.isCapturing)
                .accessibilityIdentifier("camera.selectPhotos")
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .navigationTitle("제품 상세 촬영")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: captureRequested) {
            guard captureRequested else { return }
            failureMessage = nil
            do {
                permission.refresh()
                guard permission.status == .authorized else {
                    captureRequested = false
                    return
                }
                try await model.captureDetail()
            } catch {
                if !(error is CancellationError) && !Task.isCancelled {
                    failureMessage = (error as? CameraFailure ?? .captureFailed).message
                }
            }
            captureRequested = false
        }
        .onChange(of: permission.status) { _, status in
            if status != .authorized { captureRequested = false }
        }
        // 화면 이탈은 요청만 취소한다. 사진과 선택 결과는 초기화하지 않는다.
        .onDisappear { captureRequested = false }
    }
}

#Preview {
    CameraDemoEntryView(authorizer: MockCameraAuthorization())
}

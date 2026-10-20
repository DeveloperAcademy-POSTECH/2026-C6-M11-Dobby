//
//  CameraFlowView.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import SwiftUI
import AVFoundation

/// 상세 촬영 Hi-Fi 화면. 기본은 실제 영상이며 Canvas에서만 샘플 이미지를 주입한다.
/// 상위 NavigationStack에 삽입하며 화면 이동 중 같은 Model을 유지한다.
struct CameraFlowView: View {
    let model: ProductPhotoModel
    let camera: CameraPreviewSession?
    @State private var permission: CameraPermission
    let onComplete: (ProductPhotoOutput) async throws -> Void
    var previewSource: CapturedAsset.Source?
    private let background = Color(red: 26 / 255, green: 25 / 255, blue: 25 / 255)
    @State private var captureRequested = false
    @State private var failureMessage: String?
    @State private var isCaptureGuidePresented = false
    @State private var isGalleryPresented = false

    init(model: ProductPhotoModel, permission: CameraPermission,
         camera: CameraPreviewSession? = nil,
         previewSource: CapturedAsset.Source? = nil,
         onComplete: @escaping (ProductPhotoOutput) async throws -> Void) {
        self.model = model
        self.camera = camera
        _permission = State(initialValue: permission)
        self.onComplete = onComplete
        self.previewSource = previewSource
    }

    var body: some View {
        CameraPermissionGate(permission: permission) {
            preview
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        if let failureMessage {
                            Text(failureMessage).padding().background(.ultraThinMaterial)
                        } else if model.isCapturing {
                            ProgressView("사진 촬영·저장 중").padding().background(.ultraThinMaterial)
                        }
                        captureControls
                    }
                }
                .ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationTitle("제품 상세 촬영")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // 기존 사진 선택에는 카메라 권한이 필요하지 않다.
                NavigationLink {
                    ProductPhotoSelectionView(model: model, onComplete: onComplete)
                } label: {
                    Text("다음").font(.body.weight(.semibold)).foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isPhotoOperationInProgress)
                .accessibilityIdentifier("camera.selectPhotos")
            }
        }
        .fullScreenCover(isPresented: $isCaptureGuidePresented) {
            DetailCaptureGuideView {
                model.acknowledgeCaptureGuide()
                setCaptureGuidePresented(false)
            }
            .presentationBackground(.clear)
            .interactiveDismissDisabled()
        }
        .onChange(of: permission.status, initial: true) { _, _ in updateCaptureGuide() }
        .fullScreenCover(isPresented: $isGalleryPresented) {
            NavigationStack { DetailPhotoGalleryView(model: model) }
        }
        .onChange(of: camera?.canCapture, initial: true) { _, _ in updateCaptureGuide() }
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

    @ViewBuilder
    private var preview: some View {
        if let previewSource {
            CameraPhotoView(source: previewSource).accessibilityLabel("샘플 카메라 미리보기")
        } else if let camera {
            CameraLivePreviewView(camera: camera)
        } else {
            ContentUnavailableView("카메라 연결이 필요해요", systemImage: "camera")
        }
    }

    private var shutter: some View {
        Button { captureRequested = true } label: {
            Image("DetailCaptureShutter").resizable().frame(width: 92, height: 92)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canCapture)
        .opacity(canCapture ? 1 : 0.5)
        .accessibilityLabel("상세 사진 촬영")
        .accessibilityHint(previewSource == nil ? "사진을 촬영하고 상세 사진 목록에 추가합니다." : "표시된 샘플 사진을 목록에 추가합니다.")
        .accessibilityIdentifier("camera.captureDetail")
    }

    private var captureControls: some View {
        HStack {
            Spacer(minLength: 16)
            Button { isGalleryPresented = true } label: {
                CameraPhotoView(source: (model.photos.last ?? model.input.measurement).source,
                                maximumPixelSize: 192)
                    .frame(width: 48, height: 48).clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isPhotoOperationInProgress)
            .accessibilityLabel("촬영한 사진 보기")
            .accessibilityIdentifier("camera.openGallery")
            Spacer(minLength: 16)
            shutter
            Spacer(minLength: 16)
            // 노출·비율 조절은 더보기 구현 단계에서 연결한다.
            Button { /* 더보기 연결 예정 */ } label: {
                Image("DetailCaptureMore").resizable().frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel("촬영 옵션 더보기")
            .accessibilityIdentifier("camera.moreOptions")
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .background(.ultraThinMaterial)
    }

    private var canCapture: Bool {
        !isPhotoOperationInProgress && (previewSource != nil || camera?.canCapture == true)
    }

    private func updateCaptureGuide() {
        if permission.status != .authorized {
            setCaptureGuidePresented(false)
        } else if !model.hasAcknowledgedCaptureGuide,
                  previewSource != nil || camera?.canCapture == true {
            setCaptureGuidePresented(true)
        }
    }

    private func setCaptureGuidePresented(_ presented: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { isCaptureGuidePresented = presented }
    }

    private var isPhotoOperationInProgress: Bool {
        captureRequested || model.isCapturing || model.isDeleting
    }
}

#Preview {
    CameraDemoEntryView(authorizer: MockCameraAuthorization(), usesSamplePreview: true)
}

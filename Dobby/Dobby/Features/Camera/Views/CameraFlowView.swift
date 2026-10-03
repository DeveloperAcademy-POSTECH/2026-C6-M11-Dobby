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
        VStack(spacing: 0) {
            photoStrip
            CameraPermissionGate(permission: permission) {
                VStack(spacing: 0) {
                    preview
                        .overlay(alignment: .topTrailing) {
                            Text(previewSource == nil ? "실시간 미리보기" : "샘플 미리보기").font(.caption2)
                                .padding(6).background(.black.opacity(0.6), in: Capsule()).padding(8)
                        }
                        .overlay(alignment: .bottom) {
                            if let failureMessage {
                                Text(failureMessage).padding().background(.ultraThinMaterial)
                            } else if model.isCapturing {
                                ProgressView("사진 촬영·저장 중").padding().background(.ultraThinMaterial)
                            }
                        }
                    shutter
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 124, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(background.ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
        .navigationTitle("제품 상세 촬영")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // 기존 사진 선택에는 카메라 권한이 필요하지 않다.
                NavigationLink {
                    ProductPhotoSelectionView(model: model, onComplete: onComplete)
                } label: {
                    Text("완료").font(.body.weight(.semibold)).foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(captureRequested || model.isCapturing)
                .accessibilityIdentifier("camera.selectPhotos")
            }
        }
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

    private var photoStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in
                        CameraPhotoView(source: photo.source, maximumPixelSize: 160)
                            .frame(width: 36.5, height: 51)
                            .accessibilityLabel(index == 0 ? "실측 사진" : "상세 사진 \(index)")
                            .id(photo.id)
                    }
                }.padding(.horizontal, 16)
            }
            .onChange(of: model.photos.count) { _, _ in
                if let id = model.photos.last?.id { withAnimation { proxy.scrollTo(id, anchor: .trailing) } }
            }
        }
        .frame(height: 51)
        .padding(.top, 8)
        .padding(.bottom, 15)
    }

    private var shutter: some View {
        Button { captureRequested = true } label: {
            // Figma 내보내기에 포함된 그림자 여백: 왼쪽 18pt, 위 6pt.
            Image("CameraShutter").resizable().frame(width: 152, height: 118)
                .offset(x: 12, y: 7).frame(width: 92, height: 92)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canCapture)
        .opacity(canCapture ? 1 : 0.5)
        .accessibilityLabel("상세 사진 촬영")
        .accessibilityHint(previewSource == nil ? "사진을 촬영하고 상세 사진 목록에 추가합니다." : "표시된 샘플 사진을 목록에 추가합니다.")
        .accessibilityIdentifier("camera.captureDetail")
    }

    private var canCapture: Bool {
        !captureRequested && !model.isCapturing && (previewSource != nil || camera?.canCapture == true)
    }
}

#Preview {
    CameraDemoEntryView(authorizer: MockCameraAuthorization(), usesSamplePreview: true)
}

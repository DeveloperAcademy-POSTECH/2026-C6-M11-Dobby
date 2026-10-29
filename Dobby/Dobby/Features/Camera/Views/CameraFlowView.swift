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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: ProductPhotoModel
    let camera: CameraPreviewSession?
    @State private var permission: CameraPermission
    let onComplete: (ProductPhotoOutput) async throws -> Void
    let onSelectPhotos: (() -> Void)?
    let onExit: (() -> Void)?
    private let onSelectionVisibilityChange: (Bool) -> Void
    var previewSource: CapturedAsset.Source?
    private let background = Color.black
    @State private var captureRequested = false
    @State private var failureMessage: String?
    @State private var isCaptureGuidePresented = false
    @State private var isGalleryPresented = false
    @State private var isMoreOptionsPresented = false

    init(model: ProductPhotoModel, permission: CameraPermission,
         camera: CameraPreviewSession? = nil,
         previewSource: CapturedAsset.Source? = nil,
         onSelectPhotos: (() -> Void)? = nil,
         onExit: (() -> Void)? = nil,
         onSelectionVisibilityChange: @escaping (Bool) -> Void = { _ in },
         onComplete: @escaping (ProductPhotoOutput) async throws -> Void) {
        self.model = model
        self.camera = camera
        _permission = State(initialValue: permission)
        self.onComplete = onComplete
        self.onSelectPhotos = onSelectPhotos
        self.onExit = onExit
        self.onSelectionVisibilityChange = onSelectionVisibilityChange
        self.previewSource = previewSource
    }

    var body: some View {
        CameraPermissionGate(permission: permission) {
            GeometryReader { safeGeometry in
                cameraCanvas(bottomSafeAreaInset: safeGeometry.safeAreaInsets.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .navigationTitle("제품 상세 촬영")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(onExit != nil)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if let onExit {
                ToolbarItem(placement: .topBarLeading) {
                    Button { requestExit(onExit) } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(.white)
                    }
                        .disabled(isExitDisabled)
                        .accessibilityLabel("뒤로가기")
                        .accessibilityIdentifier("product-flow.back")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                // 기존 사진 선택에는 카메라 권한이 필요하지 않다.
                photoSelectionControl
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
            if status != .authorized {
                captureRequested = false
                isMoreOptionsPresented = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isMoreOptionsPresented = false }
        }
        // 화면 이탈은 요청만 취소한다. 사진과 선택 결과는 초기화하지 않는다.
        .onDisappear {
            captureRequested = false
            isMoreOptionsPresented = false
        }
    }

    /// Match the measurement camera's complete canvas and ratio-aware anchors.
    /// Reading the safe inset outside ignoresSafeArea prevents a second offset.
    private func cameraCanvas(bottomSafeAreaInset: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                ratioPreview
                    .modifier(DetailZoomModifier(options: camera?.options,
                        enabled: !isMoreOptionsPresented && !isPhotoOperationInProgress && scenePhase == .active
                            && (previewSource != nil || camera?.state == .running),
                        bottomSafeAreaInset: bottomSafeAreaInset))
                if !isMoreOptionsPresented {
                    captureControls(in: geometry.size, bottomSafeAreaInset: bottomSafeAreaInset)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.30),
                            value: camera?.options.photoAspectRatio ?? .fourThree)
                        .animation(nil, value: geometry.size)
                }
                captureFeedback(in: geometry.size, bottomSafeAreaInset: bottomSafeAreaInset)
                cameraOptionsOverlay(in: geometry.size, bottomSafeAreaInset: bottomSafeAreaInset)
                    .allowsHitTesting(isMoreOptionsPresented)
                    .accessibilityHidden(!isMoreOptionsPresented)
                    .zIndex(2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func captureFeedback(in size: CGSize, bottomSafeAreaInset: CGFloat) -> some View {
        if let frame = shutterFrame(in: size, bottomSafeAreaInset: bottomSafeAreaInset),
           failureMessage != nil || model.isCapturing {
            Group {
                if let failureMessage {
                    Text(failureMessage).multilineTextAlignment(.center)
                } else {
                    ProgressView("사진 촬영·저장 중")
                }
            }
            .padding(12)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: min(380, size.width - 32))
            .position(x: size.width / 2, y: max(24, frame.y - 34))
            .allowsHitTesting(false)
        }
    }

    private func cameraOptionsOverlay(in size: CGSize, bottomSafeAreaInset: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            let panel = CameraOptionsPanelLayout(containerSize: size, bottomSafeAreaInset: bottomSafeAreaInset)
            if isMoreOptionsPresented {
                Button { isMoreOptionsPresented = false } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("촬영 옵션 닫고 미리보기로 돌아가기")
                    .accessibilityIdentifier("camera.dismissOptions")
                DetailCaptureOptionsView(options: camera?.options,
                    exposureSelectionFeedbackEnabled: true,
                    panelLayout: panel) { isMoreOptionsPresented = false }
                    .position(x: panel.frame.midX, y: panel.frame.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isMoreOptionsPresented ? .isModal : [])
    }

    @ViewBuilder
    private var ratioPreview: some View {
        let ratio = camera?.options.photoAspectRatio ?? .fourThree
        Group {
            if let previewSource {
                DetailAspectRatioPreview(aspectRatio: ratio) { _ in
                    CameraPhotoView(source: previewSource).accessibilityLabel("샘플 카메라 미리보기")
                }
            } else if let camera {
                CameraLivePreviewView(camera: camera, aspectRatio: ratio)
            } else {
                ContentUnavailableView("카메라 연결이 필요해요", systemImage: "camera")
            }
        }
    }

    private var photoSelectionControl: some View {
        Group {
            if let onSelectPhotos {
                Button(action: onSelectPhotos) { selectionLabel }
            } else {
                NavigationLink {
                    ProductPhotoSelectionView(model: model, onComplete: onComplete)
                        .onAppear { onSelectionVisibilityChange(true) }
                        .onDisappear { onSelectionVisibilityChange(false) }
                } label: { selectionLabel }
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(Color(red: 0.94, green: 0.24, blue: 0.07))
        .disabled(isPhotoOperationInProgress)
        .accessibilityIdentifier("camera.selectPhotos")
    }

    private var selectionLabel: some View {
        Text("다음").font(.body.weight(.semibold)).foregroundStyle(.white).frame(minWidth: 44)
    }

    private var shutter: some View {
        CameraShutterControl(isEnabled: canCapture, isCapturing: isPhotoOperationInProgress,
            showsReadyState: canCapture, action: { captureRequested = true })
            .accessibilityLabel(isPhotoOperationInProgress ? "상세 사진 처리 중" : "상세 사진 촬영")
            .accessibilityValue(isPhotoOperationInProgress ? "촬영 중" : canCapture ? "촬영 가능" : "카메라 준비 중")
            .accessibilityHint(previewSource == nil ? "사진을 촬영하고 상세 사진 목록에 추가합니다."
                : "표시된 샘플 사진을 목록에 추가합니다.")
            .accessibilityIdentifier("camera.captureDetail")
    }

    private func shutterFrame(in size: CGSize, bottomSafeAreaInset: CGFloat) -> CameraPhotoViewport? {
        captureControlLayout(in: size, bottomSafeAreaInset: bottomSafeAreaInset)?.shutter
    }

    private func captureControlLayout(in size: CGSize, bottomSafeAreaInset: CGFloat) -> MeasurementCameraChromeLayout.Controls? {
        let rect = DetailAspectRatioPreviewLayout(containerSize: size,
            aspectRatio: camera?.options.photoAspectRatio ?? .fourThree).frame
        return MeasurementCameraChromeLayout.controls(containerWidth: Double(size.width),
            containerHeight: Double(size.height),
            photo: .init(x: Double(rect.minX), y: Double(rect.minY),
                width: Double(rect.width), height: Double(rect.height)),
            bottomSafeAreaInset: Double(bottomSafeAreaInset))
    }

    @ViewBuilder
    private func captureControls(in size: CGSize, bottomSafeAreaInset: CGFloat) -> some View {
        if let controls = captureControlLayout(in: size, bottomSafeAreaInset: bottomSafeAreaInset) {
            let frame = controls.shutter
            let centerY = frame.y + frame.height / 2
            shutter.position(x: frame.x + frame.width / 2, y: centerY)
            CameraMoreButton(isEnabled: !isPhotoOperationInProgress) { isMoreOptionsPresented = true }
                .position(x: controls.more.x + controls.more.width / 2,
                    y: controls.more.y + controls.more.height / 2)
                .accessibilityLabel("촬영 옵션 더보기")
                .accessibilityIdentifier("camera.moreOptions")
            Button { isGalleryPresented = true } label: {
                CameraPhotoView(source: (model.photos.last ?? model.input.measurement).source,
                                maximumPixelSize: 192)
                    .frame(width: 48, height: 48).clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isPhotoOperationInProgress)
            .position(x: controls.accessory.x + controls.accessory.width / 2,
                y: controls.accessory.y + controls.accessory.height / 2)
            .accessibilityLabel("촬영한 사진 보기")
            .accessibilityIdentifier("camera.openGallery")
        }
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

    private var isExitDisabled: Bool {
        isPhotoOperationInProgress || camera?.options.isApplying == true
            || isCaptureGuidePresented || isGalleryPresented
    }

    private func requestExit(_ onExit: () -> Void) {
        guard !isExitDisabled else { return }
        isMoreOptionsPresented = false
        onExit()
    }
}

#Preview {
    CameraDemoEntryView(authorizer: MockCameraAuthorization(), usesSamplePreview: true)
}

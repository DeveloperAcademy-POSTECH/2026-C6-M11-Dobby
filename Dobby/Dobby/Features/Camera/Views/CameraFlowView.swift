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
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: ProductPhotoModel
    let camera: CameraPreviewSession?
    @State private var permission: CameraPermission
    let onComplete: (ProductPhotoOutput) async throws -> Void
    let onExit: (() -> Void)?
    var previewSource: CapturedAsset.Source?
    private let background = Color.black
    @State private var captureRequested = false
    @State private var captureIndicatorPhase: AutomaticMeasurementPhase = .capturing
    @State private var failureMessage: String?
    @State private var isCaptureGuidePresented = false
    @State private var isGalleryPresented = false
    @State private var isMoreOptionsPresented = false
    @State private var librarySaver = DetailPhotoLibrarySaver()
    @State private var isCompletingCapture = false
    @State private var capturePhotosToSave: [CapturedAsset] = []
    @State private var hasStartedLibrarySaving = false
    @State private var didSaveAllCapturePhotos = false
    @State private var captureOutputToSave: ProductPhotoOutput?
    @State private var completionTask: Task<Void, Never>?
    @State private var librarySaveFailure: LibrarySaveFailure?

    private struct LibrarySaveFailure {
        let message: String
        let canOpenSettings: Bool
    }

    init(model: ProductPhotoModel, permission: CameraPermission,
         camera: CameraPreviewSession? = nil,
         previewSource: CapturedAsset.Source? = nil,
         onExit: (() -> Void)? = nil,
         onComplete: @escaping (ProductPhotoOutput) async throws -> Void) {
        self.model = model
        self.camera = camera
        _permission = State(initialValue: permission)
        self.onComplete = onComplete
        self.onExit = onExit
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
        .navigationBarBackButtonHidden(onExit != nil || isCompletingCapture)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(isCompletingCapture ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if let onExit {
                ToolbarItem(placement: .topBarLeading) {
                    Button { requestExit(onExit) } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(.white)
                    }
                        .disabled(isExitDisabled)
                        .accessibilityHidden(isCompletingCapture)
                        .accessibilityLabel("뒤로가기")
                        .accessibilityIdentifier("product-flow.back")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                // 촬영을 마친 전체 사진을 저장한 뒤 상위 흐름에 전달한다.
                completionControl
            }
        }
        .accessibilityHidden(isCompletingCapture)
        .overlay {
            if isCompletingCapture {
                DetailPhotoLibrarySavingOverlay(
                    savedCount: hasStartedLibrarySaving
                        ? min(librarySaver.savedCount, capturePhotosToSave.count) : 0,
                    totalCount: capturePhotosToSave.count)
            }
        }
        .interactiveDismissDisabled(isCompletingCapture)
        .alert("사진을 저장하지 못했어요", isPresented: Binding(
            get: { librarySaveFailure != nil },
            set: { if !$0 { librarySaveFailure = nil } }
        )) {
            Button("다시 시도") { requestCompletion() }
            if librarySaveFailure?.canOpenSettings == true {
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Button("촬영 화면으로", role: .cancel) {}
        } message: {
            if let failure = librarySaveFailure {
                Text("\(librarySaver.totalCount)장 중 \(librarySaver.savedCount)장을 저장했어요.\n\(failure.message)\n촬영 목록은 유지돼요. 이미 저장한 사진은 다시 저장하지 않아요.")
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
            captureIndicatorPhase = .capturing
            do {
                permission.refresh()
                guard permission.status == .authorized else {
                    captureRequested = false
                    return
                }
                try await model.captureDetail()
                captureIndicatorPhase = .completed
                if !reduceMotion { try await Task.sleep(for: .milliseconds(280)) }
            } catch {
                if !(error is CancellationError) && !Task.isCancelled {
                    failureMessage = (error as? CameraFailure ?? .captureFailed).message
                }
            }
            captureRequested = false
        }
        .task(id: isCompletingCapture) {
            guard isCompletingCapture else { return }
            hasStartedLibrarySaving = true
            do {
                try await librarySaver.save(capturePhotosToSave)
                try Task.checkCancellation()
                didSaveAllCapturePhotos = true
                // The Photos authorization dialog temporarily makes the scene
                // inactive. Navigate only after it has returned to the app.
                completeCaptureIfReady()
            } catch {
                let shouldPresentFailure = !(error is CancellationError) && !Task.isCancelled
                didSaveAllCapturePhotos = false
                isCompletingCapture = false
                if shouldPresentFailure {
                    let saveError = error as? DetailPhotoLibrarySaveError
                    let explanation = [saveError?.failureReason, saveError?.recoverySuggestion]
                        .compactMap { $0 }.joined(separator: "\n")
                    librarySaveFailure = LibrarySaveFailure(
                        message: explanation.isEmpty ? error.localizedDescription : explanation,
                        canOpenSettings: saveError?.canOpenSettings == true)
                }
            }
        }
        .onChange(of: permission.status) { _, status in
            if status != .authorized {
                captureRequested = false
                isMoreOptionsPresented = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isMoreOptionsPresented = false }
            if phase == .active { completeCaptureIfReady() }
        }
        // 화면 이탈은 요청만 취소한다. 사진과 선택 결과는 초기화하지 않는다.
        .onDisappear {
            captureRequested = false
            isMoreOptionsPresented = false
            isCompletingCapture = false
            didSaveAllCapturePhotos = false
            completionTask?.cancel()
            completionTask = nil
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
           failureMessage != nil {
            Group {
                if let failureMessage {
                    Text(failureMessage).multilineTextAlignment(.center)
                } else {
                    EmptyView()
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
                DetailAspectRatioPreview(aspectRatio: ratio, extendsPreviewBehindChrome: true) { _ in
                    CameraPhotoView(source: previewSource).accessibilityLabel("샘플 카메라 미리보기")
                }
            } else if let camera {
                CameraLivePreviewView(camera: camera, aspectRatio: ratio,
                    interactionEnabled: !isMoreOptionsPresented && !isPhotoOperationInProgress
                        && !isCaptureGuidePresented && !isGalleryPresented && scenePhase == .active)
            } else {
                ContentUnavailableView("카메라 연결이 필요해요", systemImage: "camera")
            }
        }
    }

    private var completionControl: some View {
        Button(action: requestCompletion) { completionLabel }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(Color(red: 0.94, green: 0.24, blue: 0.07))
        .disabled(isPhotoOperationInProgress || model.allPhotosOutput == nil)
        .accessibilityHidden(isCompletingCapture)
        .accessibilityIdentifier("camera.selectPhotos")
    }

    private var completionLabel: some View {
        Text("다음").font(.body.weight(.semibold)).foregroundStyle(.white).frame(minWidth: 44)
    }

    private var shutter: some View {
        ZStack {
            CameraShutterControl(isEnabled: canCapture, isCapturing: false,
                showsReadyState: canCapture, action: { captureRequested = true })
                .opacity(captureRequested || model.isCapturing ? 0 : 1)
            if captureRequested || model.isCapturing {
                MeasurementProcessingIndicator(phase: captureIndicatorPhase)
            }
        }
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
        DetailCameraPreviewLayout(containerSize: size,
            aspectRatio: camera?.options.photoAspectRatio ?? .fourThree,
            extendsPreviewBehindChrome: true)
            .controls(in: size, bottomSafeAreaInset: bottomSafeAreaInset)
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
                CameraPhotoView(source: (model.photos.last ?? model.selectablePhotos.last)?.source ?? .mockPlaceholder,
                                maximumPixelSize: 192)
                    .frame(width: 48, height: 48).clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isPhotoOperationInProgress || model.selectablePhotos.isEmpty)
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
        guard !isCompletingCapture else { return }
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
            || isCompletingCapture || librarySaver.isSaving
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

    private func requestCompletion() {
        guard !isPhotoOperationInProgress, scenePhase == .active else { return }
        librarySaveFailure = nil
        failureMessage = nil
        isMoreOptionsPresented = false
        guard let output = model.allPhotosOutput else { return }
        captureOutputToSave = output
        didSaveAllCapturePhotos = false
        capturePhotosToSave = output.selectedPhotos
        hasStartedLibrarySaving = false
        isCompletingCapture = true
    }

    private func completeCaptureIfReady() {
        guard isCompletingCapture, didSaveAllCapturePhotos, scenePhase == .active,
              completionTask == nil, let output = captureOutputToSave else { return }
        // Keep the saving overlay and input lock through the app-product handoff.
        // A second foreground notification must not start another completion.
        completionTask = Task { @MainActor in
            defer {
                completionTask = nil
                didSaveAllCapturePhotos = false
                isCompletingCapture = false
            }
            do {
                try Task.checkCancellation()
                try await onComplete(output)
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                librarySaveFailure = LibrarySaveFailure(
                    message: "사진 앱 저장은 완료했지만 상품 정보를 반영하지 못했어요.\n\(error.localizedDescription)",
                    canOpenSettings: false)
            }
        }
    }

}

#Preview {
    CameraDemoEntryView(authorizer: MockCameraAuthorization(), usesSamplePreview: true)
}

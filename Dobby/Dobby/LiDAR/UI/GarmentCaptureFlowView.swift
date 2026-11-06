import SwiftUI
import UIKit

/// Product capture flow; the measurement lab remains available independently.
struct GarmentCaptureFlowView: View {
    @StateObject private var captureSession = GarmentCaptureSession()
    private var camera: ARKitCaptureProvider { captureSession.camera }
    private var service: RecordedMeasurementService? { captureSession.service }
    private var loadingError: String? { captureSession.loadingError }
    private let archive: MeasurementArchive
    private let previewKind: AutomaticGarmentKind
    private let isPreview: Bool
    private let previewIsPartial: Bool
    private let previewBothSidesPartial: Bool
    private let previewMissingTopLength: Bool
    private let onConfirmedRecord: ((SavedMeasurement) async throws -> Void)?
    @State private var restoredRecord: SavedMeasurement?
    private let allowsRetake: Bool
    private let onCancel: (() -> Void)?
    private let embedsNavigation: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var guidanceFontSize: CGFloat = 14
    @State private var orientation: ImageOrientation = .right
    @State private var model: AutomaticMeasurement?
    @State private var previewModel: AutomaticMeasurement?
    @State private var previewRecognized = false
    @State private var isCapturing = false
    @State private var phase: AutomaticMeasurementPhase = .idle
    @State private var captureTask: Task<Void, Never>?
    @State private var cameraRestartTask: Task<Void, Never>?
    @State private var runID: UUID?
    @State private var captureFailure: WorkflowFailureFeedback?
    @State private var recordingError: String?
    @State private var processingSnapshot: CaptureSnapshot?
    @State private var processingImage: UIImage?
    @State private var captureViewportSize: CGSize = .zero
    @State private var processingViewportSize: CGSize = .zero
    @State private var previewControls = CameraControlState(sessionID: UUID())
    @State private var previewFocusVisible = false
    @State private var syntheticOptions = SyntheticMeasurementCameraOptions()
    @State private var showsCameraOptions = false
    @State private var displayedAspectRatio: DetailPhotoAspectRatio = .fourThree
    @State private var isChangingAspectRatio = false
    @State private var aspectTransitionID: UUID?
    @AppStorage("dobby.measurementCapture.skipPlacementTutorial.v1") private var skipsPlacementTutorial = false
    @State private var showsPlacementTutorial = false
    @State private var previewSkipsPlacementTutorial = false
    @StateObject private var levelGuide = GarmentCameraLevelGuide()

    init(archive: MeasurementArchive = MeasurementArchive(), preview: Bool = false,
         onConfirmedRecord: ((SavedMeasurement) async throws -> Void)? = nil,
         onCancel: (() -> Void)? = nil, embedsNavigation: Bool = true,
         restoredRecord: SavedMeasurement? = nil,
         allowsRetake: Bool = true) {
        self.archive = archive
        self.isPreview = preview
        self.onConfirmedRecord = onConfirmedRecord
        _restoredRecord = State(initialValue: restoredRecord)
        self.allowsRetake = allowsRetake
        _model = State(initialValue: restoredRecord.map(AutomaticMeasurement.init(record:)))
        self.onCancel = onCancel
        self.embedsNavigation = embedsNavigation
        // Fixture selection affects only the labelled synthetic preview.
        // The physical camera always classifies its own current image.
        self.previewKind = preview && ProcessInfo.processInfo.arguments.contains("--garment-preview-top") ? .top : .bottoms
        self.previewIsPartial = preview && ProcessInfo.processInfo.arguments.contains("--garment-preview-partial")
        self.previewBothSidesPartial = preview && ProcessInfo.processInfo.arguments.contains("--garment-preview-both-sides-partial")
        self.previewMissingTopLength = preview && ProcessInfo.processInfo.arguments.contains("--garment-preview-missing-top-length")
    }

    var body: some View {
        captureNavigation {
            Group {
                if let model {
                    GarmentMeasurementResultView(model: model, archive: archive, recordingError: recordingError,
                        initialImage: processingImage, onRetake: retake,
                        onConfirm: { if onConfirmedRecord == nil { dismiss() } },
                        onConfirmedRecord: onConfirmedRecord,
                        initialRecord: restoredRecord, allowsRetake: allowsRetake)
                } else {
                    cameraScreen
                        .navigationTitle("실측 촬영")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    cancel()
                                    if let onCancel { onCancel() } else { dismiss() }
                                } label: { GarmentCaptureToolbarIcon(systemName: "chevron.left") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("촬영 닫기")
                                    .accessibilityIdentifier("closeGarmentCapture")
                            }.sharedBackgroundVisibility(.hidden)
                        }
                }
            }
            .toolbarBackground(model == nil ? Color.clear : Color.white, for: .navigationBar)
            .toolbarBackground(model == nil ? .hidden : .visible, for: .navigationBar)
            .background {
                if model == nil { GarmentCaptureStyle.background.ignoresSafeArea() }
                else { Color.white.ignoresSafeArea() }
            }
        }
        .disabled(captureFailure != nil)
        .allowsHitTesting(captureFailure == nil)
        .accessibilityHidden(captureFailure != nil)
        .tint(model == nil ? .white : .primary)
        .preferredColorScheme(model == nil ? .dark : .light)
        .task {
            // A result tutorial may temporarily cover this flow. Returning to
            // that result must not restart a camera or reset placement guidance.
            guard model == nil else { return }
            showsPlacementTutorial = isPreview
                ? ProcessInfo.processInfo.arguments.contains("--garment-preview-capture-tutorial")
                : !skipsPlacementTutorial && camera.isSupported && loadingError == nil
            if !isPreview { levelGuide.start() }
            if isPreview {
                previewModel = GarmentCapturePreview.measurement(partial: previewIsPartial,
                    bothSidesPartial: previewBothSidesPartial, missingTopLength: previewMissingTopLength, kind: previewKind)
                synchronizePreviewOptions()
            }
            else {
                // Camera startup and lightweight service setup run independently.
                // Semantic models still analyze the frozen photo; the product
                // shutter separately requires a visible live foreground outline.
                async let preparation: Void = captureSession.prepare()
                await camera.start()
                await preparation
            }
        }
        .onChange(of: orientation) { _, value in
            clearPreviewFocus()
            // Before the snapshot, rotation invalidates an in-flight shutter.
            // Once frozen, inference keeps that photo's original orientation.
            let interruptedCapture = isCapturing && processingSnapshot == nil
            if interruptedCapture { cancel() }
            camera.updateImageOrientation(value)
            // Inference pauses ARKit. Cancelling that stage must restore a
            // usable preview even though the cancelled task cannot publish.
            if interruptedCapture, !isPreview, model == nil, scenePhase == .active {
                restartCamera()
            }
        }
        .onChange(of: permissionDenied) { _, denied in
            if denied { showsPlacementTutorial = false }
        }
        .onChange(of: loadingError) { _, error in
            if error != nil { showsPlacementTutorial = false }
        }
        .onChange(of: captureOptions.photoAspectRatio) { _, ratio in changePhotoAspectRatio(to: ratio) }
        .onChange(of: captureOptions.appliedExposure) { _, bias in
            guard isPreview, let bias, bias.isFinite else { return }
            previewControls.requestedExposureBias = bias
            previewControls.exposureBias = bias
        }
        .onChange(of: scenePhase) { _, value in
            if value != .active {
                closeCameraOptions()
                aspectTransitionID = nil
                isChangingAspectRatio = false
                levelGuide.stop(); clearPreviewFocus(); cancel(); camera.stop(); previewRecognized = false
                if isPreview { synchronizePreviewOptions(invalidate: true) }
            }
            else if !isPreview, model == nil { levelGuide.start(); restartCamera() }
            else if isPreview { synchronizePreviewOptions() }
        }
        .onDisappear {
            closeCameraOptions()
            aspectTransitionID = nil
            isChangingAspectRatio = false
            levelGuide.stop(); clearPreviewFocus(); cancel(); camera.stop()
            if isPreview { syntheticOptions.synchronize(exposure: 0, available: false, invalidatePendingRequests: true) }
        }
        .onChange(of: model == nil) { _, isCamera in
            if isCamera, !isPreview { levelGuide.start() } else { levelGuide.stop() }
        }
        .task(id: processingSnapshot?.frame.frameID) {
            guard let snapshot = processingSnapshot else { return }
            let image = await SnapshotPresentation.thumbnail(for: snapshot, maximumDimension: 1024)
            guard !Task.isCancelled, processingSnapshot?.frame.frameID == snapshot.frame.frameID else { return }
            processingImage = image
        }
        .overlay {
            if captureFailure != nil {
                MeasurementCaptureFailureOverlay(onConfirm: dismissCaptureFailure)
            }
        }
    }

    @ViewBuilder
    private func captureNavigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if embedsNavigation {
            NavigationStack { content() }
        } else {
            content()
        }
    }

    private var cameraScreen: some View {
        // Read the same navigation-safe container inset as CameraFlowView
        // before the live canvas expands to the complete camera screen.
        GeometryReader { safeGeometry in
            cameraCanvas(bottomSafeAreaInset: safeGeometry.safeAreaInsets.bottom)
        }
        .background(GarmentCaptureStyle.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentCaptureScreen")
    }

    private func cameraCanvas(bottomSafeAreaInset: CGFloat) -> some View {
        GeometryReader { geometry in
            let photoRect = photoViewport(in: geometry.size)
            ZStack {
                Color.black
                // A photo's 1x is its complete sensor field of view. Filling the
                // entire tall phone first would add an unlabelled ~1.63x crop.
                cameraImage
                    .modifier(MeasurementPhotoViewportModifier(rect: photoRect))
                    .accessibilityHidden(showsPlacementTutorial)
                CameraBlackSurroundings(photoRect: photoRect)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                cameraFeedback
                if !showsCameraOptions {
                    responsiveCameraChrome(in: geometry.size, photoRect: photoRect,
                        bottomSafeAreaInset: bottomSafeAreaInset)
                        .animation(presentationReduceMotion ? nil : .smooth(duration: 0.30), value: displayedAspectRatio)
                        .animation(nil, value: geometry.size)
                        .opacity(showsPlacementTutorial ? 0 : 1)
                        .accessibilityHidden(showsPlacementTutorial)
                        .transition(.opacity)
                }
                if !showsCameraOptions {
                    captureControls(in: geometry.size, bottomSafeAreaInset: bottomSafeAreaInset)
                        .animation(presentationReduceMotion ? nil : .smooth(duration: 0.30), value: displayedAspectRatio)
                        .animation(nil, value: geometry.size)
                        .transition(.opacity)
                        .accessibilityHidden(showsPlacementTutorial || showsCameraOptions)
                }
                if shouldShowLevelGuide, !showsPlacementTutorial, !showsCameraOptions {
                    VStack(spacing: 109) {
                        Image("MeasurementLevelTop").resizable().scaledToFit().frame(width: 161, height: 23)
                        Image("MeasurementLevelBottom").resizable().scaledToFit().frame(width: 229, height: 38)
                    }
                    .position(x: photoRect.midX,
                        y: photoRect.minY + photoRect.height * (389.5 - 146) / 536)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("카메라를 바닥과 평행하게 맞춰주세요")
                    .accessibilityIdentifier("garmentCameraLevelGuide")
                    .allowsHitTesting(false)
                }
                if showsPlacementTutorial {
                    GarmentCaptureTutorialView(skipsTutorial: isPreview ? $previewSkipsPlacementTutorial : $skipsPlacementTutorial) {
                        showsPlacementTutorial = false
                    }
                }
                cameraOptionsOverlay(in: geometry.size, bottomSafeAreaInset: bottomSafeAreaInset)
                    .allowsHitTesting(showsCameraOptions)
                    .accessibilityHidden(!showsCameraOptions)
                    .zIndex(2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { captureViewportSize = photoRect.size }
            .onChange(of: photoRect.size) { _, size in
                captureViewportSize = size
                clearPreviewFocus()
            }
            .onChange(of: geometry.size) { _, _ in
                if isPreview { previewRecognized = false }
            }
        }
        .ignoresSafeArea()
    }

    private var cameraSourceAspectRatio: CGFloat {
        // A failed photo can remain available for manual recovery. Once live
        // capture resumes, that old photo must not dictate its orientation.
        if isCapturing, let snapshot = processingSnapshot { return SnapshotPresentation.aspectRatio(for: snapshot) }
        if isPreview, let previewModel { return SnapshotPresentation.aspectRatio(for: previewModel.snapshot) }
        // Only the initial empty preview needs a default. The first delivered
        // frame supplies its real dimensions without copying any camera pixels.
        let size = camera.frameStatus?.imageSize ?? PixelSize(width: 1920, height: 1440)
        let quarterTurn = orientation == .left || orientation == .right
        return CGFloat(quarterTurn ? size.height : size.width) / CGFloat(quarterTurn ? size.width : size.height)
    }

    private var captureOptions: DetailCameraOptions { isPreview ? syntheticOptions.options : captureSession.cameraOptions }

    private var cameraPhotoAspectRatio: CGFloat {
        if isCapturing, let snapshot = processingSnapshot {
            return SnapshotPresentation.aspectRatio(for: snapshot)
                * CGFloat((snapshot.capturePresentationCrop ?? snapshot.presentationCrop ?? .full).width
                    / (snapshot.capturePresentationCrop ?? snapshot.presentationCrop ?? .full).height)
        }
        let ratio = MeasurementPhotoAspectRatio(rawValue: displayedAspectRatio.rawValue) ?? .fourThree
        let size = isPreview ? previewModel?.snapshot.frame.imageSize : camera.frameStatus?.imageSize
        let imageOrientation = isPreview ? previewModel?.snapshot.frame.orientation ?? .up : orientation
        guard let size, let crop = ratio.displayCrop(imageSize: size, orientation: imageOrientation) else {
            return cameraSourceAspectRatio
        }
        return cameraSourceAspectRatio * CGFloat(crop.width / crop.height)
    }

    private func changePhotoAspectRatio(to ratio: DetailPhotoAspectRatio) {
        guard !isCapturing, displayedAspectRatio != ratio else { return }
        clearPreviewFocus()
        if isPreview { previewRecognized = false }
        let transition = UUID()
        aspectTransitionID = transition
        isChangingAspectRatio = !presentationReduceMotion
        withAnimation(presentationReduceMotion ? nil : .smooth(duration: 0.30), completionCriteria: .logicallyComplete) {
            displayedAspectRatio = ratio
        } completion: {
            guard aspectTransitionID == transition else { return }
            isChangingAspectRatio = false
        }
    }

    private func photoViewport(in size: CGSize) -> CGRect {
        guard let window = MeasurementCameraChromeLayout.photoViewport(containerWidth: Double(size.width),
            containerHeight: Double(size.height), photoAspectRatio: Double(cameraPhotoAspectRatio)) else { return .zero }
        return CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
    }

    @ViewBuilder
    private func responsiveCameraChrome(in size: CGSize, photoRect: CGRect, bottomSafeAreaInset: CGFloat) -> some View {
        let photo = CameraPhotoViewport(x: Double(photoRect.minX), y: Double(photoRect.minY),
            width: Double(photoRect.width), height: Double(photoRect.height))
        let labelWidth = max(44, min(380, photoRect.width - 32) - 32 - (isCapturing ? 26 : 0))
        let textHeight = (guidance as NSString).boundingRect(
            with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.systemFont(ofSize: guidanceFontSize, weight: .semibold)], context: nil).height
        let labelHeight = max(44, ceil(textHeight) + 20)
        if let chrome = MeasurementCameraChromeLayout.layout(containerWidth: Double(size.width),
            containerHeight: Double(size.height), photo: photo, guidanceHeight: Double(labelHeight),
            shutter: shutterFrame(in: size, bottomSafeAreaInset: bottomSafeAreaInset)) {
            if let frame = chrome.guidanceFrame {
                recognitionGuidance
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            }
            zoomSelector
                .position(x: chrome.zoomCenterX, y: chrome.zoomCenterY)
        }
    }

    private var shouldShowLevelGuide: Bool {
        !isCapturing && !silhouetteVisible && (isPreview
            ? ProcessInfo.processInfo.arguments.contains("--garment-preview-level-guide")
            : levelGuide.needsLevelAdvice)
    }

    private var selectedZoom: CameraZoom { isPreview ? previewControls.selectedZoom : camera.cameraControls.selectedZoom }
    private var nextZoom: CameraZoom { selectedZoom == .standard ? .double : .standard }

    private var zoomSelector: some View {
        Button { selectZoom(nextZoom) } label: {
            Text(selectedZoom == .standard ? "1x" : "2x")
                .font(.system(size: guidanceFontSize, weight: .semibold))
                .foregroundStyle(CameraZoomStyle.selectedText).frame(width: 48, height: 48)
                .glassEffect(.regular.tint(.black.opacity(0.18)).interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canUseCameraControls || !controlCapabilities.availableZooms.contains(nextZoom))
        .accessibilityLabel("촬영 배율")
        .accessibilityValue(selectedZoom == .standard ? "1x" : "2x")
        .accessibilityHint(nextZoom == .double ? "탭하면 2배로 전환합니다" : "탭하면 1배로 전환합니다")
        .accessibilityIdentifier("cameraZoomSelector")
        .accessibilityHidden(showsPlacementTutorial || showsCameraOptions)
    }

    private func selectZoom(_ zoom: CameraZoom) {
        guard canUseCameraControls, controlCapabilities.availableZooms.contains(zoom) else { return }
        clearPreviewFocus()
        if isPreview { previewRecognized = false; previewControls.selectedZoom = zoom }
        else { camera.setZoom(zoom) }
    }

    private var cameraOptionsButton: some View {
        CameraMoreButton(isEnabled: captureFailure == nil && !isCapturing, action: openCameraOptions)
            .accessibilityLabel("촬영 옵션")
            .accessibilityIdentifier("garmentCaptureOptions")
            .accessibilityHidden(showsCameraOptions)
    }

    private func openCameraOptions() {
        guard captureFailure == nil, !isCapturing, model == nil else { return }
        if isPreview { synchronizePreviewOptions() }
        else { captureSession.synchronizeCameraOptions() }
        clearPreviewFocus()
        showsCameraOptions = true
    }

    private func closeCameraOptions() {
        showsCameraOptions = false
    }

    private func cameraOptionsOverlay(in size: CGSize, bottomSafeAreaInset: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            let panel = CameraOptionsPanelLayout(containerSize: size, bottomSafeAreaInset: bottomSafeAreaInset)
            if showsCameraOptions {
                Button { closeCameraOptions() } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("촬영 옵션 닫고 미리보기로 돌아가기")
                    .accessibilityIdentifier("camera.dismissOptions")
                // Both cameras share the same 4:3-anchored panel bounds.
                DetailCaptureOptionsView(options: captureOptions,
                    exposureSelectionFeedbackEnabled: true,
                    panelLayout: panel) { closeCameraOptions() }
                    .position(x: panel.frame.midX, y: panel.frame.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(showsCameraOptions ? .isModal : [])
        .accessibilityIdentifier("measurementCameraOptions")
    }

    private var cameraImage: some View {
        ZStack {
            if isCapturing, let snapshot = processingSnapshot {
                Color.black
                if let processingImage {
                    GeometryReader { geometry in
                        // Analysis retains the complete captured RGB/depth.
                        // This frozen preview uses the same full-photo window
                        // as the live camera. The registered 2x snapshot already
                        // contains its crop, so never apply selected zoom again.
                        Canvas { context, _ in
                            let layout = GarmentPhotoGeometry.processingPhotoLayout(
                                photoAspectRatio: SnapshotPresentation.aspectRatio(for: snapshot),
                                capturedViewportSize: processingViewportSize, viewportSize: geometry.size)
                            context.clip(to: Path(layout.viewportRect))
                            context.draw(context.resolve(Image(uiImage: processingImage)),
                                in: layout.photoRect)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isImage)
                        .accessibilityLabel("촬영한 사진의 측정점을 확인 중")
                        .accessibilityIdentifier("garmentProcessingPhoto")
                    }
                } else { ProgressView("촬영한 사진 준비 중").tint(.white) }
            } else if isPreview, let previewModel, let image = SnapshotPresentation.image(for: previewModel.snapshot) {
                GeometryReader { geometry in
                    let aspect = SnapshotPresentation.aspectRatio(for: previewModel.snapshot)
                    let factor: CGFloat = previewControls.selectedZoom == .double ? 2 : 1
                    let width = max(geometry.size.width, geometry.size.height * aspect) * factor
                    let height = width / aspect
                    let transform = CameraAffineTransform(a: Double(width / geometry.size.width), b: 0, c: 0,
                        d: Double(height / geometry.size.height),
                        tx: Double((geometry.size.width - width) / (2 * geometry.size.width)),
                        ty: Double((geometry.size.height - height) / (2 * geometry.size.height)))
                    ZStack {
                        ZStack {
                            Image(uiImage: image).resizable()
                            if previewRecognized, !hidesPreviewOutline, let mask = previewModel.landmarks.mask {
                                GarmentSilhouetteOverlay(mask: mask, sourceID: previewModel.snapshot.frame.sessionID,
                                    forceReduceMotion: presentationReduceMotion)
                            }
                        }
                        .frame(width: width, height: height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        SyntheticCameraControlSurface(state: previewControls, capabilities: controlCapabilities,
                            transform: transform, isEnabled: canFocus, focusVisible: previewFocusVisible,
                            onFocus: setPreviewFocus, onExposure: setPreviewExposure,
                            onExposureAdjustmentActive: { _ in })
                            // Keep synthetic gesture coordinates in the visible
                            // photo window, not the enlarged 2x image's ideal size.
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onChange(of: geometry.size) { _, _ in clearPreviewFocus() }
                }.clipped()
            } else if !isPreview, camera.isSupported, loadingError == nil {
                ZoomedCameraPreview(session: camera.session, readiness: camera.liveReadiness, orientation: $orientation,
                    controlState: camera.cameraControls,
                    focusEnabled: canFocus,
                    capabilities: camera.cameraCapabilities, onFocus: camera.requestFocus,
                    onExposure: camera.requestExposureBias,
                    onExposureAdjustmentActive: camera.setExposureAdjustmentActive)
            } else {
                Rectangle().fill(.black)
            }
            if !isPreview, !camera.isSupported || loadingError != nil || permissionDenied {
                VStack(spacing: 16) {
                    Image(systemName: "camera").font(.largeTitle)
                    Text(unavailableMessage).font(.body).multilineTextAlignment(.center)
                    if permissionDenied {
                        Button("설정에서 카메라 허용") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.borderedProminent).tint(GarmentCaptureStyle.accent)
                    }
                }.padding(32)
            }
            if silhouetteVisible, !hidesPreviewOutline {
                Color.clear.accessibilityElement().accessibilityLabel("촬영을 돕는 옷 윤곽 미리보기")
                    .accessibilityIdentifier("garmentSilhouette").allowsHitTesting(false)
            }
        }.clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("garmentCameraViewport")
    }

    /// Progress belongs to the screen chrome, not the sensor-to-photo transform.
    private var cameraFeedback: some View {
        VStack(spacing: 0) {
            if isCapturing {
                processingProgress.padding(.top, 154)
            }
            if isPreview {
                Text("화면 미리보기 · 합성 카메라 조절 · 실제 측정 아님")
                    .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.65), in: Capsule()).padding(.top, isCapturing ? 8 : 154)
                    .opacity(showsPlacementTutorial ? 0 : 1)
                    .accessibilityIdentifier("garmentPreviewProvenance")
            }
            Spacer(minLength: 24)
        }.allowsHitTesting(false)
    }

    private var outlineCue: Bool { canTakePhoto }

    /// The launch flag affects only the labelled synthetic preview. Physical
    /// capture always follows the user's accessibility setting.
    private var presentationReduceMotion: Bool {
        reduceMotion || (isPreview && ProcessInfo.processInfo.arguments.contains("--garment-preview-reduce-motion"))
    }

    private var hidesPreviewOutline: Bool {
        isPreview && ProcessInfo.processInfo.arguments.contains("--garment-preview-no-outline")
    }

    /// The same outline state drives the guide, orange center and shutter gate.
    /// Foreground detection does not certify the later garment measurements.
    private var recognitionGuidance: some View {
        HStack(spacing: 8) {
            if isCapturing {
                ProgressView().controlSize(.small).tint(.white).frame(width: 18)
            }
            Text(guidance).multilineTextAlignment(.center)
        }.font(.system(size: guidanceFontSize, weight: .semibold)).foregroundStyle(.white)
            .frame(minHeight: 20)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .transaction { $0.animation = nil }
            .background {
                ZStack {
                    Capsule().fill(GarmentCaptureStyle.guidance)
                    Capsule().fill(GarmentCaptureStyle.recognition)
                        .animation(presentationReduceMotion || !outlineCue ? nil : .easeInOut(duration: 0.20)) { content in
                            content.opacity(outlineCue ? 1 : 0)
                        }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(guidance)
            .accessibilityHint("옷 윤곽이 인식되어 셔터에 주황색 점이 나타나면 촬영할 수 있어요")
            .accessibilityIdentifier("captureGuidance")
            .accessibilityHidden(showsPlacementTutorial || showsCameraOptions)
            // This is advisory text, not a control. It must not swallow taps
            // intended for the camera's immediate focus/exposure recognizer.
            .allowsHitTesting(false)
    }

    private func captureControlLayout(in size: CGSize, bottomSafeAreaInset: CGFloat) -> MeasurementCameraChromeLayout.Controls? {
        let rect = photoViewport(in: size)
        return MeasurementCameraChromeLayout.controls(containerWidth: Double(size.width),
            containerHeight: Double(size.height),
            photo: .init(x: Double(rect.minX), y: Double(rect.minY),
                width: Double(rect.width), height: Double(rect.height)),
            bottomSafeAreaInset: Double(bottomSafeAreaInset))
    }

    private func shutterFrame(in size: CGSize, bottomSafeAreaInset: CGFloat) -> CameraPhotoViewport? {
        captureControlLayout(in: size, bottomSafeAreaInset: bottomSafeAreaInset)?.shutter
    }

    @ViewBuilder
    private func captureControls(in size: CGSize, bottomSafeAreaInset: CGFloat) -> some View {
        if let controls = captureControlLayout(in: size, bottomSafeAreaInset: bottomSafeAreaInset) {
            let shutter = controls.shutter
            let centerX = shutter.x + shutter.width / 2
            let centerY = shutter.y + shutter.height / 2
            measurementShutter.position(x: centerX, y: centerY)
            cameraOptionsButton.position(x: controls.more.x + controls.more.width / 2,
                y: controls.more.y + controls.more.height / 2)
                .opacity(showsPlacementTutorial ? 0 : 1)
            if size.height >= 280 {
                VStack(spacing: 8) {
                    CameraControlPanel(errorMessage: isPreview ? nil : camera.controlError)
                    if isPreview, !isCapturing, !showsPlacementTutorial {
                        Button(previewRecognized ? "인식 해제" : "윤곽 미리보기") { previewRecognized.toggle() }
                            .font(.caption).accessibilityIdentifier("previewRecognizeGarment")
                            .accessibilityHidden(showsCameraOptions)
                    }
                }
                .frame(width: min(380, size.width - 32), height: max(0, shutter.y - 16), alignment: .bottom)
                .position(x: centerX, y: max(0, shutter.y - 16) / 2)
            }
        }
    }

    private var measurementShutter: some View {
        GarmentShutterButton(isEnabled: canTakePhoto, isCapturing: isCapturing,
            showsRecognizedState: canTakePhoto, action: takePhoto, forceReduceMotion: presentationReduceMotion)
            .accessibilityHint(isCapturing ? "촬영한 사진의 측정점과 길이를 계산하고 있습니다"
                : isPreview && previewControls.selectedZoom == .double
                ? "합성 촬영 결과는 1배에서 확인해요. 1배로 돌아와 옷 윤곽을 다시 인식해 주세요"
                : "옷 윤곽이 인식되어 주황색 점이 나타나면 촬영할 수 있습니다")
            .accessibilityHidden(showsPlacementTutorial || showsCameraOptions)
    }

    private var controlCapabilities: CameraControlCapabilities {
        isPreview ? .init(focusSupported: true, meteringSupported: true,
                          exposureRange: .init(minimum: -2, maximum: 2), availableZooms: [.standard, .double]) : camera.cameraCapabilities
    }

    private func setPreviewFocus(_ point: ImagePoint, requestID: UUID) {
        guard canFocus, point.isValid else { return }
        // A labelled synthetic control state, never a hardware observation.
        previewControls.focusPoint = point
        previewControls.focusRequestID = requestID
        previewControls.focusStatus = .accepted
        previewControls.aeafStatus = .unlocked
        previewControls.requestedExposureBias = 0
        previewControls.exposureBias = 0
        previewFocusVisible = true
        synchronizePreviewOptions(invalidate: true)
    }

    private func setPreviewExposure(_ bias: Double) {
        guard canFocus, let target = controlCapabilities.exposureRange?.clamp(bias) else { return }
        // This fixture never changes a camera or establishes sensor response.
        previewControls.requestedExposureBias = target
        previewControls.exposureBias = target
        synchronizePreviewOptions(invalidate: true)
    }

    private func synchronizePreviewOptions(invalidate: Bool = false) {
        syntheticOptions.synchronize(exposure: previewControls.exposureBias,
            available: previewModel != nil && !isCapturing && scenePhase == .active,
            invalidatePendingRequests: invalidate)
    }

    private func clearPreviewFocus() {
        previewFocusVisible = false
        previewControls.focusPoint = nil
        previewControls.focusRequestID = nil
        previewControls.focusStatus = .idle
        previewControls.aeafStatus = .unlocked
    }

    /// Recognition availability and the orange center must agree. The action
    /// checks this again, so a stale enabled view cannot capture after mask loss.
    /// Synthetic 2x cannot claim a calibrated capture from its fixed 1x input.
    private var canTakePhoto: Bool {
        canUseCameraControls && silhouetteVisible && !showsPlacementTutorial && !showsCameraOptions
            && (isPreview || (service != nil && camera.frameStatus?.hasDepth == true))
            && !isChangingAspectRatio && !captureOptions.isApplying && scenePhase == .active
            && (!isPreview || previewControls.selectedZoom != .double)
    }
    /// Tapping to focus does not depend on garment recognition or the
    /// measurement service being ready. The camera owns autofocus support.
    private var canFocus: Bool {
        guard captureFailure == nil, !isCapturing, !showsCameraOptions, !isChangingAspectRatio else { return false }
        if isPreview { return previewModel != nil }
        return camera.isRunning && camera.cameraCapabilities.focusSupported
    }
    private var canUseCameraControls: Bool {
        guard captureFailure == nil, !isCapturing, !showsCameraOptions, !isChangingAspectRatio else { return false }
        if isPreview { return previewModel != nil }
        return camera.isRunning && camera.state == .ready
    }
    private var silhouetteVisible: Bool {
        !isCapturing && (isPreview ? previewRecognized : camera.liveReadiness.silhouette != nil)
    }
    private var permissionDenied: Bool { camera.state == .unavailable(.cameraPermissionDenied) }
    private var unavailableMessage: String {
        if let loadingError { return "옷 인식 모델을 불러오지 못했어요.\n" + loadingError }
        if permissionDenied { return "실측하려면 카메라 접근을 허용해 주세요." }
        return "이 기기에서는 LiDAR 실측 촬영을 사용할 수 없어요.\nLiDAR가 있는 iPhone에서 실행해 주세요."
    }
    private var guidance: String {
        if isCapturing {
            switch phase {
            case .detectingLandmarks: return "촬영한 옷의 측정점을 찾고 있어요"
            case .measuring, .completed: return "실제 길이를 계산하고 있어요"
            default: return "사진과 깊이를 확보하고 있어요. 잠시만 멈춰주세요"
            }
        }
        if isPreview, previewControls.selectedZoom == .double { return "2× 조절 미리보기 · 합성 촬영은 1×에서 확인해요" }
        if captureOptions.isApplying { return "노출 설정을 적용하고 있어요" }
        if !isPreview {
            switch camera.state {
            case .failed, .interrupted: return "카메라 연결이 중단됐어요. 다시 촬영 화면을 열어주세요"
            case .requestingPermission: return "카메라 접근을 허용해 주세요"
            case .ready: break
            default: return "카메라를 준비하고 있어요"
            }
            guard camera.frameStatus?.hasDepth == true else { return "LiDAR 깊이 데이터를 준비하고 있어요" }
            guard service != nil else { return "측정 기능을 준비하고 있어요" }
        }
        if shouldShowLevelGuide { return "핸드폰을 수평으로 들어주세요" }
        if canTakePhoto { return "옷 인식 완료! 촬영 버튼을 눌러주세요" }
        if canUseCameraControls { return "옷이 잘리지 않게 카메라 안에 넣어주세요" }
        if isPreview { return "옷 한 벌 전체가 보이도록 평평하게 펼쳐주세요" }
        return "카메라를 준비하고 있어요"
    }

    private var processingProgress: some View {
        HStack(spacing: 14) {
            progressStep("사진", complete: processingSnapshot != nil, active: phase == .capturing)
            progressStep("측정점", complete: phase == .measuring || phase == .completed,
                active: phase == .detectingLandmarks)
            progressStep("길이", complete: phase == .completed, active: phase == .measuring)
        }.font(.caption.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
            .background(.black.opacity(0.75), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityValue(processingProgressDescription)
            .accessibilityIdentifier("garmentMeasurementProgress")
    }

    private var processingProgressDescription: String {
        switch phase {
        case .detectingLandmarks: "사진 완료 · 측정점 확인 중 · 길이 대기"
        case .measuring: "사진 완료 · 측정점 완료 · 길이 계산 중"
        case .completed: "사진 완료 · 측정점 완료 · 길이 완료"
        default: "사진과 깊이 확보 중 · 측정점 대기 · 길이 대기"
        }
    }

    private func progressStep(_ title: String, complete: Bool, active: Bool) -> some View {
        HStack(spacing: 5) {
            if active { ProgressView().controlSize(.mini).tint(.white) }
            else { Image(systemName: complete ? "checkmark.circle.fill" : "circle") }
            Text(title)
        }.foregroundStyle(complete || active ? .white : .white.opacity(0.45))
    }

    private func takePhoto() {
        guard canTakePhoto, !isCapturing else { return }
        clearPreviewFocus()
        if isPreview, let previewModel { takePreviewPhoto(previewModel); return }
        guard let service else { return }
        let viewport = captureViewportSize
        processingViewportSize = viewport
        let token = UUID()
        runID = token
        processingSnapshot = nil
        processingImage = nil
        captureFailure = nil
        isCapturing = true
        phase = .capturing
        captureTask = Task {
            do {
                let output = try await service.run(orientation: orientation, purpose: .automaticModel,
                    isSynthetic: false, deviceContext: SnapshotPresentation.deviceIdentifier,
                    onPhaseChange: { value in
                        guard runID == token else { return }
                        phase = value
                    }, onSnapshot: { snapshot in
                        guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                        processingSnapshot = framedSnapshot(snapshot, viewport: viewport)
                        camera.pauseForMeasurement()
                    })
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                guard let measuredKind = output.workflowOutput.landmarks.garmentKind else {
                    throw AutomaticMeasurementWorkflowFailure(stage: .landmarks, code: .invalidProvenance,
                        message: "촬영한 옷의 종류를 확인하지 못했습니다. 옷 한 벌 전체가 보이도록 다시 촬영해 주세요.")
                }
                recordingError = output.recordingError
                let context = MeasurementTestContext(category: measuredKind.category,
                    deviceModel: SnapshotPresentation.deviceIdentifier)
                let measured = AutomaticMeasurement(output: output.workflowOutput, context: context)
                var framedOutput = output.workflowOutput
                framedOutput.snapshot = framedSnapshot(framedOutput.snapshot, viewport: viewport,
                    including: measured.landmarks.points + measured.visibleEditableLandmarks.points,
                    endpoints: measured.visibleValues.filter(\.hasUsableMeasurement).flatMap { $0.points.map(\.imagePoint) })
                model = AutomaticMeasurement(output: framedOutput, context: context)
            } catch {
                finishFailedCapture(error, token: token)
            }
            if runID == token { runID = nil; isCapturing = false; captureTask = nil }
        }
    }

    /// Rehearses the same frozen-photo stages with explicitly synthetic data.
    /// Observation delays exist only in the dedicated UI test fixture.
    private func takePreviewPhoto(_ preview: AutomaticMeasurement) {
        let preview = framedPreview(preview, viewport: captureViewportSize)
        processingViewportSize = captureViewportSize
        let token = UUID()
        runID = token
        processingSnapshot = preview.snapshot
        processingImage = nil
        captureFailure = nil
        isCapturing = true
        phase = .capturing
        captureTask = Task {
            do {
                try await previewStagePause(.milliseconds(200))
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                phase = .detectingLandmarks
                try await previewStagePause(.seconds(2))
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                if ProcessInfo.processInfo.arguments.contains("--garment-preview-capture-failure") {
                    throw AutomaticMeasurementWorkflowFailure(stage: .landmarks, code: .providerFailure,
                        message: "미리보기용 실측 실패입니다.", cause: .landmarksNotFound)
                }
                phase = .measuring
                try await previewStagePause(.seconds(2))
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                phase = .completed
                model = preview
                isCapturing = false
                runID = nil
                captureTask = nil
            } catch {
                finishFailedCapture(error, token: token)
            }
        }
    }

    /// The actual preview bounds now fit the entire oriented sensor image.
    /// Camera chrome is outside those bounds; do not subtract it a second time.
    private func framedSnapshot(_ snapshot: CaptureSnapshot, viewport: CGSize,
                                including points: [GarmentLandmark] = [],
                                endpoints: [ImagePoint] = []) -> CaptureSnapshot {
        guard !isPreview || displayedAspectRatio != .fourThree
                || ProcessInfo.processInfo.arguments.contains("--garment-preview-matched-framing"),
              viewport.width > 0, viewport.height > 0 else { return snapshot }
        guard let crop = PhotoDisplayCrop.matchingPreview(imageSize: snapshot.frame.imageSize,
            orientation: snapshot.frame.orientation, viewportWidth: viewport.width,
            viewportHeight: viewport.height, visibleRect: .init(x: 0, y: 0, width: 1, height: 1)) else { return snapshot }
        var framed = snapshot
        // Keep normal handles visible if recognition finds a point behind the
        // camera chrome. Expansion is frozen before editing, so drags cannot
        // cause the photograph to jump or modify the measurement coordinate grid.
        let imagePoints = points.filter { $0.isVisible && $0.point.isValid }.map(\.point)
            + endpoints.filter(\.isValid)
        framed.capturePresentationCrop = crop
        framed.presentationCrop = crop.including(displayPoints: imagePoints.map {
            ImageCoordinateTransform.originalToDisplay($0, orientation: snapshot.frame.orientation)
        })
        return framed
    }

    private func framedPreview(_ preview: AutomaticMeasurement, viewport: CGSize) -> AutomaticMeasurement {
        guard displayedAspectRatio != .fourThree || ProcessInfo.processInfo.arguments.contains("--garment-preview-matched-framing"),
              var record = try? preview.makeRecord(id: preview.id) else { return preview }
        record.snapshot = framedSnapshot(preview.snapshot, viewport: viewport,
            including: preview.landmarks.points + preview.visibleEditableLandmarks.points,
            endpoints: preview.visibleValues.filter(\.hasUsableMeasurement).flatMap { $0.points.map(\.imagePoint) })
        return AutomaticMeasurement(record: record)
    }

    private func previewStagePause(_ duration: Duration) async throws {
        if ProcessInfo.processInfo.arguments.contains("--garment-preview-processing") {
            try await Task.sleep(for: duration)
        } else {
            await Task.yield()
            try Task.checkCancellation()
        }
    }

    private func presentFailure(_ error: Error) {
        let failure = (error as? AutomaticMeasurementWorkflowFailure)
            ?? (error as? RecordedMeasurementRunFailure)?.workflowFailure
            ?? AutomaticMeasurementWorkflowFailure(
                stage: processingSnapshot == nil ? .capture : .landmarks,
                code: error is CancellationError ? .cancelled
                    : (error as? any AutomaticMeasurementFailureClassifying)?.automaticMeasurementFailureCode ?? .providerFailure,
                message: error.localizedDescription,
                cause: (error as? any AutomaticMeasurementFailureCauseProviding)?.automaticMeasurementFailureCause)
        guard let feedback = WorkflowFailureFeedback.make(for: failure,
            hasCapturedPhoto: processingSnapshot != nil) else {
            // A provider can report a normal stop even when the owning task's
            // cancellation flag has not reached this actor yet.
            captureFailure = nil
            return
        }
        // Keep the classified reason for diagnostics; the product alert uses
        // the Figma copy consistently for every failed capture.
        captureFailure = feedback
    }

    private func finishFailedCapture(_ error: Error, token: UUID) {
        guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
        presentFailure(error)
        runID = nil
        isCapturing = false
        phase = .idle
        captureTask = nil
        processingSnapshot = nil
        processingImage = nil
        processingViewportSize = .zero
        recordingError = nil
        closeCameraOptions()
        clearPreviewFocus()
        // Resume behind the modal so confirming it does not start another
        // camera session or leave the previous analysis frame on screen.
        restartCamera()
    }

    private func dismissCaptureFailure() {
        captureFailure = nil
    }

    private func cancel() {
        runID = nil
        captureTask?.cancel()
        captureTask = nil
        cameraRestartTask?.cancel()
        cameraRestartTask = nil
        service?.cancel()
        isCapturing = false
        processingSnapshot = nil
        processingImage = nil
        processingViewportSize = .zero
        captureFailure = nil
    }

    private func restartCamera() {
        guard !isPreview, model == nil, scenePhase == .active else { return }
        cameraRestartTask?.cancel()
        cameraRestartTask = Task {
            guard !Task.isCancelled else { return }
            // A resumed draft starts at the result and skips initial camera
            // setup. Prepare its existing service before allowing a new shot.
            async let preparation: Void = captureSession.prepare()
            await camera.start()
            await preparation
        }
    }

    private func retake() {
        guard allowsRetake else { return }
        cancel()
        clearPreviewFocus()
        model = nil
        // Only the first restored result may reuse its archived record.
        restoredRecord = nil
        recordingError = nil
        previewRecognized = false
        phase = .idle
        if isPreview {
            previewModel = GarmentCapturePreview.measurement(partial: previewIsPartial,
                bothSidesPartial: previewBothSidesPartial, missingTopLength: previewMissingTopLength, kind: previewKind)
        }
        else { restartCamera() }
    }
}

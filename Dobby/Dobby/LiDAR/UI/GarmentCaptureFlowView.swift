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
    private let onExitRecord: ((SavedMeasurement) async throws -> Void)?
    private let onExitRequested: ((@escaping () -> Void) -> Void)?
    private let restoredRecord: SavedMeasurement?
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
    @State private var errorMessage: String?
    @State private var recordingError: String?
    @State private var processingSnapshot: CaptureSnapshot?
    @State private var processingImage: UIImage?
    @State private var captureViewportSize: CGSize = .zero
    @State private var processingViewportSize: CGSize = .zero
    @State private var errorTitle = "촬영을 완료하지 못했어요"
    @State private var manualRecovery: ManualMeasurement?
    @State private var previewControls = CameraControlState(sessionID: UUID())
    @State private var previewFocusVisible = false
    @AppStorage("dobby.measurementCapture.skipPlacementTutorial.v1") private var skipsPlacementTutorial = false
    @State private var showsPlacementTutorial = false
    @State private var previewSkipsPlacementTutorial = false
    @StateObject private var levelGuide = GarmentCameraLevelGuide()

    init(archive: MeasurementArchive = MeasurementArchive(), preview: Bool = false,
         onConfirmedRecord: ((SavedMeasurement) async throws -> Void)? = nil,
         onCancel: (() -> Void)? = nil, embedsNavigation: Bool = true,
         restoredRecord: SavedMeasurement? = nil,
         onExitRecord: ((SavedMeasurement) async throws -> Void)? = nil,
         allowsRetake: Bool = true,
         onExitRequested: ((@escaping () -> Void) -> Void)? = nil) {
        self.archive = archive
        self.isPreview = preview
        self.onConfirmedRecord = onConfirmedRecord
        self.onExitRecord = onExitRecord
        self.onExitRequested = onExitRequested
        self.restoredRecord = restoredRecord
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
                        onExitRecord: onExitRecord, initialRecord: restoredRecord,
                        allowsRetake: allowsRetake, onExitRequested: onExitRequested)
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
        .onChange(of: scenePhase) { _, value in
            if value != .active { levelGuide.stop(); clearPreviewFocus(); cancel(); camera.stop(); previewRecognized = false }
            else if !isPreview, model == nil { levelGuide.start(); restartCamera() }
        }
        .onDisappear { levelGuide.stop(); clearPreviewFocus(); cancel(); camera.stop() }
        .onChange(of: model == nil) { _, isCamera in
            if isCamera, !isPreview { levelGuide.start() } else { levelGuide.stop() }
        }
        .task(id: processingSnapshot?.frame.frameID) {
            guard let snapshot = processingSnapshot else { return }
            let image = await SnapshotPresentation.thumbnail(for: snapshot, maximumDimension: 1024)
            guard !Task.isCancelled, processingSnapshot?.frame.frameID == snapshot.frame.frameID else { return }
            processingImage = image
        }
        .sheet(item: $manualRecovery, onDismiss: {
            if !isPreview, model == nil, scenePhase == .active { restartCamera() }
        }) { measurement in
            MeasurementDetailView(model: measurement, archive: archive)
        }
        .alert(errorTitle, isPresented: Binding(get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
            if processingSnapshot != nil {
                Button("사진에서 측정점 확인") { reviewCapturedPhoto() }
            }
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
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
        GeometryReader { geometry in
            ZStack {
                cameraImage.accessibilityHidden(showsPlacementTutorial)
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 0) {
                        Spacer()
                        captureControls(compact: true).frame(width: 180).background(.ultraThinMaterial)
                    }
                    VStack {
                        Spacer()
                        recognitionGuidance.padding(.bottom, 20).opacity(showsPlacementTutorial ? 0 : 1)
                    }.padding(.trailing, 180).allowsHitTesting(false)
                        .accessibilityHidden(showsPlacementTutorial)
                } else {
                    VStack(spacing: 0) {
                        Rectangle().fill(.ultraThinMaterial).overlay(.black.opacity(0.12))
                            .frame(height: 146).opacity(showsPlacementTutorial ? 0 : 1)
                        Spacer(minLength: 0)
                        Rectangle().fill(.ultraThinMaterial).overlay(.black.opacity(0.12))
                            .frame(height: showsPlacementTutorial ? 158 : 192)
                    }.allowsHitTesting(false)
                    VStack(spacing: 0) {
                        Spacer(minLength: 146)
                        VStack(spacing: 17) {
                            recognitionGuidance
                            zoomSelector
                        }.padding(.horizontal, 16).padding(.bottom, 17)
                            .opacity(showsPlacementTutorial ? 0 : 1)
                            .accessibilityHidden(showsPlacementTutorial)
                        captureControls().frame(height: showsPlacementTutorial ? 158 : 192, alignment: .top)
                    }
                }
                if shouldShowLevelGuide, !showsPlacementTutorial {
                    VStack(spacing: 109) {
                        Image("MeasurementLevelTop").resizable().scaledToFit().frame(width: 161, height: 23)
                        Image("MeasurementLevelBottom").resizable().scaledToFit().frame(width: 229, height: 38)
                    }
                    .position(x: geometry.size.width / 2,
                        y: geometry.size.height * 389.5 / 874)
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
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { captureViewportSize = geometry.size }
            .onChange(of: geometry.size) { _, size in
                captureViewportSize = size
                if isPreview { previewRecognized = false }
            }
        }
        .ignoresSafeArea()
        .background(GarmentCaptureStyle.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentCaptureScreen")
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
                .foregroundStyle(.white).frame(width: 48, height: 48)
                .glassEffect(.regular.tint(.black.opacity(0.18)).interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canUseCameraControls || !controlCapabilities.availableZooms.contains(nextZoom))
        .accessibilityLabel("촬영 배율")
        .accessibilityValue(selectedZoom == .standard ? "1x" : "2x")
        .accessibilityHint(nextZoom == .double ? "탭하면 2배로 전환합니다" : "탭하면 1배로 전환합니다")
        .accessibilityIdentifier("cameraZoomSelector")
    }

    private func selectZoom(_ zoom: CameraZoom) {
        guard canUseCameraControls, controlCapabilities.availableZooms.contains(zoom) else { return }
        clearPreviewFocus()
        if isPreview { previewRecognized = false; previewControls.selectedZoom = zoom }
        else { camera.setZoom(zoom) }
    }

    private var cameraOptions: some View {
        Menu {
            Button("촬영 가이드 다시 보기") { showsPlacementTutorial = true }
                .accessibilityIdentifier("replayGarmentCaptureTutorial")
        } label: {
            // This existing 48pt asset already includes the dark disc and
            // white dots; template tinting would turn it into a solid circle.
            Image("DetailCaptureMore").renderingMode(.original)
                .frame(width: 48, height: 48)
                .background(Color(white: 0.094), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(isCapturing)
        .accessibilityLabel("촬영 옵션")
        .accessibilityIdentifier("garmentCaptureOptions")
    }

    private var cameraImage: some View {
        ZStack {
            if isCapturing, let snapshot = processingSnapshot {
                Color.black
                if let processingImage {
                    GeometryReader { geometry in
                        // Analysis retains the complete captured RGB/depth.
                        // Only this frozen preview matches the live camera's
                        // aspect-fill composition; never briefly reveal the
                        // wider original or apply the selected zoom twice.
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
                    }
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
            if silhouetteVisible, !hidesPreviewOutline {
                Color.clear.accessibilityElement().accessibilityLabel("촬영을 돕는 옷 윤곽 미리보기")
                    .accessibilityIdentifier("garmentSilhouette").allowsHitTesting(false)
            }
        }.clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("garmentCameraViewport")
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
            // This is advisory text, not a control. It must not swallow taps
            // intended for the camera's immediate focus/exposure recognizer.
            .allowsHitTesting(false)
    }

    private func captureControls(compact: Bool = false) -> some View {
        VStack(spacing: 8) {
            if compact {
                measurementShutter
                zoomSelector.opacity(showsPlacementTutorial ? 0 : 1)
                cameraOptions.opacity(showsPlacementTutorial ? 0 : 1)
            } else {
                HStack {
                    Color.clear.frame(width: 48, height: 48).accessibilityHidden(true)
                    Spacer(minLength: 8)
                    measurementShutter
                    Spacer(minLength: 8)
                    cameraOptions.opacity(showsPlacementTutorial ? 0 : 1)
                }.padding(.horizontal, 48)
            }
            CameraControlPanel(errorMessage: isPreview ? nil : camera.controlError)
            if isPreview, !isCapturing, !showsPlacementTutorial {
                Button(previewRecognized ? "인식 해제" : "윤곽 미리보기") { previewRecognized.toggle() }
                    .font(.caption).accessibilityIdentifier("previewRecognizeGarment")
            }
        }.padding(.top, showsPlacementTutorial ? 24 : 34).accessibilityHidden(showsPlacementTutorial)
    }

    private var measurementShutter: some View {
        GarmentShutterButton(isEnabled: canTakePhoto, isCapturing: isCapturing,
            showsRecognizedState: canTakePhoto, action: takePhoto, forceReduceMotion: presentationReduceMotion)
            .accessibilityHint(isCapturing ? "촬영한 사진의 측정점과 길이를 계산하고 있습니다"
                : isPreview && previewControls.selectedZoom == .double
                ? "합성 촬영 결과는 1배에서 확인해요. 1배로 돌아와 옷 윤곽을 다시 인식해 주세요"
                : "옷 윤곽이 인식되어 주황색 점이 나타나면 촬영할 수 있습니다")
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
    }

    private func setPreviewExposure(_ bias: Double) {
        guard canFocus, let target = controlCapabilities.exposureRange?.clamp(bias) else { return }
        // This fixture never changes a camera or establishes sensor response.
        previewControls.requestedExposureBias = target
        previewControls.exposureBias = target
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
        canUseCameraControls && silhouetteVisible && !showsPlacementTutorial && scenePhase == .active
            && (!isPreview || previewControls.selectedZoom != .double)
    }
    /// Tapping to focus does not depend on garment recognition or the
    /// measurement service being ready. The camera owns autofocus support.
    private var canFocus: Bool {
        guard !isCapturing else { return false }
        if isPreview { return previewModel != nil }
        return camera.isRunning && camera.cameraCapabilities.focusSupported
    }
    private var canUseCameraControls: Bool {
        guard !isCapturing else { return false }
        if isPreview { return previewModel != nil }
        return service != nil && camera.isRunning && camera.state == .ready
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
        if shouldShowLevelGuide { return "핸드폰을 수평으로 들어주세요" }
        if canTakePhoto { return "옷 인식 완료! 촬영 버튼을 눌러주세요" }
        if canUseCameraControls { return "옷이 잘리지 않게 카메라 안에 넣어주세요" }
        if isPreview { return "옷 한 벌 전체가 보이도록 평평하게 펼쳐주세요" }
        switch camera.state {
        case .failed, .interrupted: return "카메라 연결이 중단됐어요. 다시 촬영 화면을 열어주세요"
        case .requestingPermission: return "카메라 접근을 허용해 주세요"
        default: break
        }
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
        errorMessage = nil
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
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                presentFailure(error)
                runID = nil
                isCapturing = false
                captureTask = nil
                restartCamera()
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
        errorMessage = nil
        isCapturing = true
        phase = .capturing
        captureTask = Task {
            do {
                try await previewStagePause(.milliseconds(200))
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                phase = .detectingLandmarks
                try await previewStagePause(.seconds(2))
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                phase = .measuring
                try await previewStagePause(.seconds(2))
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                phase = .completed
                model = preview
                isCapturing = false
                runID = nil
                captureTask = nil
            } catch {
                // The same cancel/retake path clears the owned fixture state.
            }
        }
    }

    /// Match the unobscured camera photograph, rather than revealing pixels
    /// hidden by aspect-fill or camera chrome. This never crops sensor data.
    private func framedSnapshot(_ snapshot: CaptureSnapshot, viewport: CGSize,
                                including points: [GarmentLandmark] = [],
                                endpoints: [ImagePoint] = []) -> CaptureSnapshot {
        guard !isPreview || ProcessInfo.processInfo.arguments.contains("--garment-preview-matched-framing"),
              viewport.width > 0, viewport.height > 0 else { return snapshot }
        let visible: NormalizedRect
        if viewport.width > viewport.height {
            guard viewport.width > 180 else { return snapshot }
            visible = .init(x: 0, y: 0, width: (viewport.width - 180) / viewport.width, height: 1)
        } else {
            guard viewport.height > 338 else { return snapshot }
            visible = .init(x: 0, y: 146 / viewport.height, width: 1,
                height: (viewport.height - 338) / viewport.height)
        }
        guard let crop = PhotoDisplayCrop.matchingPreview(imageSize: snapshot.frame.imageSize,
            orientation: snapshot.frame.orientation, viewportWidth: viewport.width,
            viewportHeight: viewport.height, visibleRect: visible) else { return snapshot }
        var framed = snapshot
        // Keep normal handles visible if recognition finds a point behind the
        // camera chrome. Expansion is frozen before editing, so drags cannot
        // cause the photograph to jump or modify the measurement coordinate grid.
        let imagePoints = points.filter { $0.isVisible && $0.point.isValid }.map(\.point)
            + endpoints.filter(\.isValid)
        framed.presentationCrop = crop.including(displayPoints: imagePoints.map {
            ImageCoordinateTransform.originalToDisplay($0, orientation: snapshot.frame.orientation)
        })
        return framed
    }

    private func framedPreview(_ preview: AutomaticMeasurement, viewport: CGSize) -> AutomaticMeasurement {
        guard ProcessInfo.processInfo.arguments.contains("--garment-preview-matched-framing"),
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
            errorMessage = nil
            return
        }
        errorTitle = feedback.title
        errorMessage = feedback.message
    }

    private func reviewCapturedPhoto() {
        guard let snapshot = processingSnapshot else { return }
        errorMessage = nil
        cameraRestartTask?.cancel()
        cameraRestartTask = nil
        camera.pauseForMeasurement()
        // Failed inference has not supplied a validated kind for this frozen
        // photo. Live preview evidence must not label a separate manual record.
        manualRecovery = ManualMeasurement(snapshot: snapshot, definition: .testDistance,
            testContext: .init(category: .other, deviceModel: SnapshotPresentation.deviceIdentifier))
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
        errorMessage = nil
    }

    private func restartCamera() {
        guard !isPreview, model == nil, manualRecovery == nil, scenePhase == .active else { return }
        cameraRestartTask?.cancel()
        cameraRestartTask = Task {
            guard !Task.isCancelled else { return }
            await camera.start()
        }
    }

    private func retake() {
        guard allowsRetake else { return }
        cancel()
        clearPreviewFocus()
        model = nil
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

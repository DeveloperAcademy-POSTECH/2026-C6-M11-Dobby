import SwiftUI
import UIKit

/// Product capture flow; the measurement lab remains available independently.
struct GarmentCaptureFlowView: View {
    @StateObject private var camera: ARKitCaptureProvider
    @State private var service: RecordedMeasurementService?
    private let loadingError: String?
    private let archive: MeasurementArchive
    private let previewKind: AutomaticGarmentKind
    private let isPreview: Bool
    private let previewIsPartial: Bool
    private let previewBothSidesPartial: Bool
    private let previewMissingTopLength: Bool
    private let onConfirmedRecord: ((SavedMeasurement) async throws -> Void)?
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
    @State private var errorTitle = "촬영을 완료하지 못했어요"
    @State private var manualRecovery: ManualMeasurement?

    init(archive: MeasurementArchive = MeasurementArchive(), preview: Bool = false,
         onConfirmedRecord: ((SavedMeasurement) async throws -> Void)? = nil,
         onCancel: (() -> Void)? = nil, embedsNavigation: Bool = true) {
        self.archive = archive
        self.isPreview = preview
        self.onConfirmedRecord = onConfirmedRecord
        self.onCancel = onCancel
        self.embedsNavigation = embedsNavigation
        // Fixture selection affects only the labelled synthetic preview.
        // The physical camera always classifies its own current image.
        self.previewKind = preview && ProcessInfo.processInfo.arguments.contains("--garment-preview-top") ? .top : .bottoms
        self.previewIsPartial = preview && ProcessInfo.processInfo.arguments.contains("--garment-preview-partial")
        self.previewBothSidesPartial = preview && ProcessInfo.processInfo.arguments.contains("--garment-preview-both-sides-partial")
        self.previewMissingTopLength = preview && ProcessInfo.processInfo.arguments.contains("--garment-preview-missing-top-length")
        let recognizer: AutoGarmentLandmarkProvider?
        if preview {
            recognizer = nil
            loadingError = nil
        } else {
            do {
                recognizer = try AutoGarmentLandmarkProvider.bundled()
                loadingError = nil
            } catch {
                recognizer = nil
                loadingError = error.localizedDescription
            }
        }
        let camera = ARKitCaptureProvider()
        _camera = StateObject(wrappedValue: camera)
        _service = State(initialValue: recognizer.map {
            RecordedMeasurementService(workflow: AutomaticMeasurementWorkflow(camera: camera,
                landmarks: $0, definitions: [], expectedLandmarkOrigin: .model),
                journal: LiDARAppServices.attemptJournal)
        })
    }

    var body: some View {
        captureNavigation {
            Group {
                if let model {
                    GarmentMeasurementResultView(model: model, archive: archive, recordingError: recordingError,
                        initialImage: processingImage, onRetake: retake,
                        onConfirm: { if onConfirmedRecord == nil { dismiss() } },
                        onConfirmedRecord: onConfirmedRecord)
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
            .toolbarBackground(GarmentCaptureStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .background(GarmentCaptureStyle.background)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .task {
            if isPreview {
                previewModel = GarmentCapturePreview.measurement(partial: previewIsPartial,
                    bothSidesPartial: previewBothSidesPartial, missingTopLength: previewMissingTopLength, kind: previewKind)
            }
            else { await camera.start() }
        }
        .onChange(of: orientation) { _, value in
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
        .onChange(of: scenePhase) { _, value in
            if value != .active { cancel(); camera.stop(); previewRecognized = false }
            else if !isPreview, model == nil { restartCamera() }
        }
        .onDisappear { cancel(); camera.stop() }
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
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 0) {
                    cameraImage
                    captureControls.frame(width: 180)
                }
            } else {
                // The handoff uses a 402 × 560 camera window. Keep that
                // composition on phones without displacing the native bars.
                let topGap: CGFloat = 15
                let photoHeight = min(geometry.size.width * 560 / 402,
                    max(180, geometry.size.height - topGap - 138))
                VStack(spacing: 0) {
                    cameraImage.frame(height: photoHeight)
                    captureControls.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(.top, topGap)
            }
        }
        .background(GarmentCaptureStyle.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentCaptureScreen")
    }

    private var cameraImage: some View {
        ZStack {
            if isCapturing, processingSnapshot != nil {
                Color.black
                if let processingImage {
                    Image(uiImage: processingImage).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("촬영한 사진의 측정점을 확인 중")
                        .accessibilityIdentifier("garmentProcessingPhoto")
                } else { ProgressView("촬영한 사진 준비 중").tint(.white) }
            } else if isPreview, let previewModel, let image = SnapshotPresentation.image(for: previewModel.snapshot) {
                GeometryReader { geometry in
                    let aspect = SnapshotPresentation.aspectRatio(for: previewModel.snapshot)
                    let width = max(geometry.size.width, geometry.size.height * aspect)
                    let height = width / aspect
                    ZStack {
                        Image(uiImage: image).resizable()
                        if previewRecognized, let mask = previewModel.landmarks.mask {
                            GarmentSilhouetteOverlay(mask: mask, sourceID: previewModel.snapshot.frame.sessionID,
                                forceReduceMotion: presentationReduceMotion)
                        }
                    }
                    .frame(width: width, height: height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }.clipped()
            } else if !isPreview, camera.isSupported, loadingError == nil {
                CameraPreview(session: camera.session, readiness: camera.liveReadiness, orientation: $orientation)
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
                    processingProgress.padding(.top, 12)
                }
                if isPreview {
                    Text("화면 미리보기 · 실제 측정 아님")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.65), in: Capsule()).padding(.top, 12)
                        .accessibilityIdentifier("garmentPreviewProvenance")
                }
                Spacer(minLength: 24)
                recognitionGuidance
                    .padding(.horizontal, 16).padding(.bottom, 25)
            }.allowsHitTesting(false)
            if silhouetteVisible {
                Color.clear.accessibilityElement().accessibilityLabel("촬영을 돕는 옷 윤곽 미리보기")
                    .accessibilityIdentifier("garmentSilhouette").allowsHitTesting(false)
            }
        }.clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("garmentCameraViewport")
    }

    private var outlineCue: Bool { silhouetteVisible }

    /// The launch flag affects only the labelled synthetic preview. Physical
    /// capture always follows the user's accessibility setting.
    private var presentationReduceMotion: Bool {
        reduceMotion || (isPreview && ProcessInfo.processInfo.arguments.contains("--garment-preview-reduce-motion"))
    }

    /// The outline is visual feedback, never a measurement or shutter gate.
    private var recognitionGuidance: some View {
        HStack(spacing: 8) {
            if isCapturing {
                ProgressView().controlSize(.small).tint(.white).frame(width: 18)
            }
            Text(guidance).multilineTextAlignment(.center)
        }.font(.system(size: guidanceFontSize, weight: .semibold)).foregroundStyle(.white)
            .frame(minWidth: outlineCue ? 217 : 238, minHeight: 20)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .transaction { $0.animation = nil }
            .background {
                ZStack {
                    Capsule().fill(Color(white: 0.067))
                    Capsule().fill(GarmentCaptureStyle.recognition)
                        .animation(presentationReduceMotion || !outlineCue ? nil : .easeInOut(duration: 0.20)) { content in
                            content.opacity(outlineCue ? 1 : 0)
                        }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(guidance)
            .accessibilityHint("윤곽 인식을 기다리지 않고 촬영할 수 있어요. 사진을 촬영한 뒤 치수를 측정합니다")
            .accessibilityIdentifier("captureGuidance")
    }

    private var captureControls: some View {
        VStack(spacing: 8) {
            GarmentShutterButton(isEnabled: canTakePhoto,
                isCapturing: isCapturing, action: takePhoto, forceReduceMotion: presentationReduceMotion)
            if isPreview, !isCapturing, !previewRecognized {
                Button("윤곽 미리보기") { previewRecognized = true }
                    .font(.caption).accessibilityIdentifier("previewRecognizeGarment")
            }
        }.padding(.horizontal, 12).padding(.top, 34)
    }

    /// Only camera availability controls the shutter. The captured RGB/depth
    /// must still pass the model and measurement checks before a result.
    private var canTakePhoto: Bool {
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
        if silhouetteVisible { return "윤곽 미리보기 · 촬영 후 측정해요" }
        if canTakePhoto { return "옷이 잘리지 않게 카메라 안에 넣어주세요" }
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
        if isPreview, let previewModel { takePreviewPhoto(previewModel); return }
        guard let service else { return }
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
                        processingSnapshot = snapshot
                        camera.pauseForMeasurement()
                    })
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                guard let measuredKind = output.workflowOutput.landmarks.garmentKind else {
                    throw AutomaticMeasurementWorkflowFailure(stage: .landmarks, code: .invalidProvenance,
                        message: "촬영한 옷의 종류를 확인하지 못했습니다. 옷 한 벌 전체가 보이도록 다시 촬영해 주세요.")
                }
                recordingError = output.recordingError
                model = AutomaticMeasurement(output: output.workflowOutput,
                    context: .init(category: measuredKind.category, deviceModel: SnapshotPresentation.deviceIdentifier))
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
        switch failure?.stage {
        case .landmarks:
            errorTitle = failure?.code == .invalidConfiguration ? "옷 인식 모델을 확인해 주세요" : "측정점 확인이 필요해요"
            errorMessage = "사진은 촬영했지만 자동 측정점을 확인하지 못했어요.\n\n"
                + (failure?.message ?? error.localizedDescription)
                + "\n\n다시 촬영하거나 이 사진에서 점을 직접 확인할 수 있어요."
        case .measurement:
            errorTitle = "길이를 계산하지 못했어요"
            errorMessage = "사진과 측정점을 확보했지만 깊이를 이용한 길이 계산을 마치지 못했어요. 사진에서 점을 확인하거나 거리와 각도를 바꿔 다시 촬영해 주세요."
        default:
            errorTitle = "사진을 촬영하지 못했어요"
            errorMessage = error.localizedDescription
        }
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
        cancel()
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

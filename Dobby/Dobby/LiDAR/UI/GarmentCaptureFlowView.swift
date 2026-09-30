import SwiftUI
import UIKit

/// Product capture flow; the measurement lab remains available independently.
struct GarmentCaptureFlowView: View {
    @StateObject private var camera: ARKitCaptureProvider
    @State private var service: RecordedMeasurementService?
    private let loadingError: String?
    private let archive: MeasurementArchive
    private let isPreview: Bool
    private let previewIsPartial: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var orientation: ImageOrientation = .right
    @State private var model: AutomaticMeasurement?
    @State private var previewModel: AutomaticMeasurement?
    @State private var previewRecognized = false
    @State private var isCapturing = false
    @State private var phase: AutomaticMeasurementPhase = .idle
    @State private var captureTask: Task<Void, Never>?
    @State private var runID: UUID?
    @State private var errorMessage: String?
    @State private var recordingError: String?

    init(archive: MeasurementArchive = MeasurementArchive(), preview: Bool = false) {
        self.archive = archive
        self.isPreview = preview
        self.previewIsPartial = preview && ProcessInfo.processInfo.arguments.contains("--garment-preview-partial")
        let recognizer: CoreMLBottomLandmarkProvider?
        do {
            recognizer = try CoreMLBottomLandmarkProvider.bundled()
            loadingError = nil
        } catch {
            recognizer = nil
            loadingError = error.localizedDescription
        }
        let camera = ARKitCaptureProvider(garmentRecognizer: recognizer)
        _camera = StateObject(wrappedValue: camera)
        _service = State(initialValue: recognizer.map {
            RecordedMeasurementService(workflow: AutomaticMeasurementWorkflow(camera: camera,
                landmarks: $0, definitions: $0.schema.measurementDefinitions, expectedLandmarkOrigin: .model),
                journal: LiDARAppServices.attemptJournal)
        })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    GarmentMeasurementResultView(model: model, archive: archive, recordingError: recordingError,
                        onRetake: retake, onConfirm: { dismiss() })
                } else {
                    cameraScreen
                        .navigationTitle("실측 촬영")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { cancel(); dismiss() } label: { Image(systemName: "chevron.left") }
                                    .accessibilityLabel("촬영 닫기")
                                    .accessibilityIdentifier("closeGarmentCapture")
                            }
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
            if isPreview { previewModel = GarmentCapturePreview.measurement(partial: previewIsPartial) }
            else { await camera.start() }
        }
        .onChange(of: orientation) { _, value in
            // A rotation invalidates live evidence and an in-flight shutter.
            let interruptedCapture = isCapturing
            if interruptedCapture { cancel() }
            camera.updateImageOrientation(value)
            // Inference pauses ARKit. Cancelling that stage must restore a
            // usable preview even though the cancelled task cannot publish.
            if interruptedCapture, !isPreview, model == nil, scenePhase == .active {
                Task { await camera.start() }
            }
        }
        .onChange(of: scenePhase) { _, value in
            if value != .active { cancel(); camera.stop(); previewRecognized = false }
            else if !isPreview, model == nil { Task { await camera.start() } }
        }
        .onDisappear { cancel(); camera.stop() }
        .alert("촬영을 완료하지 못했어요", isPresented: Binding(get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var cameraScreen: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 0) {
                    cameraImage
                    captureControls.frame(width: 180)
                }
            } else {
                VStack(spacing: 0) {
                    cameraImage
                    captureControls.frame(minHeight: 138, maxHeight: 172)
                }
            }
        }
        .background(GarmentCaptureStyle.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentCaptureScreen")
    }

    private var cameraImage: some View {
        ZStack {
            if isPreview, let previewModel, let image = SnapshotPresentation.image(for: previewModel.snapshot) {
                GeometryReader { geometry in
                    let aspect = SnapshotPresentation.aspectRatio(for: previewModel.snapshot)
                    let width = max(geometry.size.width, geometry.size.height * aspect)
                    let height = width / aspect
                    ZStack {
                        Image(uiImage: image).resizable()
                        if previewRecognized, let mask = previewModel.landmarks.mask {
                            GarmentSilhouetteOverlay(mask: mask)
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
                if isPreview {
                    Text("화면 미리보기 · 실제 측정 아님")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.65), in: Capsule()).padding(.top, 12)
                        .accessibilityIdentifier("garmentPreviewProvenance")
                }
                Spacer(minLength: 24)
                Text(guidance)
                    .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(isReady ? GarmentCaptureStyle.recognition : Color.black.opacity(0.85), in: Capsule())
                    .padding(.horizontal, 16).padding(.bottom, 24)
                    .accessibilityIdentifier("captureGuidance")
            }.allowsHitTesting(false)
            if silhouetteVisible {
                Color.clear.accessibilityElement().accessibilityLabel("인식된 옷 모양의 반투명 윤곽")
                    .accessibilityIdentifier("garmentSilhouette").allowsHitTesting(false)
            }
        }.clipped()
    }

    private var captureControls: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 12)
            GarmentShutterButton(isEnabled: isReady && (isPreview || service != nil),
                isCapturing: isCapturing, action: takePhoto)
            if isPreview, !previewRecognized {
                Button("인식 상태 보기") { previewRecognized = true }
                    .font(.caption).accessibilityIdentifier("previewRecognizeGarment")
            } else {
                Text("바지·반바지 자동 실측 · 상의 준비 중")
                    .font(.caption2).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
            }
            Spacer(minLength: 10)
        }.padding(.horizontal, 12)
    }

    private var isReady: Bool {
        isPreview ? previewRecognized && previewModel != nil : camera.isRunning && camera.liveReadiness.isReady && camera.liveReadiness.garmentRecognized
    }
    private var silhouetteVisible: Bool {
        isPreview ? previewRecognized : camera.liveReadiness.garmentRecognized && camera.liveReadiness.silhouette != nil
    }
    private var permissionDenied: Bool { camera.state == .unavailable(.cameraPermissionDenied) }
    private var unavailableMessage: String {
        if let loadingError { return "하의 인식 모델을 불러오지 못했어요.\n" + loadingError }
        if permissionDenied { return "실측하려면 카메라 접근을 허용해 주세요." }
        return "이 기기에서는 LiDAR 실측 촬영을 사용할 수 없어요.\nLiDAR가 있는 iPhone에서 실행해 주세요."
    }
    private var guidance: String {
        if isCapturing {
            switch phase {
            case .detectingLandmarks: return "촬영한 옷의 측정점을 찾고 있어요"
            case .measuring, .completed: return "실제 길이를 계산하고 있어요"
            default: return "움직이지 말고 잠시 기다려 주세요"
            }
        }
        if isReady { return "옷 인식 완료! 촬영 버튼을 눌러주세요" }
        if isPreview { return "옷이 잘리지 않게 카메라 안에 넣어주세요" }
        switch camera.state {
        case .failed, .interrupted: return "카메라 연결이 중단됐어요. 다시 촬영 화면을 열어주세요"
        case .requestingPermission: return "카메라 접근을 허용해 주세요"
        default: break
        }
        switch camera.liveReadiness.state {
        case .analyzing, .searching: return "옷이 잘리지 않게 카메라 안에 넣어주세요"
        case .ready: return "옷을 확인하고 있어요"
        default: return camera.liveReadiness.state.hint
        }
    }

    private func takePhoto() {
        guard isReady, !isCapturing else { return }
        if isPreview, let previewModel { model = previewModel; return }
        guard let service else { return }
        let token = UUID()
        runID = token
        isCapturing = true
        phase = .capturing
        captureTask = Task {
            do {
                let output = try await service.run(orientation: orientation, purpose: .automaticModel,
                    isSynthetic: false, deviceContext: SnapshotPresentation.deviceIdentifier,
                    onPhaseChange: { value in
                        guard runID == token else { return }
                        phase = value
                        if value == .detectingLandmarks { camera.stop() }
                    })
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                recordingError = output.recordingError
                model = AutomaticMeasurement(output: output.workflowOutput,
                    context: .init(category: .bottoms, deviceModel: SnapshotPresentation.deviceIdentifier))
            } catch {
                guard runID == token, !Task.isCancelled, scenePhase == .active else { return }
                errorMessage = error.localizedDescription
                await camera.start()
            }
            if runID == token { runID = nil; isCapturing = false; captureTask = nil }
        }
    }

    private func cancel() {
        runID = nil
        captureTask?.cancel()
        captureTask = nil
        service?.cancel()
        isCapturing = false
    }

    private func retake() {
        cancel()
        model = nil
        recordingError = nil
        previewRecognized = false
        phase = .idle
        if isPreview { previewModel = GarmentCapturePreview.measurement(partial: previewIsPartial) }
        else { Task { await camera.start() } }
    }
}

import ARKit
import SceneKit
import SwiftUI
import UIKit

struct LiDARCameraView: View {
    @ObservedObject var provider: ARKitCaptureProvider
    var onCapture: (CaptureSnapshot) -> Void
    var captureAction: ((ImageOrientation) async throws -> CaptureSnapshot)? = nil
    var progressText: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var takingPhoto = false
    @State private var errorMessage: String?
    @State private var orientation: ImageOrientation = .right
    @State private var captureTask: Task<Void, Never>?
    @State private var isVisible = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ZoomedCameraPreview(session: provider.session, readiness: provider.liveReadiness, orientation: $orientation,
                    controlState: provider.cameraControls,
                    focusEnabled: provider.isRunning && !takingPhoto && provider.cameraCapabilities.focusSupported,
                    onFocus: provider.requestFocus).ignoresSafeArea()
                if geometry.size.height < 500 {
                    HStack(spacing: 24) {
                        VStack(spacing: 12) {
                            cameraHeader
                            readinessCard
                            Spacer(minLength: 0)
                        }.frame(maxWidth: 400)
                        Spacer(minLength: 0)
                        VStack(spacing: 8) { cameraControlPanel; shutterButton }.frame(width: 180)
                    }.padding(20)
                } else {
                    VStack(spacing: 16) {
                        cameraHeader
                        readinessCard
                        Spacer(minLength: 0)
                        Text("소매와 밑단까지 모두 보이게 펼쳐 주세요")
                            .font(.subheadline).padding(12).background(.black.opacity(0.55), in: Capsule())
                        cameraControlPanel
                        shutterButton
                    }.padding(24)
                }
            }.foregroundStyle(.white).background(.black)
        }
            .task { isVisible = true; await provider.start() }
            .onChange(of: orientation) { _, value in provider.updateImageOrientation(value) }
            .onDisappear { isVisible = false; captureTask?.cancel(); provider.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await provider.start() } }
                else { captureTask?.cancel(); takingPhoto = false; provider.stop() }
            }
            .alert("촬영 상태 확인", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    private var cameraHeader: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.title3).padding(12).background(.black.opacity(0.5), in: Circle())
            }.accessibilityLabel("촬영 닫기")
            Spacer()
            Text("LiDAR · \(provider.cameraControls.selectedZoom.label)").font(.subheadline.bold()).padding(10).background(.black.opacity(0.5), in: Capsule())
        }
    }

    private var cameraControlPanel: some View {
        CameraControlPanel(capabilities: provider.cameraCapabilities, state: provider.cameraControls,
            isEnabled: provider.isRunning && !takingPhoto, errorMessage: provider.controlError,
            onExposure: provider.setExposureBias, onResetExposure: provider.resetExposure, onZoom: provider.setZoom)
            .padding(.horizontal, 8).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private var readinessCard: some View {
        VStack(spacing: 8) {
            if takingPhoto, let progressText {
                Text(progressText).font(.headline).padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(provider.liveReadiness.silhouette == nil ? "인식 전에도 촬영할 수 있어요" : "윤곽 미리보기",
                      systemImage: "viewfinder").font(.headline)
                Text("사진과 깊이를 함께 확보한 뒤 측정합니다. 윤곽은 촬영을 돕는 미리보기예요.")
                    .font(.subheadline)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
            if !provider.isRunning, !takingPhoto {
                Text(captureGuidance).font(.subheadline).padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// Presentation belongs to the view; the adapter publishes camera facts.
    private var captureGuidance: String {
        switch provider.state {
        case .idle:
            return "카메라를 시작하거나 샘플을 불러와 주세요."
        case .requestingPermission:
            return "카메라 권한을 확인하고 있습니다."
        case .unavailable(.unsupportedDevice):
            return ARKitCaptureError.unsupportedDevice.localizedDescription
        case .unavailable(.cameraPermissionDenied):
            return ARKitCaptureError.cameraPermissionDenied.localizedDescription
        case .interrupted:
            return ARKitCaptureError.interrupted.localizedDescription
        case .failed(let reason):
            return ARKitCaptureError.sessionFailed(reason).localizedDescription
        case .starting, .ready, .capturing:
            guard let status = provider.frameStatus else {
                return "옷 전체가 보이도록 카메라를 향해 주세요. 깊이를 준비하고 있습니다."
            }
            guard status.hasDepth else {
                return "LiDAR 깊이를 준비하고 있습니다. 렌즈를 가리지 말고 잠시 기다려 주세요."
            }
            switch status.tracking {
            case .normal:
                return "옷을 펴고 소매와 밑단까지 화면에 들어오게 해 주세요."
            case .excessiveMotion:
                return "카메라 움직임이 큽니다. 잠시 멈춘 뒤 촬영하면 더 안정적입니다."
            case .insufficientFeatures:
                return "주변 무늬가 부족합니다. 조명을 밝게 하고 옷과 배경을 함께 보여 주세요."
            case .limited:
                return "카메라 위치를 파악하고 있습니다. 잠시 안정적으로 잡아 주세요."
            case .unavailable:
                return "카메라 위치 추적을 준비하고 있습니다."
            }
        }
    }

    private var shutterButton: some View {
        Button {
            takingPhoto = true
            captureTask = Task {
                do {
                    let snapshot: CaptureSnapshot
                    if let captureAction { snapshot = try await captureAction(orientation) }
                    else { snapshot = try await CaptureAttemptRecorder.capture(camera: provider, orientation: orientation) }
                    guard !Task.isCancelled else { return }
                    provider.stop()
                    onCapture(snapshot)
                } catch {
                    if !Task.isCancelled, isVisible, scenePhase == .active {
                        errorMessage = error.localizedDescription
                        // Automatic inference pauses the camera. A failed model
                        // must leave a usable retake path in this same view.
                        if !provider.isRunning { await provider.start() }
                    }
                }
                takingPhoto = false
            }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 80, height: 80)
                Circle().fill(.white).frame(width: 66, height: 66)
                if takingPhoto { ProgressView().tint(.black) }
            }
        }.disabled(takingPhoto || !provider.isRunning).accessibilityLabel("LiDAR 사진 촬영")
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: ARSession
    let readiness: LiveCaptureReadiness
    @Binding var orientation: ImageOrientation
    var controlState: CameraControlState? = nil
    var focusEnabled = false
    var onFocus: ((ImagePoint) -> Void)? = nil
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.preferredFramesPerSecond = 60
        view.onOrientation = { orientation = $0 }
        view.onFocus = onFocus
        view.focusEnabled = focusEnabled
        view.controlState = controlState
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        view.onOrientation = { orientation = $0 }
        view.readiness = readiness
        view.onFocus = onFocus
        view.focusEnabled = focusEnabled
        view.controlState = controlState
        view.updateOutline()
        view.updateFocus()
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.onOrientation = nil
        view.onFocus = nil
        view.tearDownOutline()
    }

    final class PreviewView: ARSCNView {
        var onOrientation: ((ImageOrientation) -> Void)?
        var onFocus: ((ImagePoint) -> Void)?
        var focusEnabled = false
        var controlState: CameraControlState? {
            didSet {
                if oldValue?.sessionID != controlState?.sessionID || oldValue?.selectedZoom != controlState?.selectedZoom {
                    focusRenderer.clear()
                }
            }
        }
        private var lastOrientation: UIInterfaceOrientation?
        private var lastBoundsSize: CGSize?
        var readiness = LiveCaptureReadiness.waiting
        private let fallbackOutlineEpoch = UUID()
        private lazy var outlineRenderer = GarmentSilhouetteLayerRenderer(containerLayer: layer)
        private lazy var focusRenderer = CameraFocusIndicatorRenderer(containerView: self)
        private lazy var focusTap = UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:)))
        private var reduceMotionObserver: NSObjectProtocol?

        override init(frame: CGRect, options: [String: Any]? = nil) {
            super.init(frame: frame, options: options)
            clipsToBounds = true
            focusTap.cancelsTouchesInView = false
            focusTap.delaysTouchesEnded = false
            addGestureRecognizer(focusTap)
            reduceMotionObserver = NotificationCenter.default.addObserver(
                forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateOutline(); self?.updateFocus() }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func focusTapped(_ recognizer: UITapGestureRecognizer) {
            guard focusEnabled, let frame = session.currentFrame,
                  let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation else { return }
            let location = recognizer.location(in: self)
            let transform = frame.displayTransform(for: orientation, viewportSize: bounds.size)
            guard let point = CameraPreviewGeometry.sensorPoint(
                viewPoint: .init(x: Double(location.x - bounds.minX), y: Double(location.y - bounds.minY)),
                viewportWidth: Double(bounds.width), viewportHeight: Double(bounds.height),
                displayTransform: Self.affine(transform)) else { return }
            onFocus?(point)
        }

        func updateFocus() {
            guard focusEnabled, let state = controlState, state.focusStatus == .accepted,
                  let point = state.focusPoint, let requestID = state.focusRequestID,
                  let frame = session.currentFrame,
                  let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
                  let displayed = CameraPreviewGeometry.displayPoint(sensorPoint: point,
                    viewportWidth: Double(bounds.width), viewportHeight: Double(bounds.height),
                    displayTransform: Self.affine(frame.displayTransform(for: orientation, viewportSize: bounds.size))) else {
                focusRenderer.clear()
                return
            }
            focusRenderer.update(point: CGPoint(x: displayed.x + Double(bounds.minX), y: displayed.y + Double(bounds.minY)),
                requestID: requestID, reduceMotion: UIAccessibility.isReduceMotionEnabled)
        }

        private static func affine(_ transform: CGAffineTransform) -> CameraAffineTransform {
            .init(a: Double(transform.a), b: Double(transform.b), c: Double(transform.c), d: Double(transform.d),
                  tx: Double(transform.tx), ty: Double(transform.ty))
        }

        func updateOutline() {
            guard let mask = readiness.silhouette,
                  let frame = session.currentFrame,
                  frame.timestamp - readiness.timestamp >= 0,
                  frame.timestamp - readiness.timestamp <= 2,
                  let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
                  readiness.imageOrientation == Self.imageOrientation(for: orientation),
                  bounds.width > 0, bounds.height > 0 else {
                outlineRenderer.clear()
                return
            }
            // ARKit accounts for sensor orientation and the preview's aspect-fill
            // crop; a simple width/height scale would put the box on the wrong pixels.
            let transform = frame.displayTransform(for: orientation, viewportSize: bounds.size)
                .concatenating(.init(scaleX: bounds.width, y: bounds.height))
                .concatenating(.init(translationX: bounds.minX, y: bounds.minY))
            let color = UIColor(named: "CaptureRecognition") ?? .systemMint
            outlineRenderer.update(mask: mask,
                identity: .init(epoch: readiness.analysisEpoch ?? fallbackOutlineEpoch,
                    timestamp: readiness.timestamp, orientation: Self.imageOrientation(for: orientation)),
                transform: transform, viewport: bounds,
                fillColor: color.withAlphaComponent(0.40).cgColor, strokeColor: color.cgColor,
                reduceMotion: UIAccessibility.isReduceMotionEnabled, gradientEndColor: UIColor.white.cgColor)
        }

        func tearDownOutline() {
            outlineRenderer.tearDown()
            focusRenderer.tearDown()
            removeGestureRecognizer(focusTap)
            if let reduceMotionObserver {
                NotificationCenter.default.removeObserver(reduceMotionObserver)
                self.reduceMotionObserver = nil
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { outlineRenderer.clear(); focusRenderer.clear() }
            else { updateOutline(); updateFocus() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if lastBoundsSize != bounds.size { focusRenderer.clear(); lastBoundsSize = bounds.size }
            guard let value = window?.windowScene?.effectiveGeometry.interfaceOrientation else {
                outlineRenderer.clear()
                focusRenderer.clear()
                return
            }
            guard value != lastOrientation else { updateOutline(); updateFocus(); return }
            lastOrientation = value
            // A viewport/rotation change must not morph a previous outline into
            // the new coordinate system while fresh recognition is pending.
            outlineRenderer.clear()
            focusRenderer.clear()
            let mapped = Self.imageOrientation(for: value)
            DispatchQueue.main.async { [weak self] in self?.onOrientation?(mapped) }
        }

        private static func imageOrientation(for value: UIInterfaceOrientation) -> ImageOrientation {
            switch value {
            case .portrait: .right
            case .portraitUpsideDown: .left
            case .landscapeLeft: .down
            default: .up
            }
        }
    }
}

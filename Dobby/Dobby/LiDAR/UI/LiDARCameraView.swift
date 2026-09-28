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
                CameraPreview(session: provider.session, readiness: provider.liveReadiness, orientation: $orientation).ignoresSafeArea()
                if geometry.size.height < 500 {
                    HStack(spacing: 24) {
                        VStack(spacing: 12) {
                            cameraHeader
                            readinessCard
                            Spacer(minLength: 0)
                        }.frame(maxWidth: 400)
                        Spacer(minLength: 0)
                        shutterButton
                    }.padding(20)
                } else {
                    VStack(spacing: 16) {
                        cameraHeader
                        readinessCard
                        Spacer(minLength: 0)
                        Text("소매와 밑단까지 모두 보이게 펼쳐 주세요")
                            .font(.subheadline).padding(12).background(.black.opacity(0.55), in: Capsule())
                        shutterButton
                    }.padding(24)
                }
            }.foregroundStyle(.white).background(.black)
        }
            .task { isVisible = true; await provider.start() }
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
            Text("LiDAR · 기본 화각").font(.subheadline.bold()).padding(10).background(.black.opacity(0.5), in: Capsule())
        }
    }

    private var readinessCard: some View {
        VStack(spacing: 8) {
            if takingPhoto, let progressText {
                Text(progressText).font(.headline).padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            LiveReadinessStatusView(readiness: provider.liveReadiness)
            if !provider.isRunning, !takingPhoto {
                Text(provider.guidance).font(.subheadline).padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
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

private struct CameraPreview: UIViewRepresentable {
    let session: ARSession
    let readiness: LiveCaptureReadiness
    @Binding var orientation: ImageOrientation
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.preferredFramesPerSecond = 30
        view.onOrientation = { orientation = $0 }
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {
        view.onOrientation = { orientation = $0 }
        view.readiness = readiness
        view.updateOutline()
    }

    final class PreviewView: ARSCNView {
        var onOrientation: ((ImageOrientation) -> Void)?
        private var lastOrientation: UIInterfaceOrientation?
        var readiness = LiveCaptureReadiness.waiting
        private let outline = CAShapeLayer()

        override init(frame: CGRect, options: [String: Any]? = nil) {
            super.init(frame: frame, options: options)
            outline.fillColor = UIColor.clear.cgColor
            outline.lineWidth = 3
            outline.shadowColor = UIColor.black.cgColor
            outline.shadowOpacity = 0.5
            outline.shadowRadius = 3
            layer.addSublayer(outline)
            clipsToBounds = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func updateOutline() {
            guard let box = readiness.bounds,
                  readiness.state != .unstable, readiness.state != .analyzing,
                  let frame = session.currentFrame,
                  frame.timestamp - readiness.timestamp <= 2,
                  let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
                  bounds.width > 0, bounds.height > 0 else {
                outline.path = nil
                return
            }
            // ARKit accounts for sensor orientation and the preview's aspect-fill
            // crop; a simple width/height scale would put the box on the wrong pixels.
            let transform = frame.displayTransform(for: orientation, viewportSize: bounds.size)
            let corners = [CGPoint(x: box.x, y: box.y), CGPoint(x: box.x + box.width, y: box.y),
                           CGPoint(x: box.x + box.width, y: box.y + box.height), CGPoint(x: box.x, y: box.y + box.height)]
                .map { $0.applying(transform) }
                .map { CGPoint(x: $0.x * bounds.width, y: $0.y * bounds.height) }
            let path = UIBezierPath()
            path.move(to: corners[0])
            for point in corners.dropFirst() { path.addLine(to: point) }
            path.close()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outline.frame = bounds
            outline.path = path.cgPath
            outline.strokeColor = (readiness.state == .ready ? UIColor.systemMint : UIColor.systemOrange).cgColor
            outline.lineDashPattern = readiness.state == .ready ? nil : [8, 5]
            CATransaction.commit()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateOutline()
            guard let value = window?.windowScene?.effectiveGeometry.interfaceOrientation, value != lastOrientation else { return }
            lastOrientation = value
            let mapped: ImageOrientation
            switch value {
            case .portrait: mapped = .right
            case .portraitUpsideDown: mapped = .left
            case .landscapeLeft: mapped = .down
            default: mapped = .up
            }
            DispatchQueue.main.async { [weak self] in self?.onOrientation?(mapped) }
        }
    }
}

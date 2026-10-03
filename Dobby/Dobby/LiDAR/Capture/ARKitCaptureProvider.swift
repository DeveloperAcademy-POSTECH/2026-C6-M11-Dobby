import ARKit
import AVFoundation
import Combine
import CoreImage
import Foundation
import ImageIO

nonisolated enum CaptureState: Equatable, Sendable {
    case idle
    case requestingPermission
    case starting
    case ready
    case capturing
    case interrupted
    case unavailable(CaptureUnavailableReason)
    case failed(String)
}

nonisolated enum CaptureUnavailableReason: Equatable, Sendable {
    case unsupportedDevice
    case cameraPermissionDenied
}

/// Camera facts only. Views decide how to describe these observations.
nonisolated struct CaptureFrameStatus: Equatable, Sendable {
    var hasDepth: Bool
    var tracking: CaptureTrackingStatus
}

nonisolated enum CaptureTrackingStatus: Equatable, Sendable {
    case normal
    case excessiveMotion
    case insufficientFeatures
    case limited
    case unavailable
}

nonisolated enum ARKitCaptureError: LocalizedError, Sendable, AutomaticMeasurementFailureClassifying {
    case unsupportedDevice
    case cameraPermissionDenied
    case sessionNotRunning
    case captureInProgress
    case timedOut
    case interrupted
    case stopped
    case invalidDepth
    case invalidImage
    case invalidCalibration
    case sessionFailed(String)

    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode {
        switch self {
        case .timedOut: .timedOut
        case .interrupted: .interrupted
        case .stopped: .cancelled
        default: .providerFailure
        }
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice: "이 기기는 LiDAR 깊이 측정을 지원하지 않습니다. 시뮬레이터에서는 샘플로 테스트해 주세요."
        case .cameraPermissionDenied: "카메라 접근 권한이 필요합니다. 설정에서 Dobby의 카메라 접근을 허용해 주세요."
        case .sessionNotRunning: "카메라가 준비되지 않았습니다. 카메라를 시작해 주세요."
        case .captureInProgress: "이미 촬영하고 있습니다. 잠시 기다려 주세요."
        case .timedOut: "4초 안에 안정된 추적과 유효한 깊이를 갖춘 프레임을 확보하지 못했습니다. 렌즈를 가리지 말고 카메라를 잠시 멈춘 뒤 다시 촬영해 주세요."
        case .interrupted: "카메라 사용이 중단되었습니다. 앱으로 돌아온 뒤 다시 촬영해 주세요."
        case .stopped: "카메라가 종료되어 촬영을 취소했습니다."
        case .invalidDepth: "LiDAR 깊이 데이터 형식을 읽을 수 없습니다. 다시 촬영해 주세요."
        case .invalidImage: "촬영한 사진을 저장할 수 없습니다. 다시 촬영해 주세요."
        case .invalidCalibration: "사진과 카메라 보정 정보가 일치하지 않습니다. 카메라를 다시 시작해 주세요."
        case .sessionFailed(let reason): "카메라 오류: \(reason)"
        }
    }
}

/// Camera ownership is deliberately confined to this adapter. Mason's camera
/// implementation can replace it while preserving CaptureSnapshotProviding.
@MainActor
final class ARKitCaptureProvider: NSObject, ObservableObject, CaptureSnapshotProviding {
    let session = ARSession()
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var frameStatus: CaptureFrameStatus?
    @Published private(set) var isRunning = false
    @Published private(set) var liveReadiness = LiveCaptureReadiness.waiting

    var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported &&
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private nonisolated let worker = CaptureWorker()
    private nonisolated let liveAnalyzer = LiveForegroundAnalyzer()
    private var resumeTrackingOnNextStart = false
    private var freshnessTask: Task<Void, Never>?
    private var lastCameraTimestamp: TimeInterval?
    private var lastCameraReceivedAt: TimeInterval?
    private var generation: UUID?
    private var permissionRequestInProgress = false
    private var imageOrientation: ImageOrientation = .right
    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = worker.queue
    }

    /// The view forwards its actual preview orientation. An old model completion
    /// must not paint a silhouette using a newer preview's rotation.
    func updateImageOrientation(_ orientation: ImageOrientation) {
        guard orientation != imageOrientation else { return }
        imageOrientation = orientation
        liveAnalyzer.setOrientation(orientation)
        resetReadiness()
    }

    func start() async {
        if isRunning {
            if state != .capturing, let generation {
                liveAnalyzer.resume(sessionID: generation)
            }
            return
        }
        guard !permissionRequestInProgress else { return }
        guard isSupported else {
            state = .unavailable(.unsupportedDevice)
            return
        }

        // A new UUID prevents delayed ML/capture results from a previous session
        // being treated as observations from this session.
        let identifier = UUID()
        generation = identifier
        permissionRequestInProgress = true
        state = .requestingPermission
        defer {
            if generation == identifier { permissionRequestInProgress = false }
        }

        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }

        guard generation == identifier else { return }
        guard !Task.isCancelled else { stop(); return }
        guard authorized else {
            state = .unavailable(.cameraPermissionDenied)
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = [.sceneDepth]
        if ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth]) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        configuration.environmentTexturing = .none
        worker.activate(sessionID: identifier)
        liveAnalyzer.reset(sessionID: identifier)
        resetReadiness()
        startFreshnessMonitor(sessionID: identifier)
        state = .starting
        frameStatus = nil
        isRunning = true
        let runOptions: ARSession.RunOptions = resumeTrackingOnNextStart ? [] : [.resetTracking, .removeExistingAnchors]
        resumeTrackingOnNextStart = false
        session.run(configuration, options: runOptions)
    }

    func stop() {
        resumeTrackingOnNextStart = false
        pauseCamera()
    }

    /// Freeze the preview after its RGB/depth snapshot has been copied. Retakes
    /// in the same foreground session can keep ARKit's established tracking.
    func pauseForMeasurement() {
        resumeTrackingOnNextStart = resumeTrackingOnNextStart || isRunning
        pauseCamera()
    }

    private func pauseCamera() {
        generation = nil
        permissionRequestInProgress = false
        worker.stop(error: .stopped)
        liveAnalyzer.reset(sessionID: nil)
        freshnessTask?.cancel()
        freshnessTask = nil
        resetReadiness()
        session.pause()
        isRunning = false
        state = .idle
        frameStatus = nil
    }

    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        try Task.checkCancellation()
        guard isRunning, let identifier = generation else {
            throw ARKitCaptureError.sessionNotRunning
        }
        guard state != .capturing else { throw ARKitCaptureError.captureInProgress }
        liveAnalyzer.suspend(sessionID: identifier)
        resetReadiness()
        var snapshotCompleted = false
        defer {
            // Successful callers now own a frozen snapshot and immediately
            // pause/close the camera. Keep preview ML out of their inference
            // queue; start() can explicitly resume this still-running preview.
            if !snapshotCompleted, generation == identifier, isRunning {
                liveAnalyzer.resume(sessionID: identifier)
                resetReadiness()
            }
        }
        let request = SnapshotRequest(sessionID: identifier, orientation: orientation,
                                      minimumFrameTimestamp: session.currentFrame?.timestamp)
        state = .capturing
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    request.attach(continuation)
                    worker.enqueue(request)
                }
            } onCancel: { [worker] in
                // Cancellation may happen even before enqueue/attach. The
                // request remembers its terminal result and resumes exactly once.
                request.finish(.failure(CancellationError()))
                worker.remove(request)
            }
            try Task.checkCancellation()
            guard generation == identifier, isRunning else {
                throw ARKitCaptureError.stopped
            }
            state = .ready
            snapshotCompleted = true
            return snapshot
        } catch {
            if generation == identifier, isRunning { state = .ready }
            throw error
        }
    }

    private func receive(_ update: CaptureObservation) {
        guard generation == update.sessionID, isRunning,
              lastCameraTimestamp.map({ update.timestamp > $0 }) ?? true else { return }
        lastCameraTimestamp = update.timestamp
        lastCameraReceivedAt = ProcessInfo.processInfo.systemUptime
        frameStatus = update.status
        // An RGB preview frame enables the shutter. Snapshot selection still
        // validates synchronized depth and camera quality after the tap.
        if state == .starting { state = .ready }
    }

    private func receiveLiveReadiness(sessionID: UUID, readiness: LiveCaptureReadiness) {
        guard generation == sessionID, isRunning, state != .capturing,
              readiness.imageOrientation == imageOrientation, liveAnalyzer.isCurrent(readiness),
              let current = session.currentFrame,
              let receivedAt = lastCameraReceivedAt,
              ProcessInfo.processInfo.systemUptime - receivedAt <= 1,
              readiness.timestamp.isFinite,
              readiness.timestamp >= liveReadiness.timestamp,
              current.timestamp - readiness.timestamp >= 0,
              current.timestamp - readiness.timestamp <= 2 else { return }
        // Preview masks are advisory visual feedback only. They contain no
        // garment kind, measurement points, depth checks or capture permission.
        liveReadiness = readiness
    }

    private func resetReadiness() {
        liveReadiness = .waiting
        lastCameraTimestamp = nil
        lastCameraReceivedAt = nil
    }

    private func startFreshnessMonitor(sessionID: UUID) {
        freshnessTask?.cancel()
        freshnessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                guard let self, generation == sessionID, isRunning else { return }
                guard liveReadiness.silhouette != nil else { continue }
                let cameraStale = lastCameraReceivedAt.map {
                    ProcessInfo.processInfo.systemUptime - $0 > 1
                } ?? true
                let previewStale = session.currentFrame.map {
                    $0.timestamp - self.liveReadiness.timestamp > 2
                } ?? true
                if cameraStale || previewStale {
                    liveAnalyzer.invalidateReadiness()
                    liveReadiness = .waiting
                }
            }
        }
    }

}

extension ARKitCaptureProvider: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let update = worker.consume(frame)
        if let identifier = worker.sessionID {
            liveAnalyzer.submit(frame: frame, sessionID: identifier) { [weak self] sessionID, readiness in
                Task { @MainActor [weak self] in
                    self?.receiveLiveReadiness(sessionID: sessionID, readiness: readiness)
                }
            }
        }
        if let update {
            Task { @MainActor [weak self] in self?.receive(update) }
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        guard let identifier = worker.suspend(error: .interrupted) else { return }
        liveAnalyzer.reset(sessionID: nil)
        Task { @MainActor [weak self] in
            guard let self, generation == identifier else { return }
            isRunning = false
            state = .interrupted
            freshnessTask?.cancel()
            resetReadiness()
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        guard let identifier = worker.sessionID else { return }
        Task { @MainActor [weak self] in
            guard let self, generation == identifier else { return }
            // Main-actor tasks created by delegate callbacks need not execute in
            // callback order. Force a fresh run even if the interruption's UI
            // update has not been delivered yet; its old UUID will then be ignored.
            isRunning = false
            await start()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let failure = ARKitCaptureError.sessionFailed(error.localizedDescription)
        guard let identifier = worker.suspend(error: failure) else { return }
        liveAnalyzer.reset(sessionID: nil)
        Task { @MainActor [weak self] in
            guard let self, generation == identifier else { return }
            isRunning = false
            state = .failed(error.localizedDescription)
            freshnessTask?.cancel()
            resetReadiness()
        }
    }
}

private nonisolated struct CaptureObservation: Sendable {
    var sessionID: UUID
    var status: CaptureFrameStatus
    var timestamp: TimeInterval
}

/// Everything accessed from both the main actor and ARKit's delegate queue is
/// guarded by lock. The CIContext is used only on the serial delegate queue.
private nonisolated final class CaptureWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.dobby.lidar.capture", qos: .userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var identifier: UUID?
    private var acceptsFrames = false
    private var pending: SnapshotRequest?
    private var copying = false
    private var selector: CaptureFrameSelector?
    private var selectedCandidate: CopiedCaptureCandidate?
    private var lastObservationTime: TimeInterval = -.infinity
    private var previousFramePose: simd_float4x4?
    private var previousFrameTime: TimeInterval?

    var sessionID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return identifier
    }

    func activate(sessionID: UUID) {
        lock.lock()
        let previous = pending
        pending = nil
        copying = false
        selector = nil
        selectedCandidate = nil
        identifier = sessionID
        acceptsFrames = true
        lastObservationTime = -.infinity
        previousFramePose = nil
        previousFrameTime = nil
        lock.unlock()
        previous?.finish(.failure(ARKitCaptureError.stopped))
    }

    func stop(error: ARKitCaptureError) {
        lock.lock()
        let previous = pending
        pending = nil
        copying = false
        selector = nil
        selectedCandidate = nil
        identifier = nil
        acceptsFrames = false
        lock.unlock()
        previous?.finish(.failure(error))
    }

    func suspend(error: ARKitCaptureError) -> UUID? {
        lock.lock()
        let currentID = identifier
        let previous = pending
        pending = nil
        copying = false
        selector = nil
        selectedCandidate = nil
        acceptsFrames = false
        lock.unlock()
        previous?.finish(.failure(error))
        return currentID
    }

    func enqueue(_ request: SnapshotRequest) {
        lock.lock()
        let error: ARKitCaptureError?
        if !acceptsFrames || identifier != request.sessionID { error = .sessionNotRunning }
        else if pending != nil { error = .captureInProgress }
        else { error = nil }
        if error == nil, !request.isFinished {
            pending = request
            copying = false
            selector = CaptureFrameSelector(requestID: request.id, startedAt: ProcessInfo.processInfo.systemUptime,
                                            minimumFrameTimestamp: request.minimumFrameTimestamp)
            selectedCandidate = nil
        }
        lock.unlock()
        if let error { request.finish(.failure(error)); return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 4) { [weak self, weak request] in
            guard let self, let request else { return }
            request.finish(.failure(ARKitCaptureError.timedOut))
            remove(request)
        }
    }

    func remove(_ request: SnapshotRequest) {
        lock.lock(); defer { lock.unlock() }
        if pending === request {
            selector?.cancel(requestID: request.id)
            pending = nil
            copying = false
            selector = nil
            selectedCandidate = nil
        }
    }

    func consume(_ frame: ARFrame) -> CaptureObservation? {
        lock.lock()
        guard let identifier, acceptsFrames else { lock.unlock(); return nil }
        let elapsed = frame.timestamp - lastObservationTime
        let shouldPublish = elapsed >= 0.33
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true }
        else { trackingNormal = false }
        if shouldPublish {
            lastObservationTime = frame.timestamp
        }
        var translationSpeed: Double?
        var angularSpeed: Double?
        if let previousFramePose, let previousFrameTime {
            let delta = frame.timestamp - previousFrameTime
            if delta > 0, delta <= 2 {
                let pose = frame.camera.transform
                translationSpeed = Double(simd_distance(pose.columns.3, previousFramePose.columns.3)) / delta
                let relative = simd_quatf(pose) * simd_quatf(previousFramePose).inverse
                angularSpeed = 2 * acos(min(1, abs(Double(relative.real)))) / delta
            }
        }
        if previousFrameTime.map({ frame.timestamp > $0 }) ?? true {
            previousFrameTime = frame.timestamp
            previousFramePose = frame.camera.transform
        }
        let request: SnapshotRequest?
        if let pending, !copying, !pending.isFinished {
            request = pending
            copying = true
        } else { request = nil }
        lock.unlock()

        let update: CaptureObservation? = shouldPublish
            ? CaptureObservation(sessionID: identifier,
                                 status: CaptureFrameStatus(hasDepth: frame.sceneDepth != nil,
                                                            tracking: Self.trackingStatus(for: frame.camera.trackingState)),
                                 timestamp: frame.timestamp)
            : nil

        if let request {
            autoreleasepool {
                consider(frame, request: request, trackingNormal: trackingNormal,
                         translationSpeed: translationSpeed, angularSpeed: angularSpeed)
            }
        }
        return update
    }

    private func consider(_ frame: ARFrame, request: SnapshotRequest, trackingNormal: Bool,
                          translationSpeed: Double?, angularSpeed: Double?) {
        let depth = frame.sceneDepth.flatMap { try? Self.copyDepth($0) }
        let quality = CaptureFrameQuality.evaluate(
            depth: depth, timestamp: frame.timestamp, trackingNormal: trackingNormal,
            translationSpeedMetersPerSecond: translationSpeed, angularSpeedRadiansPerSecond: angularSpeed)
        lock.lock()
        guard pending === request, identifier == request.sessionID, acceptsFrames,
              !request.isFinished, var selector else { lock.unlock(); return }
        let previousDeadline = selector.windowEndsAt
        let replace = selector.consider(quality, requestID: request.id, now: ProcessInfo.processInfo.systemUptime)
        let newDeadline = previousDeadline == nil ? selector.windowEndsAt : nil
        self.selector = selector
        if !replace { copying = false }
        lock.unlock()

        if replace, let depth {
            do {
                // Copy only the new best candidate. No ARFrame or ARKit-owned
                // pixel buffer survives this call, and no JPEG is made here.
                let candidate = try copyCandidate(frame, depth: depth, request: request)
                lock.lock()
                if pending === request, identifier == request.sessionID, acceptsFrames, !request.isFinished {
                    selectedCandidate = candidate
                    copying = false
                }
                lock.unlock()
            } catch {
                complete(request, result: .failure(error))
                return
            }
        }
        if let newDeadline {
            let remaining = max(0, newDeadline - ProcessInfo.processInfo.systemUptime)
            queue.asyncAfter(deadline: .now() + remaining) { [weak self, weak request] in
                guard let self, let request else { return }
                finalize(request)
            }
        }
    }

    private func finalize(_ request: SnapshotRequest) {
        lock.lock()
        guard pending === request, identifier == request.sessionID, acceptsFrames,
              !request.isFinished, var selector, let candidate = selectedCandidate else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let summary = selector.finish(requestID: request.id, now: now) else {
            let remaining = selector.windowEndsAt.map { max(0.001, $0 - now) }
            lock.unlock()
            if let remaining {
                queue.asyncAfter(deadline: .now() + remaining) { [weak self, weak request] in
                    guard let self, let request else { return }
                    finalize(request)
                }
            }
            return
        }
        self.selector = selector
        copying = true
        lock.unlock()
        let result = Result { try autoreleasepool { try snapshot(candidate, selectionSummary: summary) } }
        complete(request, result: result)
    }

    private func complete(_ request: SnapshotRequest, result: Result<CaptureSnapshot, Error>) {
        lock.lock()
        let stillCurrent = pending === request && identifier == request.sessionID && acceptsFrames
        if pending === request {
            pending = nil
            copying = false
            selector = nil
            selectedCandidate = nil
        }
        lock.unlock()
        if stillCurrent { request.finish(result) }
    }

    private static func trackingStatus(for state: ARCamera.TrackingState) -> CaptureTrackingStatus {
        switch state {
        case .normal: .normal
        case .limited(.excessiveMotion): .excessiveMotion
        case .limited(.insufficientFeatures): .insufficientFeatures
        case .limited: .limited
        case .notAvailable: .unavailable
        }
    }

    private func copyCandidate(_ frame: ARFrame, depth: DepthMap, request: SnapshotRequest) throws -> CopiedCaptureCandidate {
        let capturedAt = Date()
        let image = frame.capturedImage
        let imageSize = PixelSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        let resolution = frame.camera.imageResolution
        let matrix = frame.camera.intrinsics
        let calibration = CameraIntrinsics(
            fx: Double(matrix.columns.0.x), fy: Double(matrix.columns.1.y),
            cx: Double(matrix.columns.2.x), cy: Double(matrix.columns.2.y),
            referenceSize: PixelSize(width: Int(resolution.width), height: Int(resolution.height))
        )
        guard imageSize.isValid, calibration.referenceSize == imageSize,
              calibration.fx.isFinite, calibration.fy.isFinite,
              calibration.cx.isFinite, calibration.cy.isFinite,
              calibration.fx > 0, calibration.fy > 0 else { throw ARKitCaptureError.invalidCalibration }
        guard depth.size.width * imageSize.height == depth.size.height * imageSize.width else {
            throw ARKitCaptureError.invalidCalibration
        }
        let sensorImage = CIImage(cvPixelBuffer: image)
        guard let copiedImage = context.createCGImage(sensorImage,
            from: CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB(), deferred: false) else { throw ARKitCaptureError.invalidImage }
        let rawFrame = MeasurementFrame(
            sessionID: request.sessionID, frameID: UUID(), timestamp: frame.timestamp,
            capturedAt: capturedAt, imageSize: imageSize, intrinsics: calibration,
            depth: depth, source: .sceneDepth, orientation: request.orientation)
        var smoothedFrame: MeasurementFrame?
        if let source = frame.smoothedSceneDepth, let smoothed = try? Self.copyDepth(source),
           smoothed.size.width * imageSize.height == smoothed.size.height * imageSize.width {
            // All provenance is copied from the raw frame, including capturedAt.
            // ARKit's smoothed estimate still uses temporal filtering internally.
            var comparison = rawFrame
            comparison.depth = smoothed
            comparison.source = .smoothedSceneDepth
            smoothedFrame = comparison
        }
        return CopiedCaptureCandidate(frame: rawFrame, smoothedFrame: smoothedFrame, image: copiedImage)
    }

    private func snapshot(_ candidate: CopiedCaptureCandidate,
                          selectionSummary: CaptureSelectionSummary) throws -> CaptureSnapshot {
        CaptureSnapshot(frame: candidate.frame, imageJPEG: try jpeg(candidate.image),
                        smoothedFrame: candidate.smoothedFrame, selectionSummary: selectionSummary)
    }

    private func jpeg(_ image: CGImage) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92
        ]
        // Keep the original sensor raster. Display rotation is carried as
        // metadata; rotating JPEG pixels here would invalidate landmark geometry.
        guard let jpeg = context.jpegRepresentation(of: CIImage(cgImage: image), colorSpace: colorSpace, options: options)
        else { throw ARKitCaptureError.invalidImage }
        return jpeg
    }

    private static func copyDepth(_ source: ARDepthData) throws -> DepthMap {
        let buffer = source.depthMap
        let size = PixelSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard size.isValid, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw ARKitCaptureError.invalidDepth }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), stride >= size.width * MemoryLayout<Float>.stride
        else { throw ARKitCaptureError.invalidDepth }
        var values = [Float](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<size.width {
                let value = row[x]
                values[y * size.width + x] = value.isFinite && value > 0 ? value : 0
            }
        }
        return DepthMap(size: size, values: values, confidence: copyConfidence(source.confidenceMap, size: size))
    }

    private static func copyConfidence(_ buffer: CVPixelBuffer?, size: PixelSize) -> [UInt8]? {
        guard let buffer,
              CVPixelBufferGetWidth(buffer) == size.width, CVPixelBufferGetHeight(buffer) == size.height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), stride >= size.width else { return nil }
        var values = [UInt8](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<size.width {
                // Future/unknown confidence codes must not be interpreted as high.
                guard row[x] <= 2 else { return nil }
                values[y * size.width + x] = row[x]
            }
        }
        return values
    }
}

/// Owns a rendered RGB copy, not an ARKit pixel buffer. The worker keeps only the
/// current winner (plus a transient replacement during copying).
private nonisolated struct CopiedCaptureCandidate {
    var frame: MeasurementFrame
    var smoothedFrame: MeasurementFrame?
    var image: CGImage
}

/// The completion lives independently of the worker so cancellation before
/// registration, timeout, interruption and success cannot double-resume it.
private nonisolated final class SnapshotRequest: @unchecked Sendable {
    let id = UUID()
    let sessionID: UUID
    let orientation: ImageOrientation
    let minimumFrameTimestamp: TimeInterval?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CaptureSnapshot, Error>?
    private var result: Result<CaptureSnapshot, Error>?

    init(sessionID: UUID, orientation: ImageOrientation, minimumFrameTimestamp: TimeInterval?) {
        self.sessionID = sessionID
        self.orientation = orientation
        self.minimumFrameTimestamp = minimumFrameTimestamp
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return result != nil
    }

    func attach(_ continuation: CheckedContinuation<CaptureSnapshot, Error>) {
        lock.lock()
        let existing = result
        if existing == nil { self.continuation = continuation }
        lock.unlock()
        if let existing { continuation.resume(with: existing) }
    }

    func finish(_ result: Result<CaptureSnapshot, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

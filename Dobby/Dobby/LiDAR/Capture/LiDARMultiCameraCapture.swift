import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import UIKit
import simd
import OSLog

/// A bounded mailbox shared with the GPU preview. A stopped generation cannot
/// clear or republish over a newer camera session.
nonisolated final class MultiCameraFrameStore: @unchecked Sendable {
    private struct State {
        var owner: UUID?
        var frame: MultiCameraFrame?
        var preview: MultiCameraPreviewFrame?
        var pinned: MultiCameraFrame?
        var revision: UInt64 = 0
    }
    private let state = Mutex(State())

    func begin(sessionID: UUID) { state.withLock { $0 = State(owner: sessionID) } }

    func publish(_ packet: MultiCameraFrame) {
        state.withLock {
            guard $0.owner == packet.sessionID,
                  $0.frame == nil || packet.timestamp > $0.frame!.timestamp else { return }
            $0.frame = packet
            // Never rewind a newer depthless preview to an older depth pair.
            guard $0.preview == nil || packet.timestamp >= $0.preview!.timestamp else { return }
            $0.revision &+= 1
            $0.preview = .init(packet, revision: $0.revision)
        }
    }

    func publishPreview(sessionID: UUID, timestamp: TimeInterval,
                        wideImage: CVPixelBuffer, calibration: MultiCameraLensCalibration) {
        state.withLock {
            guard $0.owner == sessionID, timestamp.isFinite, timestamp >= 0,
                  $0.preview == nil || timestamp > $0.preview!.timestamp else { return }
            $0.revision &+= 1
            $0.preview = .init(sessionID: sessionID, timestamp: timestamp, wideImage: wideImage,
                              calibration: calibration, revision: $0.revision)
        }
    }

    func latest() -> MultiCameraFrame? { state.withLock { $0.frame } }
    func latestPreview() -> MultiCameraPreviewFrame? { state.withLock { $0.preview } }

    func pin(_ frame: MultiCameraFrame) {
        state.withLock {
            guard $0.owner == frame.sessionID else { return }
            // Pin only the exact shutter winner, never substitute newer RGB.
            $0.pinned = $0.frame?.timestamp == frame.timestamp ? $0.frame : frame
        }
    }
    func pinned() -> MultiCameraFrame? { state.withLock { $0.pinned } }

    @discardableResult
    func clear(sessionID: UUID) -> Bool {
        state.withLock {
            guard $0.owner == sessionID else { return false }
            $0.owner = nil; $0.frame = nil; $0.preview = nil
            return true
        }
    }
}

/// Developer-only analysis isolation. No value or environment variable can
/// change the camera graph: both modes acquire calibrated wide + LiDAR only.
nonisolated enum CameraPerformanceExperiment: String, Sendable {
    case full, measurementOnly
    static let current: Self = {
        #if DEBUG
        let permitted = true
        #else
        let permitted = ProcessInfo.processInfo.environment["DOBBY_CAMERA_METRICS"] == "1"
        #endif
        guard permitted else { return .full }
        return Self(rawValue: ProcessInfo.processInfo.environment["DOBBY_CAMERA_EXPERIMENT"] ?? "") ?? .full
    }()
    var analyzesForeground: Bool { self == .full }
}

nonisolated enum LiDARMultiCameraCaptureError: LocalizedError, Sendable {
    case permission, unavailableDevices, unsupportedFormats, connection, startup
    case narrowedFieldOfView(expected: Float, available: Float, diagnostics: String = "")
    case noEligibleFormats(camera: String, diagnostics: String)
    case unsupportedPixelFormats(camera: String, supported: String)
    case unsupportedPhysicalZoom(camera: String, minimum: Double, maximum: Double, actual: Double)

    var errorDescription: String? {
        switch self {
        case .permission: "카메라 접근 권한이 필요해요. 설정에서 카메라 권한을 확인해 주세요."
        case .unavailableDevices: "LiDAR를 지원하는 후면 카메라를 찾지 못했어요. 다른 앱의 카메라 사용을 종료하고 다시 시도해 주세요."
        case .unsupportedFormats: "실측에 필요한 일반 영상·LiDAR 깊이 포맷을 준비하지 못했어요."
        case .connection: "카메라 영상과 깊이 출력을 연결하지 못했어요. 다시 시도해 주세요."
        case .startup: "카메라를 시작하지 못했어요. 다른 카메라 앱을 종료한 뒤 다시 시도해 주세요."
        case .narrowedFieldOfView(let expected, let available, let diagnostics):
            "일반·LiDAR의 기본 1x 화각을 유지할 수 없어요. 기준 \(String(format: "%.1f", expected))°, 지원 \(String(format: "%.1f", available))°예요. \(diagnostics)"
        case .noEligibleFormats(let camera, let diagnostics):
            "\(camera) 카메라에서 실측에 사용할 수 있는 영상·깊이 포맷이 없어요. \(diagnostics)"
        case .unsupportedPixelFormats(let camera, let supported):
            "\(camera) 카메라의 영상 픽셀 형식을 연결하지 못했어요. 지원 형식: \(supported)"
        case .unsupportedPhysicalZoom(let camera, let minimum, let maximum, let actual):
            "\(camera) 카메라의 실제 배율을 1x로 설정하지 못했어요. 범위 \(String(format: "%.2f", minimum))–\(String(format: "%.2f", maximum)), 현재 \(String(format: "%.2f", actual))x예요."
        }
    }
}

/// Full-sensor 4:3 and real depth are mandatory for the measurement pair.
nonisolated enum LiDARMultiCameraFormatPolicy {
    /// Small metadata/rounding tolerance only; not a substitute for a physical
    /// same-position comparison against the system Camera application.
    static let maximumFieldOfViewLossDegrees: Float = 0.25
    /// Full-field LiDAR formats can be available only above preview size.
    /// Try them after cheaper equivalent formats and let the committed graph
    /// decide sustainability; a fixed 2560px cap could hide a supported camera.
    static let maximumOutputWidth = 4_096

    static func isEligible(width: Int, height: Int, supportsFrameRate: Bool,
                           minimumWidth: Int, hasDepth: Bool,
                           maximumWidth: Int = maximumOutputWidth) -> Bool {
        supportsFrameRate && width >= minimumWidth && width <= maximumWidth
            && hasValidRaster(width: width, height: height)
            && isFullAspect(width: width, height: height) && hasDepth
    }

    static func hasValidRaster(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 16_384 && height <= 16_384
    }

    static func permitsPhysicalOneTimes(minimum: Double, maximum: Double) -> Bool {
        minimum.isFinite && maximum.isFinite && minimum > 0 && minimum <= 1 && maximum >= 1
    }

    static func isFullAspect(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 16_384 && height <= 16_384
            && abs(Double(width) / Double(height) - 4.0 / 3.0) < 0.01
    }

    static func widestNativeFieldOfView(_ values: [Float]) -> Float? {
        values.filter { $0.isFinite && $0 > 0 && $0 < 180 }.max()
    }

    static func preservesFieldOfView(_ fieldOfView: Float, widestCompatible: Float) -> Bool {
        fieldOfView.isFinite && widestCompatible.isFinite
            && fieldOfView > 0 && fieldOfView < 180
            && widestCompatible > 0 && widestCompatible < 180
            && fieldOfView >= widestCompatible - maximumFieldOfViewLossDegrees
    }

    static func acceptsFieldOfView(_ fieldOfView: Float, nativeReference: Float) -> Bool {
        preservesFieldOfView(fieldOfView, widestCompatible: nativeReference)
    }

    static func preferredWidthPenalty(width: Int, preferred: Int) -> Int {
        // Prefer the requested preview size, then smaller sustainable formats.
        // Formats larger than it are last, even when they are near that size.
        width <= preferred ? preferred - width : 10_000 + width - preferred
    }
}

/// First-rejection counts are disjoint, so a device screenshot can explain
/// exactly why a camera's declared formats never reached the candidate graph.
nonisolated struct LiDARMultiCameraFormatDiagnostics: Sendable {
    enum Rejection: String, CaseIterable, Sendable {
        case raster = "크기", aspect = "비율", frameRate = "30fps"
        case depth = "깊이", color = "색공간", fieldOfView = "화각", resolution = "해상도"
    }
    let total: Int
    var eligible = 0
    private var rejected: [Rejection: Int] = [:]

    init(total: Int) { self.total = max(0, total) }

    mutating func reject(_ reason: Rejection, count: Int = 1) {
        if count > 0 { rejected[reason, default: 0] += count }
    }

    var summary: String {
        let reasons = Rejection.allCases.compactMap { reason -> String? in
            let count = rejected[reason, default: 0]
            return count > 0 ? "\(reason.rawValue)\(count)" : nil
        }.joined(separator: "·")
        return "전체 \(total) / 유효 \(eligible) / 제외 \(reasons.isEmpty ? "없음" : reasons)"
    }
}

/// Counts delivery before packet validation. A synchronizer callback is allowed
/// to contain only some outputs; absence must stay distinct from a dropped
/// buffer or a calibration rejection. Contains no images or device identifiers.
nonisolated struct LiDARMultiCameraDeliveryDiagnostics: Sendable {
    struct Stream: Sendable {
        var received = 0
        var dropped = 0
        private var reasons: [Int: Int] = [:]

        mutating func observe(_ dropReason: Int?) {
            guard let dropReason else { return }
            received += 1
            if dropReason != 0 {
                dropped += 1
                reasons[dropReason, default: 0] += 1
            }
        }

        var summary: String {
            let codes = reasons.keys.sorted().map { "\($0):\(reasons[$0, default: 0])" }.joined(separator: ",")
            return "\(received)(드롭\(dropped)\(codes.isEmpty ? "" : ":" + codes))"
        }
    }

    private(set) var callbacks = 0
    private(set) var wide = Stream()
    private(set) var depth = Stream()
    private(set) var completeCollections = 0

    /// nil is absent, zero is delivered, and positive values are AVFoundation
    /// AVCaptureOutput.DataDroppedReason raw values (1 late, 2 pool, 3 gap).
    mutating func observe(wide: Int?, depth: Int?) {
        callbacks += 1
        self.wide.observe(wide)
        self.depth.observe(depth)
        if wide == 0, depth == 0 { completeCollections += 1 }
    }

    var summary: String {
        "콜백\(callbacks) / 일반\(wide.summary)·깊이\(depth.summary) / 전체묶음\(completeCollections)"
    }

    var failureDescription: String {
        if callbacks == 0 { return "동기화 콜백이 한 번도 도착하지 않았어요." }
        let required = [("일반 영상", wide.received), ("LiDAR 깊이", depth.received)]
        let missing = required.filter { $0.1 == 0 }.map(\.0)
        if !missing.isEmpty { return "\(missing.joined(separator: "·")) 데이터가 도착하지 않았어요." }
        return "영상과 깊이가 서로 다른 묶음으로 도착하거나 드롭되어 동기화하지 못했어요."
    }
}

/// Starting the capture session is not evidence that usable RGB/depth and lens
/// calibration have arrived. One waiter is resumed by the first VALID packet.
/// A failure between that packet and commitStart() still belongs to startup.
nonisolated final class MultiCameraFirstFrameGate<Value: Sendable>: @unchecked Sendable {
    private enum Phase { case waiting, ready(Value), started, failed(Error) }
    private struct State {
        var phase: Phase = .waiting
        var continuation: CheckedContinuation<Value, Error>?
        var waiterInstalled = false
    }
    private let state = Mutex(State())

    func waitForFirstFrame() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Value, Error>? = state.withLock {
                guard !$0.waiterInstalled else { return .failure(CancellationError()) }
                $0.waiterInstalled = true
                switch $0.phase {
                case .waiting: $0.continuation = continuation; return nil
                case .ready(let value): return .success(value)
                case .failed(let error): return .failure(error)
                case .started: return .failure(CancellationError())
                }
            }
            if let result { continuation.resume(with: result) }
        }
    }

    @discardableResult
    func acceptFirstFrame(_ value: Value) -> Bool {
        let accepted = state.withLock { current -> (Bool, CheckedContinuation<Value, Error>?) in
            guard case .waiting = current.phase else { return (false, nil) }
            current.phase = .ready(value)
            let continuation = current.continuation
            current.continuation = nil
            return (true, continuation)
        }
        accepted.1?.resume(returning: value)
        return accepted.0
    }

    /// True suppresses the runtime failure callback: start() will throw.
    @discardableResult
    func fail(_ error: Error) -> Bool {
        let transition = state.withLock { current -> (Bool, CheckedContinuation<Value, Error>?) in
            if case .failed = current.phase { return (true, nil) }
            let startup: Bool
            if case .started = current.phase { startup = false } else { startup = true }
            current.phase = .failed(error)
            let continuation = current.continuation
            current.continuation = nil
            return (startup, continuation)
        }
        transition.1?.resume(throwing: error)
        return transition.0
    }

    func commitStart() throws {
        try state.withLock {
            switch $0.phase {
            case .ready: $0.phase = .started
            case .failed(let error): throw error
            case .waiting, .started: throw CancellationError()
            }
        }
    }

    var failure: Error? {
        state.withLock { if case .failed(let error) = $0.phase { return error }; return nil }
    }
}

nonisolated private struct MultiCameraControlDevice: @unchecked Sendable {
    let device: AVCaptureDevice
}

/// RGB and LiDAR remain one atomic native pair.
/// Legacy type name retained at the provider boundary. Owns ONE LiDAR camera
/// input in a standard AVCaptureSession: one wide RGB output + one depth output.
/// ARKit stays paused while this session owns the device.
/// Depthless display packets cannot enter the measurement worker.
nonisolated final class LiDARMultiCameraCapture: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    let frames = MultiCameraFrameStore()

    private struct Ticket: Equatable, Sendable {
        var sessionID: UUID
        var nonce: UUID = UUID()
    }
    private struct RunState {
        var ticket: Ticket?
        var onFrame: (@Sendable (MultiCameraFrame) -> Void)?
        var onFailure: (@Sendable (UUID, String) -> Void)?
        var device: AVCaptureDevice?
        var synchronizerID: ObjectIdentifier?
        var startup: MultiCameraFirstFrameGate<MultiCameraControlDevice>?
        var startedAt = 0.0
        var lastPacketAt = 0.0
        var lastTimestamp: TimeInterval?
        var lastRejection: String?
        var delivery = LiDARMultiCameraDeliveryDiagnostics()
        var previewCalibration: (time: TimeInterval, lens: MultiCameraLensCalibration)?
    }
    private let state = Mutex(RunState())
    private let sessionQueue = DispatchQueue(label: "com.dobby.lidar.multicam.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "com.dobby.lidar.multicam.frames", qos: .userInteractive)
    private let wideOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()

    // The following properties belong exclusively to sessionQueue.
    private var configuredTicket: Ticket?
    private var wideInput: AVCaptureDeviceInput?
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var notifications: [NSObjectProtocol] = []
    private var pressureObservations: [NSKeyValueObservation] = []
    private var watchdog: DispatchSourceTimer?
    private var reducedFrameRate = false
    private var pressureLevels: [ObjectIdentifier: AVCaptureDevice.SystemPressureState.Level] = [:]
    private var pressureRecovery: DispatchWorkItem?
    private var pressureRecoveryToken: UUID?
    private var lastCostReportAt: TimeInterval = -.infinity
    private let logger = Logger(subsystem: "com.dobby.camera", category: "LiDARMultiCam")

    func start(sessionID: UUID,
               onFrame: @escaping @Sendable (MultiCameraFrame) -> Void,
               onFailure: @escaping @Sendable (UUID, String) -> Void) async throws -> AVCaptureDevice {
        try Task.checkCancellation()
        let ticket = Ticket(sessionID: sessionID)
        let startup = MultiCameraFirstFrameGate<MultiCameraControlDevice>()
        state.withLock {
            $0.startup?.fail(CancellationError())
            $0 = RunState(ticket: ticket, onFrame: onFrame, onFailure: onFailure)
            $0.startup = startup
            frames.begin(sessionID: sessionID)
            CameraFramePerformanceMetrics.shared.begin(sessionID: sessionID)
        }
        return try await withTaskCancellationHandler {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    sessionQueue.async { [self] in
                        do {
                            guard isCurrent(ticket) else { throw CancellationError() }
                            tearDown()
                            let device = try configure(ticket: ticket)
                            guard isCurrent(ticket) else { throw CancellationError() }
                            installObservers(ticket: ticket, device: device)
                            state.withLock {
                                guard $0.ticket == ticket else { return }
                                $0.device = device
                                $0.startedAt = ProcessInfo.processInfo.systemUptime
                            }
                            session.startRunning()
                            guard isCurrent(ticket), session.isRunning, !session.isInterrupted else {
                                throw isCurrent(ticket) ? LiDARMultiCameraCaptureError.startup : (startup.failure ?? CancellationError())
                            }
                            installWatchdog(ticket: ticket)
                            continuation.resume()
                        } catch {
                            startup.fail(error)
                            if configuredTicket == ticket { tearDown() }
                            clear(ticket)
                            continuation.resume(throwing: error)
                        }
                    }
                }
                let accepted = try await startup.waitForFirstFrame()
                try Task.checkCancellation()
                return try state.withLock { current in
                    guard current.ticket == ticket else { throw startup.failure ?? CancellationError() }
                    try startup.commitStart()
                    return accepted.device
                }
            } catch {
                // Release the camera hardware before the caller starts ARKit.
                // A watchdog may already have cleared RunState; the private
                // ticket still identifies the configured hardware to retire.
                let failure = startup.failure ?? error
                logger.error("LiDAR capture startup failed: \(failure.localizedDescription, privacy: .public)")
                await retire(ticket)
                throw failure
            }
        } onCancel: {
            self.cancel(ticket)
        }
    }

    /// Passing the old UUID is essential when a UI pause races a fresh start.
    /// Nil is reserved for an explicit owner-wide shutdown.
    func stop(sessionID: UUID? = nil) async {
        let ticket = state.withLock { current -> Ticket? in
            guard let ticket = current.ticket,
                  sessionID == nil || ticket.sessionID == sessionID else { return nil }
            current.startup?.fail(CancellationError())
            current = RunState()
            frames.clear(sessionID: ticket.sessionID)
            CameraFramePerformanceMetrics.shared.end(sessionID: ticket.sessionID)
            return ticket
        }
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                // A stale stop cannot stop a more recently configured owner.
                if sessionID == nil {
                    if state.withLock({ $0.ticket == nil }) { tearDown() }
                } else if let ticket, configuredTicket == ticket {
                    tearDown()
                }
                continuation.resume()
            }
        }
    }

    func device(for sessionID: UUID) -> AVCaptureDevice? {
        state.withLock { $0.ticket?.sessionID == sessionID ? $0.device : nil }
    }

    private func isCurrent(_ ticket: Ticket) -> Bool { state.withLock { $0.ticket == ticket } }

    private func cancel(_ ticket: Ticket) {
        clear(ticket)
        sessionQueue.async { [self] in
            if configuredTicket == ticket { tearDown() }
        }
    }

    private func clear(_ ticket: Ticket) {
        state.withLock { current in
            guard current.ticket == ticket else { return }
            current.startup?.fail(CancellationError())
            current = RunState()
            frames.clear(sessionID: ticket.sessionID)
            CameraFramePerformanceMetrics.shared.end(sessionID: ticket.sessionID)
        }
    }

    private func retire(_ ticket: Ticket) async {
        clear(ticket)
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if configuredTicket == ticket { tearDown() }
                continuation.resume()
            }
        }
    }

    private struct FormatChoice {
        let format: AVCaptureDevice.Format
        let depth: AVCaptureDevice.Format?
        let width: Int
        let fieldOfView: Float
    }

    private func configure(ticket: Ticket) throws -> AVCaptureDevice {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw LiDARMultiCameraCaptureError.permission
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInLiDARDepthCamera, .builtInWideAngleCamera], mediaType: .video, position: .back)
        guard let lidar = discovery.devices.first(where: { $0.deviceType == .builtInLiDARDepthCamera }),
              let physicalWide = lidar.constituentDevices.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera && !$0.isVirtualDevice }) else {
            throw LiDARMultiCameraCaptureError.unavailableDevices
        }
        let formats = try formatChoices(for: lidar, minimumWidth: 1_280, preferredWidth: 1_920,
                                        nativeReferenceDevice: physicalWide)
        let input = try AVCaptureDeviceInput(device: lidar)
        configuredTicket = ticket
        session.beginConfiguration()
        var configurationOpen = true
        defer { if configurationOpen { session.commitConfiguration() } }
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        guard session.canAddInput(input) else { throw LiDARMultiCameraCaptureError.connection }
        session.addInputWithNoConnections(input)
        wideInput = input
        // Explicit formats preserve the complete 1x field; preset-driven
        // reconfiguration must not silently resize/crop the calibrated pair.
        guard session.canSetSessionPreset(.inputPriority) else { throw LiDARMultiCameraCaptureError.unsupportedFormats }
        session.sessionPreset = .inputPriority
        guard let widePort = input.ports.first(where: { $0.mediaType == .video }),
              let depthPort = input.ports.first(where: { $0.mediaType == .depthData }) else {
            throw LiDARMultiCameraCaptureError.connection
        }
        wideOutput.alwaysDiscardsLateVideoFrames = true
        wideOutput.automaticallyConfiguresOutputBufferDimensions = false
        wideOutput.deliversPreviewSizedOutputBuffers = false
        depthOutput.alwaysDiscardsLateDepthData = true
        depthOutput.isFilteringEnabled = false
        for output: AVCaptureOutput in [wideOutput, depthOutput] {
            guard session.canAddOutput(output) else { throw LiDARMultiCameraCaptureError.connection }
            session.addOutputWithNoConnections(output)
        }
        let connection = try connect(widePort, to: wideOutput)
        _ = try connect(depthPort, to: depthOutput)
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }

        var selected: FormatChoice?
        var lastPixelFormatFailure: LiDARMultiCameraCaptureError?
        for choice in formats {
            guard isCurrent(ticket) else { throw CancellationError() }
            try select(choice, on: lidar)
            input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 30)
            let supported = wideOutput.availableVideoPixelFormatTypes
            guard let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     kCVPixelFormatType_32BGRA].first(where: supported.contains) else {
                let codes = supported.prefix(8).map { String(format: "0x%08X", $0) }.joined(separator: ",")
                lastPixelFormatFailure = .unsupportedPixelFormats(camera: "일반·LiDAR", supported: codes)
                continue
            }
            wideOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            session.commitConfiguration(); configurationOpen = false
            connection.isCameraIntrinsicMatrixDeliveryEnabled = connection.isCameraIntrinsicMatrixDeliverySupported
            // With one video output hardwareCost may be zero; it is not a
            // sustained-performance proof. Runtime device pressure is observed.
            if session.hardwareCost.isFinite, session.hardwareCost >= 0, session.hardwareCost <= 1 {
                selected = choice; break
            }
            session.beginConfiguration(); configurationOpen = true
        }
        guard let selected else {
            if let lastPixelFormatFailure { throw lastPixelFormatFailure }
            throw LiDARMultiCameraCaptureError.unsupportedFormats
        }
        if CameraFramePerformanceMetrics.shared.isEnabled {
            let rgb = CMVideoFormatDescriptionGetDimensions(selected.format.formatDescription)
            let depth = selected.depth.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
            CameraFramePerformanceMetrics.shared.configuration(
                "mode=\(CameraPerformanceExperiment.current.rawValue) inputs=1 wide=\(rgb.width)x\(rgb.height) depth=\(depth?.width ?? 0)x\(depth?.height ?? 0) targetFPS=30 hardwareCost=\(session.hardwareCost)",
                sessionID: ticket.sessionID)
        }
        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [wideOutput, depthOutput])
        state.withLock {
            guard $0.ticket == ticket else { return }
            $0.synchronizerID = ObjectIdentifier(synchronizer)
        }
        synchronizer.setDelegate(self, queue: outputQueue)
        self.synchronizer = synchronizer
        return lidar
    }

    private func formatChoices(for device: AVCaptureDevice, minimumWidth: Int,
                               preferredWidth: Int,
                               nativeReferenceDevice: AVCaptureDevice? = nil) throws -> [FormatChoice] {
        // Find the widest full-aspect source BEFORE applying our resolution /
        // bandwidth ceiling. A larger or lower-resolution full-sensor format
        // may reveal that an otherwise suitable 4:3 format is actually cropped.
        let camera = "일반·LiDAR"
        var diagnostics = LiDARMultiCameraFormatDiagnostics(total: device.formats.count)
        let compatible = device.formats.compactMap { format -> FormatChoice? in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let depth = format.supportedDepthDataFormats.filter {
                let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return (type == kCVPixelFormatType_DepthFloat16 || type == kCVPixelFormatType_DepthFloat32)
                    && supports(30, format: $0)
            }.max {
                let lhs = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let rhs = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return lhs.width * lhs.height < rhs.width * rhs.height
            }
            guard LiDARMultiCameraFormatPolicy.hasValidRaster(width: Int(size.width), height: Int(size.height)) else {
                diagnostics.reject(.raster); return nil
            }
            guard LiDARMultiCameraFormatPolicy.isFullAspect(width: Int(size.width), height: Int(size.height)) else {
                diagnostics.reject(.aspect); return nil
            }
            guard supports(30, format: format) else { diagnostics.reject(.frameRate); return nil }
            guard depth != nil else { diagnostics.reject(.depth); return nil }
            guard format.supportedColorSpaces.contains(.sRGB) else { diagnostics.reject(.color); return nil }
            let fieldOfView = format.videoFieldOfView
            guard fieldOfView.isFinite, fieldOfView > 0, fieldOfView < 180 else {
                diagnostics.reject(.fieldOfView); return nil
            }
            return FormatChoice(format: format, depth: depth, width: Int(size.width), fieldOfView: fieldOfView)
        }
        // Full native LiDAR/physical-wide formats define 1x before frame-rate,
        // depth or bandwidth filtering. Uniformly cropped candidates cannot
        // redefine the normal lens's field of view.
        let referenceValues: [Float] = ([device] + [nativeReferenceDevice].compactMap({ $0 })).flatMap(\.formats).compactMap { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard LiDARMultiCameraFormatPolicy.isFullAspect(width: Int(size.width), height: Int(size.height)) else { return nil }
            return format.videoFieldOfView
        }
        guard let widest = LiDARMultiCameraFormatPolicy.widestNativeFieldOfView(referenceValues) else {
            diagnostics.reject(.fieldOfView, count: compatible.count)
            throw LiDARMultiCameraCaptureError.noEligibleFormats(camera: camera, diagnostics: diagnostics.summary)
        }
        let resolutionCandidates = compatible.filter {
            $0.width >= minimumWidth && $0.width <= LiDARMultiCameraFormatPolicy.maximumOutputWidth
        }
        diagnostics.reject(.resolution, count: compatible.count - resolutionCandidates.count)
        let preserving = resolutionCandidates.filter {
            LiDARMultiCameraFormatPolicy.acceptsFieldOfView($0.fieldOfView,
                nativeReference: widest)
        }
        diagnostics.reject(.fieldOfView, count: resolutionCandidates.count - preserving.count)
        diagnostics.eligible = preserving.count
        logger.info("\(camera, privacy: .public) format scan: \(diagnostics.summary, privacy: .public)")
        if preserving.isEmpty,
           let available = resolutionCandidates.map(\.fieldOfView).max() {
            #if DEBUG
            logger.error("Full native 1x rejected: requiredFov=\(widest, privacy: .public) availableLiDARFov=\(available, privacy: .public) tolerance=\(LiDARMultiCameraFormatPolicy.maximumFieldOfViewLossDegrees, privacy: .public)")
            #endif
            throw LiDARMultiCameraCaptureError.narrowedFieldOfView(expected: widest, available: available,
                diagnostics: diagnostics.summary)
        }
        guard !preserving.isEmpty else {
            throw LiDARMultiCameraCaptureError.noEligibleFormats(camera: camera, diagnostics: diagnostics.summary)
        }
        return preserving.sorted {
            let firstPenalty = LiDARMultiCameraFormatPolicy.preferredWidthPenalty(width: $0.width, preferred: preferredWidth)
            let secondPenalty = LiDARMultiCameraFormatPolicy.preferredWidthPenalty(width: $1.width, preferred: preferredWidth)
            // Every surviving candidate preserves native 1x. Prefer 1920/1280
            // before a 4032px fallback, not negligible rounding in FOV metadata.
            if firstPenalty != secondPenalty { return firstPenalty < secondPenalty }
            return $0.fieldOfView > $1.fieldOfView
        }
    }

    private func supports(_ fps: Double, format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }
    }

    private func select(_ choice: FormatChoice, on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = choice.format
        if choice.format.isAutoVideoFrameRateSupported { device.isAutoVideoFrameRateEnabled = false }
        if let depth = choice.depth {
            device.activeDepthDataFormat = depth
            device.activeDepthDataMinFrameDuration = CMTime(value: 1, timescale: 30)
        }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        let camera = "일반·LiDAR"
        let minimumZoom = Double(device.minAvailableVideoZoomFactor)
        let maximumZoom = Double(device.maxAvailableVideoZoomFactor)
        guard LiDARMultiCameraFormatPolicy.permitsPhysicalOneTimes(minimum: minimumZoom, maximum: maximumZoom) else {
            throw LiDARMultiCameraCaptureError.unsupportedPhysicalZoom(camera: camera,
                minimum: minimumZoom, maximum: maximumZoom, actual: Double(device.videoZoomFactor))
        }
        device.videoZoomFactor = 1 // Digital 2x is registered once by the measurement pipeline.
        guard abs(device.videoZoomFactor - 1) < 0.001 else {
            throw LiDARMultiCameraCaptureError.unsupportedPhysicalZoom(camera: camera,
                minimum: minimumZoom, maximum: maximumZoom, actual: Double(device.videoZoomFactor))
        }
        if device.isGeometricDistortionCorrectionSupported {
            // Wide RGB AND depth are rectified together by MultiCameraFrame.
            device.isGeometricDistortionCorrectionEnabled = false
        }
        if choice.format.supportedColorSpaces.contains(.sRGB) { device.activeColorSpace = .sRGB }
        device.automaticallyAdjustsVideoHDREnabled = false
        if choice.format.isVideoHDRSupported { device.isVideoHDREnabled = false }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
    }

    @discardableResult
    private func connect(_ port: AVCaptureInput.Port, to output: AVCaptureOutput) throws -> AVCaptureConnection {
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else { throw LiDARMultiCameraCaptureError.connection }
        session.addConnection(connection)
        return connection
    }

    private func installObservers(ticket: Ticket, device: AVCaptureDevice) {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
            self?.fail(ticket, message: "카메라 연결이 끊겼어요. \(message ?? "촬영 화면을 다시 열어 주세요.")")
        })
        notifications.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.fail(ticket, message: "다른 카메라 사용이나 기기 상태로 촬영이 중단됐어요. 다른 앱의 카메라를 종료하고 다시 시도해 주세요.")
        })
        notifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cancel(ticket)
        })
        for source in [device] {
            pressureObservations.append(source.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                let level = device.systemPressureState.level
                self?.sessionQueue.async { [weak self] in self?.handlePressure(level, sourceID: ObjectIdentifier(device), ticket: ticket) }
            })
        }
    }

    private func installWatchdog(ticket: Ticket) {
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 4, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let timeout = self.state.withLock { current -> (reason: String, summary: String)? in
                guard current.ticket == ticket else { return nil }
                let last = current.lastPacketAt > 0 ? current.lastPacketAt : current.startedAt
                guard last > 0, ProcessInfo.processInfo.systemUptime - last > 3 else { return nil }
                return (current.lastRejection ?? current.delivery.failureDescription, current.delivery.summary)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if CameraFramePerformanceMetrics.shared.isEnabled, now - self.lastCostReportAt >= 5 {
                self.lastCostReportAt = now
                let wideFPS = self.wideInput.map { CMTimeGetSeconds($0.device.activeVideoMinFrameDuration) }.map { $0 > 0 ? 1 / $0 : 0 } ?? 0
                let pressure = self.pressureLevels.values.map(\.rawValue).sorted().joined(separator: ",")
                CameraFramePerformanceMetrics.shared.configuration(
                    "wideFPS=\(wideFPS) hardwareCost=\(self.session.hardwareCost) pressure=\(pressure)",
                    sessionID: ticket.sessionID)
            }
            if let timeout {
                let connections = self.connectionDiagnostics()
                self.logger.error("Delivery timeout: \(timeout.summary, privacy: .public); \(connections.detailed, privacy: .public)")
                self.fail(ticket, message: "카메라 영상을 준비하지 못했어요. \(timeout.reason) \(timeout.summary). \(connections.visible) 촬영 화면을 다시 열어 주세요.")
            }
        }
        watchdog = timer
        timer.resume()
    }

    /// Called only on sessionQueue. Reading connection state does not modify
    /// routing or bypass the native LiDAR RGB/depth pairing.
    private func connectionDiagnostics() -> (visible: String, detailed: String) {
        let outputs: [(String, AVCaptureOutput)] = [("일반", wideOutput), ("깊이", depthOutput)]
        let visible = outputs.map { name, output in
            "\(name)\(output.connections.contains(where: \.isActive) ? 1 : 0)"
        }.joined(separator: "·")
        let detailed = outputs.map { name, output in
            let connections = output.connections.map { connection in
                let ports = connection.inputPorts.map { port in
                    "\(port.mediaType.rawValue):\(port.sourceDeviceType?.rawValue ?? "unknown"):\(port.isEnabled ? 1 : 0)"
                }.joined(separator: ",")
                return "enabled=\(connection.isEnabled ? 1 : 0),active=\(connection.isActive ? 1 : 0),ports=[\(ports)]"
            }.joined(separator: ";")
            return "\(name){\(connections)}"
        }.joined(separator: " ")
        return ("연결 활성 \(visible).", detailed)
    }

    private func handlePressure(_ level: AVCaptureDevice.SystemPressureState.Level,
                                sourceID: ObjectIdentifier, ticket: Ticket) {
        guard configuredTicket == ticket, isCurrent(ticket) else { return }
        pressureLevels[sourceID] = level
        let levels = Array(pressureLevels.values)
        if levels.contains(.critical) || levels.contains(.shutdown) {
            pressureRecovery?.cancel(); pressureRecovery = nil; pressureRecoveryToken = nil
            fail(ticket, message: "카메라 처리 부하가 높아 촬영을 중단했어요. 기기를 식힌 뒤 다시 시도해 주세요.")
            return
        }
        if levels.contains(.serious) {
            pressureRecovery?.cancel(); pressureRecovery = nil; pressureRecoveryToken = nil
            guard !reducedFrameRate else { return }
            do {
                try applyFrameRate(15)
                reducedFrameRate = true
                CameraFramePerformanceMetrics.shared.configuration("pressure response: paired streams=15fps", sessionID: ticket.sessionID)
            } catch {
                fail(ticket, message: "카메라 부하를 낮추면서 사진·깊이 동기화를 유지하지 못했어요. 촬영 화면을 다시 열어 주세요.")
            }
            return
        }
        guard reducedFrameRate, levels.count == pressureObservations.count,
              levels.allSatisfy({ $0 == .nominal }) else {
            pressureRecovery?.cancel(); pressureRecovery = nil; pressureRecoveryToken = nil
            return
        }
        guard pressureRecovery == nil else { return }
        schedulePressureRecovery(ticket: ticket, attempt: 0)
    }

    private func schedulePressureRecovery(ticket: Ticket, attempt: Int) {
        // Ten seconds nominal initially; failed recovery retries at bounded
        // 20/40-second intervals even if no further KVO notification arrives.
        let token = UUID()
        pressureRecoveryToken = token
        let recovery = DispatchWorkItem { [weak self] in
            guard let self, self.pressureRecoveryToken == token, self.configuredTicket == ticket,
                  self.isCurrent(ticket), self.reducedFrameRate,
                  self.pressureLevels.count == self.pressureObservations.count,
                  self.pressureLevels.values.allSatisfy({ $0 == .nominal }) else { return }
            self.pressureRecovery = nil; self.pressureRecoveryToken = nil
            do {
                try self.applyFrameRate(30)
                self.reducedFrameRate = false
                CameraFramePerformanceMetrics.shared.configuration("pressure recovered: paired streams=30fps", sessionID: ticket.sessionID)
            } catch {
                self.logger.error("Could not restore camera frame rate: \(error.localizedDescription, privacy: .public)")
                if attempt < 2 { self.schedulePressureRecovery(ticket: ticket, attempt: attempt + 1) }
            }
        }
        pressureRecovery = recovery
        sessionQueue.asyncAfter(deadline: .now() + 10 * pow(2.0, Double(attempt)), execute: recovery)
    }

    /// Same-session FPS adjustment only: no active-format, K, LUT or depth
    /// changes. Acquire every device lock before mutating any stream.
    private func applyFrameRate(_ fps: Int32) throws {
        guard let wideInput,
              supports(Double(fps), format: wideInput.device.activeFormat),
              let depth = wideInput.device.activeDepthDataFormat,
              supports(Double(fps), format: depth) else { throw LiDARMultiCameraCaptureError.unsupportedFormats }
        var locked: [AVCaptureDevice] = []
        defer { locked.reversed().forEach { $0.unlockForConfiguration() } }
        for input in [wideInput] {
            try input.device.lockForConfiguration(); locked.append(input.device)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let duration = CMTime(value: 1, timescale: fps)
        for input in [wideInput] {
            input.device.activeVideoMinFrameDuration = duration
            input.device.activeVideoMaxFrameDuration = duration
            input.videoMinFrameDurationOverride = duration
        }
        wideInput.device.activeDepthDataMinFrameDuration = duration
    }

    private func fail(_ ticket: Ticket, message: String) {
        let callback = state.withLock { current -> (@Sendable (UUID, String) -> Void)? in
            guard current.ticket == ticket else { return nil }
            let startupFailed = current.startup?.fail(MultiCameraStartupFailure(message: message)) ?? true
            let callback = startupFailed ? nil : current.onFailure
            current = RunState()
            frames.clear(sessionID: ticket.sessionID)
            CameraFramePerformanceMetrics.shared.end(sessionID: ticket.sessionID)
            return callback
        }
        callback?(ticket.sessionID, message)
        sessionQueue.async { [self] in
            if configuredTicket == ticket { tearDown() }
        }
    }

    private func tearDown() {
        pressureRecovery?.cancel(); pressureRecovery = nil; pressureRecoveryToken = nil
        pressureLevels.removeAll()
        lastCostReportAt = -.infinity
        watchdog?.cancel()
        watchdog = nil
        pressureObservations.forEach { $0.invalidate() }
        pressureObservations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        synchronizer?.setDelegate(nil, queue: nil)
        synchronizer = nil
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for connection in session.connections { session.removeConnection(connection) }
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        wideInput = nil
        configuredTicket = nil
        reducedFrameRate = false
    }

    deinit {
        watchdog?.cancel()
        pressureObservations.forEach { $0.invalidate() }
        notifications.forEach(NotificationCenter.default.removeObserver)
        synchronizer?.setDelegate(nil, queue: nil)
        let teardown = SessionTeardown(session: session)
        sessionQueue.async { teardown.stop() }
    }
}

nonisolated private struct MultiCameraStartupFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Ownership transfers out of deinit to the same serial queue that owned all
/// session configuration. No caller can access this one-shot teardown handle.
nonisolated private struct SessionTeardown: @unchecked Sendable {
    let session: AVCaptureSession
    func stop() {
        if session.isRunning { session.stopRunning() }
    }
}

extension LiDARMultiCameraCapture: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        let wide = collection.synchronizedData(for: wideOutput) as? AVCaptureSynchronizedSampleBufferData
        let depth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData
        let admission = state.withLock { current -> Ticket? in
            guard current.synchronizerID == ObjectIdentifier(synchronizer),
                  let ticket = current.ticket else { return nil }
            current.delivery.observe(wide: wide.map { $0.sampleBufferWasDropped ? $0.droppedReason.rawValue : 0 },
                depth: depth.map { $0.depthDataWasDropped ? $0.droppedReason.rawValue : 0 })
            return ticket
        }
        guard let ticket = admission else { return }
        let metrics = CameraFramePerformanceMetrics.shared
        observe(wide, stage: .wideInput, late: .wideLate, ticket: ticket)
        if let depth {
            if depth.depthDataWasDropped { recordDrop(depth.droppedReason, late: .depthLate, ticket: ticket) }
            else { metrics.event(.depthInput, timestamp: depth.timestamp.seconds, sessionID: ticket.sessionID) }
        }
        var primary: MultiCameraFrame?
        if let wide, let depth, !wide.sampleBufferWasDropped, !depth.depthDataWasDropped {
            do {
                primary = try MultiCameraFrame.makePrimary(sessionID: ticket.sessionID,
                    wide: wide.sampleBuffer, wideTimestamp: wide.timestamp,
                    depth: depth.depthData, depthTimestamp: depth.timestamp)
            } catch {
                metrics.drop(.primaryRejected, sessionID: ticket.sessionID)
                state.withLock { if $0.ticket == ticket { $0.lastRejection = error.localizedDescription } }
            }
        } else if let wide, !wide.sampleBufferWasDropped {
            metrics.drop(.missingWideDepth, sessionID: ticket.sessionID)
            // Current video K must prove a recent same-session LUT is still valid.
            // A missing K fails closed; no old depth is ever attached to this RGB.
            let calibration = state.withLock { $0.ticket == ticket ? $0.previewCalibration : nil }
            if let calibration, wide.timestamp.seconds >= calibration.time,
               wide.timestamp.seconds - calibration.time <= 0.10,
               (try? MultiCameraFrame.validatePreviewCalibration(wide.sampleBuffer, calibration: calibration.lens)) != nil,
               let image = CMSampleBufferGetImageBuffer(wide.sampleBuffer) {
                state.withLock { current in
                    guard current.ticket == ticket else { return }
                    frames.publishPreview(sessionID: ticket.sessionID, timestamp: wide.timestamp.seconds,
                                          wideImage: image, calibration: calibration.lens)
                }
            }
        }

        var admitted: MultiCameraFrame?
        let callback = state.withLock { current -> (@Sendable (MultiCameraFrame) -> Void)? in
            guard current.ticket == ticket, let primary,
                  current.lastTimestamp == nil || primary.timestamp > current.lastTimestamp! else { return nil }
            current.lastTimestamp = primary.timestamp
            current.lastPacketAt = ProcessInfo.processInfo.systemUptime
            current.lastRejection = nil
            current.previewCalibration = (primary.timestamp, primary.wideCalibration)
            frames.publish(primary)
            if let device = current.device { current.startup?.acceptFirstFrame(MultiCameraControlDevice(device: device)) }
            admitted = primary
            return current.onFrame
        }
        if let admitted {
            metrics.event(.primaryPublished, timestamp: admitted.timestamp, sessionID: ticket.sessionID)
            callback?(admitted)
        }
    }

    private func observe(_ sample: AVCaptureSynchronizedSampleBufferData?,
                         stage: CameraFramePerformanceMetrics.Stage,
                         late: CameraFramePerformanceMetrics.DropReason, ticket: Ticket) {
        guard let sample else { return }
        if sample.sampleBufferWasDropped { recordDrop(sample.droppedReason, late: late, ticket: ticket) }
        else { CameraFramePerformanceMetrics.shared.event(stage, timestamp: sample.timestamp.seconds, sessionID: ticket.sessionID) }
    }

    private func recordDrop(_ reason: AVCaptureOutput.DataDroppedReason,
                            late: CameraFramePerformanceMetrics.DropReason, ticket: Ticket) {
        let drop: CameraFramePerformanceMetrics.DropReason
        switch reason.rawValue {
        case 2: drop = .outOfBuffers
        case 3: drop = .discontinuity
        default: drop = late
        }
        CameraFramePerformanceMetrics.shared.drop(drop, sessionID: ticket.sessionID)
    }
}

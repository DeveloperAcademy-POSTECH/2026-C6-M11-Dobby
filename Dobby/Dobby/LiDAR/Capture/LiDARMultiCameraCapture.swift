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
        var pinned: MultiCameraFrame?
    }
    private let state = Mutex(State())

    func begin(sessionID: UUID) {
        state.withLock { $0 = State(owner: sessionID) }
    }

    func publish(_ packet: MultiCameraFrame) {
        state.withLock {
            guard $0.owner == packet.sessionID else { return }
            $0.frame = packet
        }
    }

    func latest() -> MultiCameraFrame? { state.withLock { $0.frame } }

    func pin(_ frame: MultiCameraFrame) {
        state.withLock {
            guard $0.owner == frame.sessionID else { return }
            $0.pinned = frame
        }
    }

    func pinned() -> MultiCameraFrame? { state.withLock { $0.pinned } }

    @discardableResult
    func clear(sessionID: UUID) -> Bool {
        state.withLock {
            guard $0.owner == sessionID else { return false }
            // A paused camera keeps the exact shutter winner available to the
            // frozen composite. begin() clears it on a genuinely new session.
            $0.owner = nil
            $0.frame = nil
            return true
        }
    }
}

nonisolated enum LiDARMultiCameraCaptureError: LocalizedError, Sendable {
    case permission, unsupported, unavailableDevices, unsupportedCombination
    case unsupportedFormats, invalidCalibration, missingUltraWideIntrinsics, connection, budget, startup
    case narrowedFieldOfView(expected: Float, available: Float, diagnostics: String = "")
    case noEligibleFormats(camera: String, diagnostics: String)
    case unsupportedPixelFormats(camera: String, supported: String)
    case unsupportedPhysicalZoom(camera: String, minimum: Double, maximum: Double, actual: Double)

    var errorDescription: String? {
        switch self {
        case .permission: "카메라 접근 권한이 필요해요. 설정에서 카메라 권한을 확인해 주세요."
        case .unsupported: "이 기기는 LiDAR와 초광각 카메라를 동시에 사용할 수 없어요."
        case .unavailableDevices: "LiDAR와 초광각 카메라를 찾지 못했어요. 다른 앱의 카메라 사용을 종료하고 다시 시도해 주세요."
        case .unsupportedCombination: "이 기기에서는 LiDAR와 초광각 카메라의 동시 촬영 조합을 지원하지 않아요."
        case .unsupportedFormats: "실측에 필요한 화각·깊이·동시 촬영 포맷을 준비하지 못했어요."
        case .invalidCalibration: "두 카메라의 위치 보정 정보를 확인하지 못했어요. 잘못된 경계 영상과 측정값이 표시되지 않도록 촬영을 중단했어요."
        case .missingUltraWideIntrinsics: "초광각 영상의 렌즈 보정 정보를 받을 수 없어 주변 화면을 연결하지 못했어요."
        case .connection: "카메라 영상과 깊이 출력을 연결하지 못했어요. 다시 시도해 주세요."
        case .budget: "LiDAR와 초광각 카메라를 함께 실행할 여유가 부족해요. 기기를 식힌 뒤 다시 시도해 주세요."
        case .startup: "카메라를 시작하지 못했어요. 다른 카메라 앱을 종료한 뒤 다시 시도해 주세요."
        case .narrowedFieldOfView(let expected, let available, let diagnostics):
            "일반·LiDAR의 기본 1x 화각을 유지할 수 없어요. 기준 \(String(format: "%.1f", expected))°, 지원 \(String(format: "%.1f", available))°예요. \(diagnostics)"
        case .noEligibleFormats(let camera, let diagnostics):
            "\(camera) 카메라에서 사용할 수 있는 동시 촬영 포맷이 없어요. \(diagnostics)"
        case .unsupportedPixelFormats(let camera, let supported):
            "\(camera) 카메라의 영상 픽셀 형식을 연결하지 못했어요. 지원 형식: \(supported)"
        case .unsupportedPhysicalZoom(let camera, let minimum, let maximum, let actual):
            "\(camera) 카메라의 실제 배율을 1x로 설정하지 못했어요. 범위 \(String(format: "%.2f", minimum))–\(String(format: "%.2f", maximum)), 현재 \(String(format: "%.2f", actual))x예요."
        }
    }
}

/// Full-sensor 4:3 is mandatory for the measurement wide/depth pair. The
/// display-only ultra-wide may use a different aspect, projected with its own
/// delivered K and raster dimensions; it never changes measurement 1x.
nonisolated enum LiDARMultiCameraFormatPolicy {
    /// Small metadata/rounding tolerance only; not a substitute for a physical
    /// same-position comparison against the system Camera application.
    static let maximumFieldOfViewLossDegrees: Float = 0.25
    /// Full-field LiDAR formats can be available only above preview size.
    /// Try them after cheaper equivalent formats and let the committed graph
    /// decide sustainability; a fixed 2560px cap could hide a supported camera.
    static let maximumOutputWidth = 4_096

    static func isEligible(width: Int, height: Int, multiCam: Bool,
                           supportsFrameRate: Bool, minimumWidth: Int,
                           requiresDepth: Bool, hasDepth: Bool,
                           maximumWidth: Int = maximumOutputWidth) -> Bool {
        multiCam && supportsFrameRate && width >= minimumWidth && width <= maximumWidth
            && hasValidRaster(width: width, height: height)
            && (!requiresDepth || (isFullAspect(width: width, height: height) && hasDepth))
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

    static func acceptsFieldOfView(_ fieldOfView: Float, nativeReference: Float,
                                   requiresDepth: Bool) -> Bool {
        guard fieldOfView.isFinite, fieldOfView > 0, fieldOfView < 180,
              nativeReference.isFinite, nativeReference > 0, nativeReference < 180 else { return false }
        // Only the wide RGB/depth pair defines measurement 1x. The display-only
        // ultra-wide can use a cheaper corrected FOV because its delivered K
        // projects those exact pixels; it never replaces measurement RGB/depth.
        return !requiresDepth || preservesFieldOfView(fieldOfView, widestCompatible: nativeReference)
    }

    static func preferredWidthPenalty(width: Int, preferred: Int) -> Int {
        // Prefer the requested preview size, then smaller sustainable formats.
        // Formats larger than it are last, even when they are near that size.
        width <= preferred ? preferred - width : 10_000 + width - preferred
    }

    static func isAffordable(hardware: Float, pressure: Float) -> Bool {
        hardware.isFinite && pressure.isFinite && hardware >= 0 && pressure >= 0
            && hardware <= 1 && pressure <= 1
    }
}

/// First-rejection counts are disjoint, so a device screenshot can explain
/// exactly why a camera's declared formats never reached the candidate graph.
nonisolated struct LiDARMultiCameraFormatDiagnostics: Sendable {
    enum Rejection: String, CaseIterable, Sendable {
        case raster = "크기", aspect = "비율", multiCam = "동시촬영", frameRate = "30fps"
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
    private(set) var ultra = Stream()
    private(set) var depth = Stream()
    private(set) var completeCollections = 0

    /// nil is absent, zero is delivered, and positive values are AVFoundation
    /// AVCaptureOutput.DataDroppedReason raw values (1 late, 2 pool, 3 gap).
    mutating func observe(wide: Int?, ultra: Int?, depth: Int?) {
        callbacks += 1
        self.wide.observe(wide)
        self.ultra.observe(ultra)
        self.depth.observe(depth)
        if wide == 0, ultra == 0, depth == 0 { completeCollections += 1 }
    }

    var summary: String {
        "콜백\(callbacks) / 일반\(wide.summary)·초광각\(ultra.summary)·깊이\(depth.summary) / 전체묶음\(completeCollections)"
    }

    var failureDescription: String {
        if callbacks == 0 { return "동기화 콜백이 한 번도 도착하지 않았어요." }
        let missing = [("일반 영상", wide.received), ("초광각 영상", ultra.received), ("LiDAR 깊이", depth.received)]
            .filter { $0.1 == 0 }.map(\.0)
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

/// Retain the real, read-only callback buffers while waiting for the other
/// camera's nearby timestamp. RGB and LiDAR remain one atomic native pair.
nonisolated private struct MultiCameraWideDepthSample: @unchecked Sendable {
    let image: CMSampleBuffer
    let imageTimestamp: CMTime
    let depth: AVDepthData
    let depthTimestamp: CMTime
}

nonisolated private struct MultiCameraUltraSample: @unchecked Sendable {
    let image: CMSampleBuffer
    let timestamp: CMTime
}

/// Owns every camera input in ONE AVFoundation session. ARKit must be paused
/// before starting this owner. Only calibrated, synchronized triples leave the
/// callback queue; neither preview nor measurement pairs a new frame with an
/// old depth map or an old ultra-wide image.
nonisolated final class LiDARMultiCameraCapture: NSObject, @unchecked Sendable {
    let session = AVCaptureMultiCamSession()
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
        var wideToUltra: simd_float4x3?
        var synchronizerID: ObjectIdentifier?
        var startup: MultiCameraFirstFrameGate<MultiCameraControlDevice>?
        var startedAt = 0.0
        var lastPacketAt = 0.0
        var lastTimestamp: TimeInterval?
        var lastRejection: String?
        var delivery = LiDARMultiCameraDeliveryDiagnostics()
        var pending: MultiCameraTimestampJoin<MultiCameraWideDepthSample, MultiCameraUltraSample>?
    }
    private let state = Mutex(RunState())
    private let sessionQueue = DispatchQueue(label: "com.dobby.lidar.multicam.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "com.dobby.lidar.multicam.frames", qos: .userInteractive)
    private let wideOutput = AVCaptureVideoDataOutput()
    private let ultraOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()

    // The following properties belong exclusively to sessionQueue.
    private var configuredTicket: Ticket?
    private var wideInput: AVCaptureDeviceInput?
    private var ultraInput: AVCaptureDeviceInput?
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var notifications: [NSObjectProtocol] = []
    private var pressureObservations: [NSKeyValueObservation] = []
    private var watchdog: DispatchSourceTimer?
    private var reducedFrameRate = false
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
            $0.pending = .init(sessionID: sessionID, maxSkew: MultiCameraFrame.maximumSynchronizationSkew)
            frames.begin(sessionID: sessionID)
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
                logger.error("MultiCam startup failed: \(failure.localizedDescription, privacy: .public)")
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
        var referenceFieldOfView: Float = 0
    }

    private func configure(ticket: Ticket) throws -> AVCaptureDevice {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw LiDARMultiCameraCaptureError.permission
        }
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw LiDARMultiCameraCaptureError.unsupported
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInLiDARDepthCamera, .builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back)
        guard let lidar = discovery.devices.first(where: { $0.deviceType == .builtInLiDARDepthCamera }),
              let ultra = discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera }),
              let physicalWide = lidar.constituentDevices.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera && !$0.isVirtualDevice }) else {
            throw LiDARMultiCameraCaptureError.unavailableDevices
        }
        // Some OS releases list the virtual LiDAR device; others expose its
        // physical wide constituent in the supported camera set. canAddInput
        // below is still the final authority for the actual LiDAR input pair.
        guard discovery.supportedMultiCamDeviceSets.contains(where: { devices in
            devices.contains(where: { $0.uniqueID == ultra.uniqueID })
                && devices.contains(where: { $0.uniqueID == lidar.uniqueID || $0.uniqueID == physicalWide.uniqueID })
        }) else { throw LiDARMultiCameraCaptureError.unsupportedCombination }
        guard let data = AVCaptureDevice.extrinsicMatrix(from: physicalWide, to: ultra),
              data.count == MemoryLayout<simd_float4x3>.size else {
            throw LiDARMultiCameraCaptureError.invalidCalibration
        }
        var extrinsics = data.withUnsafeBytes { $0.loadUnaligned(as: simd_float4x3.self) }
        extrinsics.columns.3 /= 1_000 // Factory baseline is millimetres; depth is metres.
        guard (0..<4).allSatisfy({ index in
            let column = extrinsics[index]
            return column.x.isFinite && column.y.isFinite && column.z.isFinite
        }) else { throw LiDARMultiCameraCaptureError.invalidCalibration }

        let wideFormats = try formatChoices(for: lidar, minimumWidth: 1_280, preferredWidth: 1_920,
                                           requiresDepth: true, nativeReferenceDevice: physicalWide)
        let ultraFormats = try formatChoices(for: ultra, minimumWidth: 960, preferredWidth: 960, requiresDepth: false)
        guard !wideFormats.isEmpty else {
            throw LiDARMultiCameraCaptureError.noEligibleFormats(camera: "일반·LiDAR", diagnostics: "유효 0")
        }
        guard !ultraFormats.isEmpty else {
            throw LiDARMultiCameraCaptureError.noEligibleFormats(camera: "초광각", diagnostics: "유효 0")
        }
        let lidarInput = try AVCaptureDeviceInput(device: lidar)
        let peripheralInput = try AVCaptureDeviceInput(device: ultra)
        configuredTicket = ticket
        session.beginConfiguration()
        var configurationOpen = true
        defer { if configurationOpen { session.commitConfiguration() } }
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        guard session.canAddInput(lidarInput) else { throw LiDARMultiCameraCaptureError.connection }
        session.addInputWithNoConnections(lidarInput)
        guard session.canAddInput(peripheralInput) else { throw LiDARMultiCameraCaptureError.unsupportedCombination }
        session.addInputWithNoConnections(peripheralInput)
        wideInput = lidarInput
        ultraInput = peripheralInput
        guard let widePort = lidarInput.ports.first(where: { $0.mediaType == .video }),
              let depthPort = lidarInput.ports.first(where: { $0.mediaType == .depthData }),
              let ultraPort = peripheralInput.ports.first(where: { $0.mediaType == .video }) else {
            throw LiDARMultiCameraCaptureError.connection
        }
        wideOutput.alwaysDiscardsLateVideoFrames = true
        ultraOutput.alwaysDiscardsLateVideoFrames = true
        wideOutput.automaticallyConfiguresOutputBufferDimensions = false
        ultraOutput.automaticallyConfiguresOutputBufferDimensions = false
        wideOutput.deliversPreviewSizedOutputBuffers = false
        ultraOutput.deliversPreviewSizedOutputBuffers = false
        depthOutput.alwaysDiscardsLateDepthData = true
        depthOutput.isFilteringEnabled = false
        for output: AVCaptureOutput in [wideOutput, ultraOutput, depthOutput] {
            guard session.canAddOutput(output) else { throw LiDARMultiCameraCaptureError.connection }
            session.addOutputWithNoConnections(output)
        }
        let wideConnection = try connect(widePort, to: wideOutput)
        let ultraConnection = try connect(ultraPort, to: ultraOutput)
        _ = try connect(depthPort, to: depthOutput)
        for connection in [wideConnection, ultraConnection] {
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        }

        var selectedPair: (wide: FormatChoice, ultra: FormatChoice)?
        var checkedCalibratedPairBudget = false
        var lastPixelFormatFailure: LiDARMultiCameraCaptureError?
        var pixelFormatRejectedPairs = 0
        var missingIntrinsicsPairs = 0
        for wide in wideFormats {
            for peripheral in ultraFormats {
                guard isCurrent(ticket) else { throw CancellationError() }
                try select(wide, on: lidar, distortionCorrection: false)
                try select(peripheral, on: ultra, distortionCorrection: true)
                // Adding the input resets this override; apply it afterwards.
                lidarInput.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 30)
                peripheralInput.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 30)
                var pairPixelFormatsSupported = true
                for output in [wideOutput, ultraOutput] {
                    let supported = output.availableVideoPixelFormatTypes
                    guard let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                             kCVPixelFormatType_32BGRA].first(where: supported.contains) else {
                        let camera = output === wideOutput ? "일반·LiDAR" : "초광각"
                        let codes = supported.prefix(8).map { String(format: "0x%08X", $0) }.joined(separator: ",")
                        lastPixelFormatFailure = .unsupportedPixelFormats(camera: camera,
                            supported: codes.isEmpty ? "없음" : codes)
                        pairPixelFormatsSupported = false
                        break
                    }
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
                }
                guard pairPixelFormatsSupported else { pixelFormatRejectedPairs += 1; continue }
                // Probe capabilities and costs on the committed active graph,
                // not the previous format while a transaction is still open.
                session.commitConfiguration()
                configurationOpen = false
                // Paired LiDAR depth already carries the wide RGB reference K
                // (Apple's synchronized LiDAR sample uses that calibration).
                // A missing optional video attachment must not reject it.
                // When delivered, the packet still checks it against depth K.
                wideConnection.isCameraIntrinsicMatrixDeliveryEnabled =
                    wideConnection.isCameraIntrinsicMatrixDeliverySupported
                // The display-only ultra-wide has no corresponding depth
                // calibration: its own per-frame K remains mandatory.
                guard ultraConnection.isCameraIntrinsicMatrixDeliverySupported else {
                    // This capability depends on the active format. The next
                    // real ultra-wide format may deliver K even if this one
                    // cannot; do not abandon the entire camera pair yet.
                    missingIntrinsicsPairs += 1
                    session.beginConfiguration()
                    configurationOpen = true
                    continue
                }
                ultraConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
                checkedCalibratedPairBudget = true
                if LiDARMultiCameraFormatPolicy.isAffordable(hardware: session.hardwareCost,
                                                             pressure: session.systemPressureCost) {
                    selectedPair = (wide, peripheral)
                    break
                }
                session.beginConfiguration()
                configurationOpen = true
            }
            if selectedPair != nil { break }
        }
        guard let selectedPair else {
            logger.error("Camera pair rejection: pixelFormats=\(pixelFormatRejectedPairs, privacy: .public) ultraIntrinsics=\(missingIntrinsicsPairs, privacy: .public) checkedBudget=\(checkedCalibratedPairBudget, privacy: .public)")
            if checkedCalibratedPairBudget { throw LiDARMultiCameraCaptureError.budget }
            if missingIntrinsicsPairs > 0 { throw LiDARMultiCameraCaptureError.missingUltraWideIntrinsics }
            if let lastPixelFormatFailure { throw lastPixelFormatFailure }
            throw LiDARMultiCameraCaptureError.unsupportedFormats
        }
        #if DEBUG
        let wideSize = CMVideoFormatDescriptionGetDimensions(selectedPair.wide.format.formatDescription)
        let ultraSize = CMVideoFormatDescriptionGetDimensions(selectedPair.ultra.format.formatDescription)
        let depthSize = selectedPair.wide.depth.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
        logger.info("Selected wide=\(wideSize.width, privacy: .public)x\(wideSize.height, privacy: .public) fov=\(selectedPair.wide.fieldOfView, privacy: .public) requiredFov=\(selectedPair.wide.referenceFieldOfView, privacy: .public) ultra=\(ultraSize.width, privacy: .public)x\(ultraSize.height, privacy: .public) correctedFov=\(selectedPair.ultra.fieldOfView, privacy: .public) depth=\(depthSize?.width ?? 0, privacy: .public)x\(depthSize?.height ?? 0, privacy: .public) fps=30 hardwareCost=\(self.session.hardwareCost, privacy: .public) pressureCost=\(self.session.systemPressureCost, privacy: .public)")
        #else
        _ = selectedPair
        #endif
        state.withLock {
            guard $0.ticket == ticket else { return }
            $0.wideToUltra = extrinsics
        }
        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [wideOutput, depthOutput, ultraOutput])
        state.withLock {
            guard $0.ticket == ticket else { return }
            $0.synchronizerID = ObjectIdentifier(synchronizer)
        }
        synchronizer.setDelegate(self, queue: outputQueue)
        self.synchronizer = synchronizer
        return lidar
    }

    private func formatChoices(for device: AVCaptureDevice, minimumWidth: Int,
                               preferredWidth: Int, requiresDepth: Bool,
                               nativeReferenceDevice: AVCaptureDevice? = nil) throws -> [FormatChoice] {
        // Find the widest full-aspect source BEFORE applying our resolution /
        // bandwidth ceiling. A larger or lower-resolution full-sensor format
        // may reveal that an otherwise suitable 4:3 format is actually cropped.
        let camera = requiresDepth ? "일반·LiDAR" : "초광각"
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
            guard !requiresDepth || LiDARMultiCameraFormatPolicy.isFullAspect(width: Int(size.width), height: Int(size.height)) else {
                diagnostics.reject(.aspect); return nil
            }
            guard format.isMultiCamSupported else { diagnostics.reject(.multiCam); return nil }
            guard supports(30, format: format) else { diagnostics.reject(.frameRate); return nil }
            guard !requiresDepth || depth != nil else { diagnostics.reject(.depth); return nil }
            guard format.supportedColorSpaces.contains(.sRGB) else { diagnostics.reject(.color); return nil }
            let corrected = format.geometricDistortionCorrectedVideoFieldOfView
            let fieldOfView = !requiresDepth && corrected > 0 ? corrected : format.videoFieldOfView
            guard fieldOfView.isFinite, fieldOfView > 0, fieldOfView < 180 else {
                diagnostics.reject(.fieldOfView); return nil
            }
            return FormatChoice(format: format, depth: depth, width: Int(size.width), fieldOfView: fieldOfView)
        }
        let referenceValues: [Float]
        if requiresDepth {
            // A MultiCam-only reference could still call a uniformly cropped
            // set "1x". Use the full native LiDAR/physical wide sensor BEFORE
            // filtering MultiCam, frame rate, depth or bandwidth capabilities.
            referenceValues = ([device] + [nativeReferenceDevice].compactMap({ $0 })).flatMap(\.formats).compactMap { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard LiDARMultiCameraFormatPolicy.isFullAspect(width: Int(size.width), height: Int(size.height)) else { return nil }
                return format.videoFieldOfView
            }
        } else {
            referenceValues = compatible.map(\.fieldOfView)
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
                nativeReference: widest, requiresDepth: requiresDepth)
        }
        diagnostics.reject(.fieldOfView, count: resolutionCandidates.count - preserving.count)
        diagnostics.eligible = preserving.count
        logger.info("\(camera, privacy: .public) format scan: \(diagnostics.summary, privacy: .public)")
        if requiresDepth, preserving.isEmpty,
           let available = resolutionCandidates.map(\.fieldOfView).max() {
            #if DEBUG
            logger.error("Full native 1x rejected: requiredFov=\(widest, privacy: .public) availableMultiCamFov=\(available, privacy: .public) tolerance=\(LiDARMultiCameraFormatPolicy.maximumFieldOfViewLossDegrees, privacy: .public)")
            #endif
            throw LiDARMultiCameraCaptureError.narrowedFieldOfView(expected: widest, available: available,
                diagnostics: diagnostics.summary)
        }
        guard !preserving.isEmpty else {
            throw LiDARMultiCameraCaptureError.noEligibleFormats(camera: camera, diagnostics: diagnostics.summary)
        }
        return preserving.map {
            var choice = $0
            choice.referenceFieldOfView = widest
            return choice
        }.sorted {
            let firstPenalty = LiDARMultiCameraFormatPolicy.preferredWidthPenalty(width: $0.width, preferred: preferredWidth)
            let secondPenalty = LiDARMultiCameraFormatPolicy.preferredWidthPenalty(width: $1.width, preferred: preferredWidth)
            if requiresDepth {
                // Every surviving wide candidate already preserves native 1x.
                // Prefer 1920/1280 before a 4032px fallback, not a negligible
                // rounding difference in otherwise equivalent FOV metadata.
                if firstPenalty != secondPenalty { return firstPenalty < secondPenalty }
                return $0.fieldOfView > $1.fieldOfView
            }
            if $0.fieldOfView != $1.fieldOfView { return $0.fieldOfView > $1.fieldOfView }
            return firstPenalty < secondPenalty
        }
    }

    private func supports(_ fps: Double, format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }
    }

    private func select(_ choice: FormatChoice, on device: AVCaptureDevice, distortionCorrection: Bool) throws {
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
        let camera = device.deviceType == .builtInLiDARDepthCamera ? "일반·LiDAR" : "초광각"
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
        if distortionCorrection && !device.isGeometricDistortionCorrectionSupported {
            throw LiDARMultiCameraCaptureError.invalidCalibration
        }
        if device.isGeometricDistortionCorrectionSupported {
            // Wide RGB AND depth are rectified together by MultiCameraFrame.
            device.isGeometricDistortionCorrectionEnabled = distortionCorrection
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
        for source in [device] + [ultraInput?.device].compactMap({ $0 }) {
            pressureObservations.append(source.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                let level = device.systemPressureState.level
                self?.sessionQueue.async { [weak self] in self?.handlePressure(level, ticket: ticket) }
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
        let outputs: [(String, AVCaptureOutput)] = [("일반", wideOutput), ("초광각", ultraOutput), ("깊이", depthOutput)]
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

    private func handlePressure(_ level: AVCaptureDevice.SystemPressureState.Level, ticket: Ticket) {
        guard configuredTicket == ticket, isCurrent(ticket) else { return }
        if level == .critical || level == .shutdown {
            fail(ticket, message: "기기 온도가 높아 카메라 촬영을 중단했어요. 기기를 식힌 뒤 다시 시도해 주세요.")
        } else if level == .serious, !reducedFrameRate,
                  let wideInput, let ultraInput {
            let inputs = [wideInput, ultraInput]
            guard inputs.allSatisfy({ supports(15, format: $0.device.activeFormat) }),
                  let depth = wideInput.device.activeDepthDataFormat, supports(15, format: depth) else {
                fail(ticket, message: "기기 온도가 높아 두 카메라의 동기화를 유지할 수 없어요. 기기를 식힌 뒤 다시 시도해 주세요.")
                return
            }
            do {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                for input in inputs {
                    try input.device.lockForConfiguration()
                    input.device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
                    input.device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
                    if input === wideInput {
                        input.device.activeDepthDataMinFrameDuration = CMTime(value: 1, timescale: 15)
                    }
                    input.device.unlockForConfiguration()
                    input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 15)
                }
                reducedFrameRate = true
                #if DEBUG
                logger.info("Thermal pressure: paired wide/ultra/depth reduced to 15fps")
                #endif
            } catch {
                fail(ticket, message: "카메라의 기기 온도 대응 설정을 적용하지 못했어요. 기기를 식힌 뒤 다시 시도해 주세요.")
            }
        }
    }

    private func fail(_ ticket: Ticket, message: String) {
        let callback = state.withLock { current -> (@Sendable (UUID, String) -> Void)? in
            guard current.ticket == ticket else { return nil }
            let startupFailed = current.startup?.fail(MultiCameraStartupFailure(message: message)) ?? true
            let callback = startupFailed ? nil : current.onFailure
            current = RunState()
            frames.clear(sessionID: ticket.sessionID)
            return callback
        }
        callback?(ticket.sessionID, message)
        sessionQueue.async { [self] in
            if configuredTicket == ticket { tearDown() }
        }
    }

    private func tearDown() {
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
        ultraInput = nil
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
    let session: AVCaptureMultiCamSession
    func stop() { if session.isRunning { session.stopRunning() } }
}

extension LiDARMultiCameraCapture: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        // Identity protects callbacks that were queued before a restart, even
        // if the caller happens to reuse the same public session UUID.
        let wide = synchronizedDataCollection.synchronizedData(for: wideOutput) as? AVCaptureSynchronizedSampleBufferData
        let ultra = synchronizedDataCollection.synchronizedData(for: ultraOutput) as? AVCaptureSynchronizedSampleBufferData
        let depth = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData
        let request = state.withLock { current -> (Ticket, simd_float4x3, MultiCameraWideDepthSample, MultiCameraUltraSample)? in
            guard current.synchronizerID == ObjectIdentifier(synchronizer),
                  let ticket = current.ticket, let extrinsics = current.wideToUltra else { return nil }
            current.delivery.observe(wide: wide.map { $0.sampleBufferWasDropped ? $0.droppedReason.rawValue : 0 },
                                     ultra: ultra.map { $0.sampleBufferWasDropped ? $0.droppedReason.rawValue : 0 },
                                     depth: depth.map { $0.depthDataWasDropped ? $0.droppedReason.rawValue : 0 })
            // The synchronizer may deliver the secondary camera in a separate
            // collection. Keep the calibrated wide/depth pair atomic, then
            // join only a nearby ultra frame on the SAME session clock.
            typealias Join = MultiCameraTimestampJoin<MultiCameraWideDepthSample, MultiCameraUltraSample>
            var primary: Join.PrimaryEntry?
            if let wide, let depth, !wide.sampleBufferWasDropped, !depth.depthDataWasDropped {
                let times = (wide.timestamp.seconds, depth.timestamp.seconds)
                primary = .init(value: .init(image: wide.sampleBuffer, imageTimestamp: wide.timestamp,
                    depth: depth.depthData, depthTimestamp: depth.timestamp),
                    timestamp: min(times.0, times.1), endTimestamp: max(times.0, times.1))
            }
            var secondary: Join.SecondaryEntry?
            if let ultra, !ultra.sampleBufferWasDropped {
                secondary = .init(value: .init(image: ultra.sampleBuffer, timestamp: ultra.timestamp),
                    timestamp: ultra.timestamp.seconds)
            }
            guard let match = current.pending?.insert(primary: primary, secondary: secondary,
                                                       sessionID: ticket.sessionID) else { return nil }
            return (ticket, extrinsics, match.primary, match.secondary)
        }
        guard let (ticket, extrinsics, wideDepth, ultraSample) = request else { return }
        do {
            let frame = try MultiCameraFrame.make(sessionID: ticket.sessionID,
                wide: wideDepth.image, wideTimestamp: wideDepth.imageTimestamp,
                ultraWide: ultraSample.image, ultraWideTimestamp: ultraSample.timestamp,
                depth: wideDepth.depth, depthTimestamp: wideDepth.depthTimestamp, wideToUltra: extrinsics)
            let callback = state.withLock { current -> (@Sendable (MultiCameraFrame) -> Void)? in
                guard current.ticket == ticket,
                      current.lastTimestamp == nil || frame.timestamp > current.lastTimestamp! else { return nil }
                current.lastTimestamp = frame.timestamp
                current.lastPacketAt = ProcessInfo.processInfo.systemUptime
                current.lastRejection = nil
                frames.publish(frame)
                if let device = current.device {
                    current.startup?.acceptFirstFrame(MultiCameraControlDevice(device: device))
                }
                return current.onFrame
            }
            guard let callback else { return }
            callback(frame)
        } catch {
            state.withLock {
                guard $0.ticket == ticket else { return }
                $0.lastRejection = error.localizedDescription
            }
        }
    }
}

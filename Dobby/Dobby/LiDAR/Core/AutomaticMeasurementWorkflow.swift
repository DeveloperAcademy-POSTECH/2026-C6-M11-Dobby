import Foundation

/// Implemented by the camera owner. The workflow never creates a camera session.
@MainActor
protocol CaptureSnapshotProviding {
    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot
}

nonisolated enum AutomaticMeasurementPhase: String, Codable, Sendable {
    case idle, capturing, detectingLandmarks, measuring, completed, failed, cancelled
}

nonisolated enum AutomaticMeasurementStage: String, Codable, Sendable {
    case capture, landmarks, measurement
}

nonisolated enum AutomaticMeasurementFailureCode: String, Codable, Sendable {
    case providerFailure, frameMismatch, invalidProvenance, timedOut, interrupted, cancelled, invalidConfiguration, busy
}

/// An adapter can classify its own errors without making Core import ARKit or
/// matching localized strings. The workflow still supplies the active stage.
nonisolated protocol AutomaticMeasurementFailureClassifying: Error {
    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode { get }
}

nonisolated struct AutomaticMeasurementWorkflowFailure: Error, LocalizedError, Codable, Sendable, Equatable,
    AutomaticMeasurementFailureClassifying {
    var stage: AutomaticMeasurementStage
    var code: AutomaticMeasurementFailureCode
    var message: String
    var errorDescription: String? { message }
    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode { code }
}

nonisolated struct AutomaticMeasurementTimings: Codable, Sendable, Equatable {
    /// Nil means the stage was never entered. For a failed/cancelled stage its
    /// duration is time spent before termination, not a completed-stage latency.
    var captureSeconds: TimeInterval?
    var landmarksSeconds: TimeInterval?
    var measurementSeconds: TimeInterval?
    var totalSeconds: TimeInterval
}

nonisolated struct AutomaticMeasurementOutput: Codable, Sendable {
    var runID: UUID
    var snapshot: CaptureSnapshot
    var landmarks: GarmentLandmarkSet
    var result: GarmentMeasurementResult
    var definitions: [MeasurementDefinition]
    var options: MeasurementOptions
    var timings: AutomaticMeasurementTimings
    var startedAt: Date
    var finishedAt: Date
}

nonisolated enum AutomaticMeasurementTerminalStatus: String, Codable, Sendable {
    case completed, failed, cancelled
}

nonisolated struct AutomaticMeasurementTerminalEvent: Sendable {
    var runID: UUID
    var status: AutomaticMeasurementTerminalStatus
    var stage: AutomaticMeasurementStage
    var failure: AutomaticMeasurementWorkflowFailure?
    var snapshot: CaptureSnapshot?
    var result: GarmentMeasurementResult?
    var timings: AutomaticMeasurementTimings
    var startedAt: Date
    var finishedAt: Date
}

/// A cancellable, bounded capture -> frozen-image inference -> measurement flow.
/// Cancellation/timeout completes the caller independently of a provider that
/// ignores cancellation. Such a provider may continue internally, so at most two
/// physical workers (current plus draining) are allowed; further runs fail busy.
@MainActor
final class AutomaticMeasurementWorkflow {
    static let maximumInFlightWorkers = 2

    private(set) var phase: AutomaticMeasurementPhase = .idle
    private(set) var currentRunID: UUID?
    private(set) var lastResult: AutomaticMeasurementOutput?
    private(set) var lastFailure: AutomaticMeasurementWorkflowFailure?
    var onPhaseChange: ((AutomaticMeasurementPhase) -> Void)?
    var onTerminal: ((AutomaticMeasurementTerminalEvent) -> Void)?
    /// Presentation may freeze this exact captured RGB while inference runs.
    /// This is not a landmark or measurement result.
    var onSnapshot: ((CaptureSnapshot) -> Void)?
    var inFlightWorkerCount: Int { workers.count }

    private let camera: any CaptureSnapshotProviding
    private let landmarks: any GarmentLandmarkProviding
    private let definitions: [MeasurementDefinition]
    private let options: MeasurementOptions
    private let timeoutSeconds: TimeInterval
    private let expectedLandmarkOrigin: LandmarkOrigin?
    private let pipeline = MeasurementPipeline()
    private var activeRun: AutomaticWorkflowRun?
    private var workers: [UUID: Task<Void, Never>] = [:]

    init(camera: any CaptureSnapshotProviding, landmarks: any GarmentLandmarkProviding,
         definitions: [MeasurementDefinition], options: MeasurementOptions = .init(),
         timeoutSeconds: TimeInterval = 15,
         expectedLandmarkOrigin: LandmarkOrigin? = nil,
         onPhaseChange: ((AutomaticMeasurementPhase) -> Void)? = nil,
         onTerminal: ((AutomaticMeasurementTerminalEvent) -> Void)? = nil,
         onSnapshot: ((CaptureSnapshot) -> Void)? = nil) {
        self.camera = camera
        self.landmarks = landmarks
        self.definitions = definitions
        self.options = options
        self.timeoutSeconds = timeoutSeconds
        self.expectedLandmarkOrigin = expectedLandmarkOrigin
        self.onPhaseChange = onPhaseChange
        self.onTerminal = onTerminal
        self.onSnapshot = onSnapshot
    }

    func run(orientation: ImageOrientation) async throws -> AutomaticMeasurementOutput {
        cancel()
        let run = AutomaticWorkflowRun()
        activeRun = run
        currentRunID = run.id
        lastResult = nil
        lastFailure = nil
        publish(.capturing)

        // Give promptly cancelled providers an opportunity to leave before
        // deciding that two genuinely draining workers prevent another retake.
        if workers.count >= Self.maximumInFlightWorkers { await Task.yield() }

        let output: AutomaticMeasurementOutput = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.attach(continuation)
                guard isActive(run) else { return }
                if Task.isCancelled {
                    finish(run, failure: cancellation(stage: run.stage))
                } else if !timeoutSeconds.isFinite || timeoutSeconds <= 0 || timeoutSeconds > 300 {
                    finish(run, failure: .init(stage: .capture, code: .invalidConfiguration,
                        message: "자동 측정 제한 시간은 0초 초과 300초 이하여야 합니다."))
                } else if !(landmarks is any GarmentMeasurementDefinitionProviding)
                    && !Self.validDefinitions(definitions) {
                    finish(run, failure: .init(stage: .capture, code: .invalidConfiguration,
                        message: "측정 항목은 1~100개이며 각 항목에 비어 있지 않은 고유 ID가 있어야 합니다."))
                } else if workers.count >= Self.maximumInFlightWorkers {
                    finish(run, failure: .init(stage: .capture, code: .busy,
                        message: "이전 카메라·모델 작업이 종료되는 중입니다. 잠시 후 다시 촬영해 주세요."))
                } else {
                    start(run, orientation: orientation)
                }
            }
        } onCancel: { [weak self] in
            // Set the flag synchronously; the actor hop below must not leave a
            // window in which a cancelled caller receives a late success.
            run.cancellationFlag.request()
            Task { @MainActor [weak self] in self?.cancel(runID: run.id) }
        }
        if Task.isCancelled { throw cancellation(stage: run.stage) }
        return output
    }

    func cancel() {
        guard let run = activeRun else { return }
        finish(run, failure: cancellation(stage: run.stage))
    }

    private func cancel(runID: UUID) {
        guard let run = activeRun, run.id == runID else { return }
        finish(run, failure: cancellation(stage: run.stage))
    }

    private func cancellation(stage: AutomaticMeasurementStage) -> AutomaticMeasurementWorkflowFailure {
        .init(stage: stage, code: .cancelled, message: "자동 측정을 취소했습니다.")
    }

    private func isActive(_ run: AutomaticWorkflowRun) -> Bool {
        activeRun === run && run.completion == nil
    }

    private func canContinue(_ run: AutomaticWorkflowRun) -> Bool {
        guard isActive(run) else { return false }
        if run.cancellationFlag.isRequested {
            finish(run, failure: cancellation(stage: run.stage))
            return false
        }
        return true
    }

    private func start(_ run: AutomaticWorkflowRun, orientation: ImageOrientation) {
        let camera = camera, provider = landmarks, pipeline = pipeline
        let definitions = definitions, options = options
        let expectedOrigin = expectedLandmarkOrigin
        workers[run.id] = Task { @MainActor [weak self] in
            defer { self?.workers.removeValue(forKey: run.id) }
            guard !Task.isCancelled, self?.canContinue(run) == true else { return }
            do {
                let snapshot = try await camera.capture(orientation: orientation)
                guard !Task.isCancelled, self?.canContinue(run) == true else { return }
                run.snapshot = snapshot
                self?.onSnapshot?(snapshot)
                guard !Task.isCancelled, self?.canContinue(run) == true else { return }
                self?.begin(.landmarks, run: run, phase: .detectingLandmarks)
                guard !Task.isCancelled, self?.canContinue(run) == true else { return }
                let points = try await pipeline.detectLandmarks(snapshot: snapshot, provider: provider)
                guard !Task.isCancelled, self?.canContinue(run) == true else { return }
                guard points.sessionID == snapshot.frame.sessionID, points.frameID == snapshot.frame.frameID else {
                    self?.finish(run, failure: .init(stage: .landmarks, code: .frameMismatch,
                        message: "의류 모델의 측정점이 촬영한 사진과 다른 프레임에 속합니다."))
                    return
                }
                if let expectedOrigin {
                    let sourceMatches: Bool
                    switch expectedOrigin {
                    case .model: sourceMatches = snapshot.frame.source != .synthetic
                    case .synthetic: sourceMatches = snapshot.frame.source == .synthetic
                    case .manual: sourceMatches = true
                    }
                    let hasModelVersion = !(points.modelVersion?
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    guard points.origin == expectedOrigin, sourceMatches,
                          expectedOrigin != .model || hasModelVersion else {
                        self?.finish(run, failure: .init(stage: .landmarks, code: .invalidProvenance,
                            message: "측정점의 출처·모델 버전 또는 사진 출처가 자동 측정 계약과 일치하지 않습니다."))
                        return
                    }
                }
                let resolvedDefinitions: [MeasurementDefinition]
                if let resolver = provider as? any GarmentMeasurementDefinitionProviding {
                    resolvedDefinitions = try resolver.measurementDefinitions(for: points)
                } else {
                    resolvedDefinitions = definitions
                }
                guard Self.validDefinitions(resolvedDefinitions) else {
                    self?.finish(run, failure: .init(stage: .landmarks, code: .invalidConfiguration,
                        message: "인식한 옷의 측정 항목을 확인하지 못했습니다. 다시 촬영해 주세요."))
                    return
                }
                self?.begin(.measurement, run: run, phase: .measuring)
                guard !Task.isCancelled, self?.canContinue(run) == true else { return }
                let result = await pipeline.measure(snapshot: snapshot, landmarks: points,
                    definitions: resolvedDefinitions, options: options)
                guard !Task.isCancelled, self?.canContinue(run) == true else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let output = AutomaticMeasurementOutput(runID: run.id, snapshot: snapshot,
                    landmarks: points, result: result, definitions: resolvedDefinitions, options: options,
                    timings: run.timings(at: now), startedAt: run.startedAt, finishedAt: .now)
                self?.finish(run, output: output)
            } catch {
                guard self?.canContinue(run) == true else { return }
                let cancelled = error is CancellationError || Task.isCancelled
                let classified = (error as? any AutomaticMeasurementFailureClassifying)?.automaticMeasurementFailureCode
                self?.finish(run, failure: .init(stage: run.stage,
                    code: cancelled ? .cancelled : (classified ?? .providerFailure),
                    message: cancelled ? "자동 측정을 취소했습니다." : error.localizedDescription))
            }
        }
        let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
        run.timeoutTask = Task { @MainActor [weak self, weak run] in
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            guard let self, let run, isActive(run) else { return }
            finish(run, failure: .init(stage: run.stage, code: .timedOut,
                message: "자동 측정 제한 시간을 초과했습니다. 카메라와 모델 상태를 확인해 주세요."))
        }
    }

    private func begin(_ stage: AutomaticMeasurementStage, run: AutomaticWorkflowRun,
                       phase: AutomaticMeasurementPhase) {
        guard isActive(run) else { return }
        run.begin(stage, at: ProcessInfo.processInfo.systemUptime)
        publish(phase)
    }

    private func finish(_ run: AutomaticWorkflowRun, failure: AutomaticMeasurementWorkflowFailure) {
        guard isActive(run) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let event = AutomaticMeasurementTerminalEvent(runID: run.id,
            status: failure.code == .cancelled ? .cancelled : .failed,
            stage: failure.stage, failure: failure, snapshot: run.snapshot, result: nil,
            timings: run.timings(at: now), startedAt: run.startedAt, finishedAt: .now)
        workers[run.id]?.cancel()
        run.timeoutTask?.cancel()
        run.timeoutTask = nil
        activeRun = nil
        currentRunID = nil
        lastFailure = failure
        publish(failure.code == .cancelled ? .cancelled : .failed)
        run.complete(.failure(failure))
        onTerminal?(event)
    }

    private func finish(_ run: AutomaticWorkflowRun, output: AutomaticMeasurementOutput) {
        guard canContinue(run) else { return }
        run.timeoutTask?.cancel()
        run.timeoutTask = nil
        activeRun = nil
        currentRunID = nil
        lastResult = output
        lastFailure = nil
        publish(.completed)
        run.complete(.success(output))
        onTerminal?(.init(runID: run.id, status: .completed, stage: .measurement,
            failure: nil, snapshot: output.snapshot, result: output.result,
            timings: output.timings, startedAt: output.startedAt, finishedAt: output.finishedAt))
    }

    private func publish(_ phase: AutomaticMeasurementPhase) {
        self.phase = phase
        onPhaseChange?(phase)
    }

    private static func validDefinitions(_ definitions: [MeasurementDefinition]) -> Bool {
        !definitions.isEmpty && definitions.count <= 100
            && definitions.allSatisfy { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && Set(definitions.map(\.id)).count == definitions.count
    }
}

@MainActor
private final class AutomaticWorkflowRun {
    let id = UUID()
    let cancellationFlag = AutomaticWorkflowCancellationFlag()
    let startedAt = Date()
    let startedUptime = ProcessInfo.processInfo.systemUptime
    private(set) var stage: AutomaticMeasurementStage = .capture
    private var stageStartedAt: TimeInterval
    private var durations: [AutomaticMeasurementStage: TimeInterval] = [:]
    var snapshot: CaptureSnapshot?
    var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<AutomaticMeasurementOutput, Error>?
    private(set) var completion: Result<AutomaticMeasurementOutput, AutomaticMeasurementWorkflowFailure>?

    init() { stageStartedAt = startedUptime }

    func attach(_ continuation: CheckedContinuation<AutomaticMeasurementOutput, Error>) {
        if let completion { continuation.resume(with: completion.mapError { $0 as Error }) }
        else { self.continuation = continuation }
    }

    func complete(_ completion: Result<AutomaticMeasurementOutput, AutomaticMeasurementWorkflowFailure>) {
        guard self.completion == nil else { return }
        self.completion = completion
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: completion.mapError { $0 as Error })
    }

    func begin(_ stage: AutomaticMeasurementStage, at now: TimeInterval) {
        durations[self.stage] = max(0, now - stageStartedAt)
        self.stage = stage
        stageStartedAt = now
    }

    func timings(at now: TimeInterval) -> AutomaticMeasurementTimings {
        var values = durations
        values[stage] = max(0, now - stageStartedAt)
        return .init(captureSeconds: values[.capture], landmarksSeconds: values[.landmarks],
                     measurementSeconds: values[.measurement], totalSeconds: max(0, now - startedUptime))
    }
}

/// Only this tiny flag crosses the cancellation handler's nonisolated boundary.
/// All workflow state, continuations and user callbacks stay on the main actor.
private nonisolated final class AutomaticWorkflowCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    var isRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return requested
    }
    func request() {
        lock.lock(); defer { lock.unlock() }
        requested = true
    }
}

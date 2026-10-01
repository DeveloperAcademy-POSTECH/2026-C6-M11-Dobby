import Foundation

nonisolated struct RecordedMeasurementOutput: Sendable {
    var workflowOutput: AutomaticMeasurementOutput
    /// A completed calculation remains usable if the local attempt could not be
    /// finalized. The caller decides how to present this diagnostic.
    var recordingError: String?
}

nonisolated enum RecordedMeasurementServiceError: Error, Equatable {
    case alreadyRunning
}

/// Preserves the measurement failure independently from a second storage error.
nonisolated struct RecordedMeasurementRunFailure: Error, LocalizedError,
    AutomaticMeasurementFailureClassifying {
    var workflowFailure: AutomaticMeasurementWorkflowFailure
    var recordingError: String
    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode { workflowFailure.code }
    var errorDescription: String? { workflowFailure.errorDescription }
}

/// Executes one domain use case: record an attempt, run the camera/landmark/
/// measurement workflow, then persist its terminal outcome. This service owns no
/// observable or presentation state. Keep the instance (and its workflow) alive
/// across retakes so cancellation-resistant providers remain subject to the
/// workflow's worker limit.
@MainActor
final class RecordedMeasurementService {
    private let workflow: AutomaticMeasurementWorkflow
    private let journal: MeasurementAttemptJournal
    private var activeRun: RecordedMeasurementRun?

    init(workflow: AutomaticMeasurementWorkflow, journal: MeasurementAttemptJournal) {
        self.workflow = workflow
        self.journal = journal
    }

    func run(orientation: ImageOrientation, purpose: MeasurementAttemptPurpose,
             isSynthetic: Bool, deviceContext: String? = nil,
             onPhaseChange: @escaping (AutomaticMeasurementPhase) -> Void = { _ in },
             onSnapshot: ((CaptureSnapshot) -> Void)? = nil) async throws
        -> RecordedMeasurementOutput {
        guard activeRun == nil else { throw RecordedMeasurementServiceError.alreadyRunning }
        let run = RecordedMeasurementRun()
        activeRun = run
        defer {
            if activeRun === run {
                workflow.onPhaseChange = nil
                workflow.onTerminal = nil
                workflow.onSnapshot = nil
                activeRun = nil
            }
        }
        return try await withTaskCancellationHandler {
            try requireCurrent(run)
            let attempt = try await journal.begin(purpose: purpose, isSynthetic: isSynthetic,
                deviceContext: deviceContext)
            var output: AutomaticMeasurementOutput?
            var runError: (any Error)?
            do {
                // begin crosses an actor boundary: cancellation during the write
                // must finish that attempt without starting a camera operation.
                try requireCurrent(run)
                workflow.onPhaseChange = { [weak self, weak run] phase in
                    guard let self, let run, self.activeRun === run,
                          !run.cancellation.isRequested else { return }
                    onPhaseChange(phase)
                }
                workflow.onTerminal = { [weak run] event in
                    guard let run, run.terminal == nil else { return }
                    run.terminal = event
                }
                workflow.onSnapshot = { [weak self, weak run] snapshot in
                    guard let self, let run, self.activeRun === run,
                          !run.cancellation.isRequested else { return }
                    onSnapshot?(snapshot)
                }
                output = try await workflow.run(orientation: orientation)
            } catch { runError = error }

            // A completed workflow terminal is authoritative, even if the caller
            // cancels while awaiting storage. Do not turn a completed calculation
            // into a cancellation or attempt a second terminal write.
            let terminal = run.terminal
            let failure = (runError as? AutomaticMeasurementWorkflowFailure) ?? terminal?.failure
            let stage = terminal?.stage ?? failure?.stage ?? .capture
            let outcome: MeasurementAttemptOutcome
            if let result = terminal?.status == .completed ? terminal?.result : output?.result {
                outcome = Self.outcome(for: result)
            } else if failure?.code == .cancelled { outcome = .cancelled }
            else if failure?.code == .timedOut { outcome = .timedOut }
            else if failure?.code == .interrupted { outcome = .interrupted }
            else if failure != nil { outcome = stage == .capture ? .captureFailed : .landmarkFailed }
            else if runError is CancellationError || run.cancellation.isRequested { outcome = .cancelled }
            else if stage == .capture { outcome = .captureFailed }
            else { outcome = .landmarkFailed }

            let snapshot = terminal?.snapshot ?? output?.snapshot
            let timings = terminal?.timings ?? output?.timings
            var recordingError: String?
            do {
                _ = try await journal.finish(id: attempt.id, outcome: outcome,
                    phase: Self.journalPhase(stage), sessionID: snapshot?.frame.sessionID,
                    frameID: snapshot?.frame.frameID,
                    timings: timings.map(Self.journalTimings) ?? .init(),
                    message: terminal?.status == .completed ? nil : runError?.localizedDescription,
                    finishedAt: terminal?.finishedAt ?? .now)
            } catch { recordingError = error.localizedDescription }

            try requireCurrent(run)
            if let runError {
                if let failure, let recordingError {
                    throw RecordedMeasurementRunFailure(workflowFailure: failure, recordingError: recordingError)
                }
                throw runError
            }
            // A workflow either returns output or throws. Keep the cancellation
            // guard here as a defensive fallback rather than inventing results.
            guard let output else { throw CancellationError() }
            return .init(workflowOutput: output, recordingError: recordingError)
        } onCancel: { [weak self] in
            run.cancellation.request()
            Task { @MainActor [weak self] in self?.cancel(run) }
        }
    }

    func cancel() {
        guard let run = activeRun else { return }
        cancel(run)
    }

    private func cancel(_ run: RecordedMeasurementRun) {
        guard activeRun === run else { return }
        run.cancellation.request()
        workflow.cancel()
    }

    private func requireCurrent(_ run: RecordedMeasurementRun) throws {
        guard activeRun === run, !run.cancellation.isRequested, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private static func outcome(for result: GarmentMeasurementResult) -> MeasurementAttemptOutcome {
        if result.values.allSatisfy({ $0.status == .unavailable }) { return .unavailable }
        return result.values.allSatisfy({ $0.status == .valid }) ? .success : .partial
    }

    private static func journalPhase(_ stage: AutomaticMeasurementStage) -> MeasurementAttemptPhase {
        switch stage { case .capture: .capture; case .landmarks: .landmarks; case .measurement: .measurement }
    }

    private static func journalTimings(_ timings: AutomaticMeasurementTimings) -> MeasurementAttemptTimings {
        .init(captureSeconds: timings.captureSeconds, landmarksSeconds: timings.landmarksSeconds,
              measurementSeconds: timings.measurementSeconds, totalSeconds: timings.totalSeconds)
    }
}

@MainActor
private final class RecordedMeasurementRun {
    nonisolated let cancellation = RecordedMeasurementCancellationFlag()
    var terminal: AutomaticMeasurementTerminalEvent?
}

private nonisolated final class RecordedMeasurementCancellationFlag: @unchecked Sendable {
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

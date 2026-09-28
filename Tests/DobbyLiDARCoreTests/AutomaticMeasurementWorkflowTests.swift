import Foundation
import XCTest
@testable import DobbyLiDARCore

@MainActor
final class AutomaticMeasurementWorkflowTests: XCTestCase {
    private struct Fixture {
        var snapshot: CaptureSnapshot
        var points: GarmentLandmarkSet
    }

    private func fixture() -> Fixture {
        var scene = SyntheticFixtures.scene(tilted: true)
        scene.frame.frameID = UUID()
        scene.landmarks.frameID = scene.frame.frameID
        scene.landmarks.origin = .model
        scene.landmarks.modelVersion = "test-fixture-v1"
        scene.landmarks.points[0].confidence = 0.8
        scene.landmarks.points[1].confidence = 0.9
        return .init(snapshot: .init(frame: scene.frame, imageJPEG: Data([1, 2, 3])), points: scene.landmarks)
    }

    private func eventually(_ condition: @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not complete within 3 seconds", file: file, line: line)
    }

    private func failure(_ body: () async throws -> AutomaticMeasurementOutput,
                         file: StaticString = #filePath, line: UInt = #line) async -> AutomaticMeasurementWorkflowFailure? {
        do {
            _ = try await body()
            XCTFail("Expected workflow failure", file: file, line: line)
            return nil
        } catch let failure as AutomaticMeasurementWorkflowFailure { return failure }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line); return nil }
    }

    func testFrozenSnapshotModelMetadataAndPartialResultsSurviveTheWholeWorkflow() async throws {
        let value = fixture()
        let camera = ImmediateWorkflowCamera([value.snapshot])
        let model = RecordingWorkflowModel(answers: [value.snapshot.frame.frameID: value.points])
        let definitions: [MeasurementDefinition] = [
            .testDistance, .init(id: "missing", title: "Missing", landmarkIDs: ["A", "C"])
        ]
        var options = MeasurementOptions()
        options.sampleRadius = 4
        var phases: [AutomaticMeasurementPhase] = []
        var terminal: [AutomaticMeasurementTerminalEvent] = []
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: model,
            definitions: definitions, options: options,
            onPhaseChange: { phases.append($0) }, onTerminal: { terminal.append($0) })
        let output = try await workflow.run(orientation: .right)
        XCTAssertEqual(phases, [.capturing, .detectingLandmarks, .measuring, .completed])
        XCTAssertEqual(output.snapshot.imageJPEG, value.snapshot.imageJPEG)
        XCTAssertEqual(output.snapshot.frame.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(output.result.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(output.result.source, .synthetic)
        XCTAssertEqual(output.landmarks.origin, .model)
        XCTAssertEqual(output.landmarks.modelVersion, "test-fixture-v1")
        XCTAssertEqual(output.landmarks.points.map(\.confidence), [0.8, 0.9])
        XCTAssertEqual(output.result.values.map(\.status), [.valid, .unavailable])
        XCTAssertEqual(output.result.values[1].failure, .missingLandmark)
        XCTAssertEqual(output.definitions.map(\.id), definitions.map(\.id))
        XCTAssertEqual(output.options.sampleRadius, 4)
        XCTAssertEqual(workflow.lastResult?.runID, output.runID)
        XCTAssertNil(workflow.currentRunID)
        XCTAssertNil(workflow.lastFailure)
        let observed = await model.observedSnapshots
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.imageJPEG, value.snapshot.imageJPEG)
        XCTAssertEqual(observed.first?.frame.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(camera.orientations, [.right])
        XCTAssertEqual(terminal.count, 1)
        XCTAssertEqual(terminal.first?.stage, .measurement)
        XCTAssertEqual(terminal.first?.status, .completed)
        let timings = output.timings
        for duration in [timings.captureSeconds, timings.landmarksSeconds, timings.measurementSeconds, timings.totalSeconds] {
            let actual = try XCTUnwrap(duration)
            XCTAssertTrue(actual.isFinite)
            XCTAssertGreaterThanOrEqual(actual, 0)
            XCTAssertLessThanOrEqual(actual, timings.totalSeconds + 1e-9)
        }
        XCTAssertEqual((timings.captureSeconds ?? 0) + (timings.landmarksSeconds ?? 0)
            + (timings.measurementSeconds ?? 0), timings.totalSeconds, accuracy: 1e-7)
        let decoded = try JSONDecoder().decode(AutomaticMeasurementOutput.self, from: JSONEncoder().encode(output))
        XCTAssertEqual(decoded.runID, output.runID)
        XCTAssertEqual(decoded.landmarks.modelVersion, output.landmarks.modelVersion)
    }

    func testCaptureFailureNeverCallsModelAndIdentifiesItsStage() async {
        let camera = ImmediateWorkflowCamera([], error: WorkflowTestError.capture)
        let model = RecordingWorkflowModel(answers: [:])
        var terminal: [AutomaticMeasurementTerminalEvent] = []
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: model, definitions: [.testDistance],
            onTerminal: { terminal.append($0) })
        let error = await failure { try await workflow.run(orientation: .up) }
        XCTAssertEqual(error?.stage, .capture)
        XCTAssertEqual(error?.code, .providerFailure)
        XCTAssertEqual(workflow.phase, .failed)
        XCTAssertNil(workflow.lastResult)
        let observed = await model.observedSnapshots
        XCTAssertTrue(observed.isEmpty)
        XCTAssertNil(terminal.first?.snapshot)
        XCTAssertNil(terminal.first?.timings.landmarksSeconds)
    }

    func testModelFailurePreservesCapturedSnapshotAndIdentifiesItsStage() async {
        let value = fixture()
        let model = RecordingWorkflowModel(answers: [:], error: WorkflowTestError.landmarks)
        var terminal: [AutomaticMeasurementTerminalEvent] = []
        let workflow = AutomaticMeasurementWorkflow(camera: ImmediateWorkflowCamera([value.snapshot]),
            landmarks: model, definitions: [.testDistance], onTerminal: { terminal.append($0) })
        let error = await failure { try await workflow.run(orientation: .up) }
        XCTAssertEqual(error?.stage, .landmarks)
        XCTAssertEqual(error?.code, .providerFailure)
        XCTAssertEqual(terminal.first?.snapshot?.frame.frameID, value.snapshot.frame.frameID)
        XCTAssertNil(terminal.first?.result)
        XCTAssertNil(terminal.first?.timings.measurementSeconds)
    }

    func testMismatchedFrameOrSessionIsRejectedBeforeMeasurementOrOverlayOutput() async {
        for mismatchSession in [false, true] {
            var value = fixture()
            if mismatchSession { value.points.sessionID = UUID() }
            else { value.points.frameID = UUID() }
            var phases: [AutomaticMeasurementPhase] = []
            let workflow = AutomaticMeasurementWorkflow(camera: ImmediateWorkflowCamera([value.snapshot]),
                landmarks: RecordingWorkflowModel(answers: [value.snapshot.frame.frameID: value.points]),
                definitions: [.testDistance], onPhaseChange: { phases.append($0) })
            let error = await failure { try await workflow.run(orientation: .up) }
            XCTAssertEqual(error?.code, .frameMismatch)
            XCTAssertEqual(error?.stage, .landmarks)
            XCTAssertFalse(phases.contains(.measuring))
            XCTAssertNil(workflow.lastResult)
        }
    }

    func testCancellationBeforeCaptureStartsDoesNotInvokeEitherProvider() async {
        let value = fixture()
        let camera = ImmediateWorkflowCamera([value.snapshot])
        let model = RecordingWorkflowModel(answers: [:])
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: model, definitions: [.testDistance])
        workflow.onPhaseChange = { phase in if phase == .capturing { workflow.cancel() } }
        var terminalCount = 0
        workflow.onTerminal = { _ in terminalCount += 1 }
        let error = await failure { try await workflow.run(orientation: .up) }
        XCTAssertEqual(error?.code, .cancelled)
        XCTAssertEqual(camera.calls, 0)
        XCTAssertEqual(workflow.inFlightWorkerCount, 0)
        XCTAssertEqual(terminalCount, 1)
    }

    func testLateNoncooperativeModelAAfterCompletedBDoesNotOverwriteB() async throws {
        let a = fixture(), b = fixture()
        let camera = ImmediateWorkflowCamera([a.snapshot, b.snapshot])
        let model = ControlledWorkflowModel()
        var events: [AutomaticMeasurementTerminalEvent] = []
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: model, definitions: [.testDistance],
            onTerminal: { events.append($0) })
        var aOutcome: Result<AutomaticMeasurementOutput, Error>?
        let first = Task {
            do { aOutcome = .success(try await workflow.run(orientation: .up)) }
            catch { aOutcome = .failure(error) }
        }
        await eventually { await model.pendingCount == 1 }
        var bOutput: AutomaticMeasurementOutput?
        let second = Task { bOutput = try? await workflow.run(orientation: .up) }
        await eventually { await model.pendingCount == 2 }
        await eventually { aOutcome != nil }
        if case .failure(let error) = aOutcome {
            XCTAssertEqual((error as? AutomaticMeasurementWorkflowFailure)?.code, .cancelled)
        } else { XCTFail("Superseded A must be cancelled before its provider resumes") }
        await model.resume(frameID: b.snapshot.frame.frameID, points: b.points)
        await eventually { bOutput != nil }
        let output = try XCTUnwrap(bOutput)
        XCTAssertEqual(workflow.lastResult?.runID, output.runID)
        await model.resume(frameID: a.snapshot.frame.frameID, points: a.points)
        await eventually { workflow.inFlightWorkerCount == 0 }
        XCTAssertEqual(workflow.lastResult?.snapshot.frame.frameID, b.snapshot.frame.frameID)
        XCTAssertEqual(workflow.phase, .completed)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.status), [.cancelled, .completed])
        await first.value
        await second.value
    }

    func testCallerCancellationReturnsWhileNoncooperativeModelIsStillWaiting() async {
        let value = fixture()
        let model = ControlledWorkflowModel()
        let workflow = AutomaticMeasurementWorkflow(camera: ImmediateWorkflowCamera([value.snapshot]),
            landmarks: model, definitions: [.testDistance])
        var outcome: Result<AutomaticMeasurementOutput, Error>?
        let task = Task {
            do { outcome = .success(try await workflow.run(orientation: .up)) }
            catch { outcome = .failure(error) }
        }
        await eventually { await model.pendingCount == 1 }
        task.cancel()
        await eventually { outcome != nil }
        XCTAssertEqual(workflow.phase, .cancelled)
        XCTAssertNil(workflow.lastResult)
        let pending = await model.pendingCount
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(workflow.inFlightWorkerCount, 1)
        await model.resume(frameID: value.snapshot.frame.frameID, points: value.points)
        await eventually { workflow.inFlightWorkerCount == 0 }
        await task.value
    }

    func testTimeoutReturnsWhileNoncooperativeCaptureIsStillWaiting() async {
        let value = fixture()
        let camera = ControlledWorkflowCamera()
        let model = RecordingWorkflowModel(answers: [value.snapshot.frame.frameID: value.points])
        var events: [AutomaticMeasurementTerminalEvent] = []
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: model, definitions: [.testDistance],
            timeoutSeconds: 0.03, onTerminal: { events.append($0) })
        let error = await failure { try await workflow.run(orientation: .up) }
        XCTAssertEqual(error?.code, .timedOut)
        XCTAssertEqual(error?.stage, .capture)
        XCTAssertTrue(camera.isPending)
        camera.resume(value.snapshot)
        await eventually { workflow.inFlightWorkerCount == 0 }
        let observed = await model.observedSnapshots
        XCTAssertTrue(observed.isEmpty)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(workflow.lastResult)
        XCTAssertEqual(workflow.phase, .failed)
    }

    func testModelTimeoutHasPartialStageTimingAndRejectsLatePoints() async {
        let value = fixture()
        let model = ControlledWorkflowModel()
        var events: [AutomaticMeasurementTerminalEvent] = []
        let workflow = AutomaticMeasurementWorkflow(camera: ImmediateWorkflowCamera([value.snapshot]),
            landmarks: model, definitions: [.testDistance], timeoutSeconds: 0.03,
            onTerminal: { events.append($0) })
        let error = await failure { try await workflow.run(orientation: .up) }
        XCTAssertEqual(error?.code, .timedOut)
        XCTAssertEqual(error?.stage, .landmarks)
        XCTAssertNotNil(events.first?.timings.captureSeconds)
        XCTAssertNotNil(events.first?.timings.landmarksSeconds)
        XCTAssertNil(events.first?.timings.measurementSeconds)
        XCTAssertEqual(events.first?.snapshot?.frame.frameID, value.snapshot.frame.frameID)
        await model.resume(frameID: value.snapshot.frame.frameID, points: value.points)
        await eventually { workflow.inFlightWorkerCount == 0 }
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(workflow.lastResult)
        XCTAssertEqual(workflow.phase, .failed)
    }

    func testCallerCancellationAtStageBoundaryCannotPublishSuccess() async {
        let value = fixture()
        let workflow = AutomaticMeasurementWorkflow(camera: ImmediateWorkflowCamera([value.snapshot]),
            landmarks: RecordingWorkflowModel(answers: [value.snapshot.frame.frameID: value.points]),
            definitions: [.testDistance])
        var caller: Task<Void, Never>?
        var outcome: Result<AutomaticMeasurementOutput, Error>?
        workflow.onPhaseChange = { phase in if phase == .measuring { caller?.cancel() } }
        caller = Task {
            do { outcome = .success(try await workflow.run(orientation: .up)) }
            catch { outcome = .failure(error) }
        }
        await eventually { outcome != nil }
        if case .failure(let error) = outcome {
            XCTAssertEqual((error as? AutomaticMeasurementWorkflowFailure)?.code, .cancelled)
        } else { XCTFail("A caller cancelled at the stage boundary must not receive success") }
        XCTAssertNil(workflow.lastResult)
        XCTAssertEqual(workflow.phase, .cancelled)
        await caller?.value
    }

    func testTenRapidRetakesCannotAccumulateMoreThanTwoNoncooperativeWorkers() async {
        let values = (0..<10).map { _ in fixture() }
        let camera = ImmediateWorkflowCamera(values.map(\.snapshot))
        let model = ControlledWorkflowModel()
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: model, definitions: [.testDistance])
        var tasks: [Task<Void, Never>] = []
        var errors: [AutomaticMeasurementWorkflowFailure] = []
        for attempt in 0..<10 {
            tasks.append(Task {
                do { _ = try await workflow.run(orientation: .up) }
                catch let error as AutomaticMeasurementWorkflowFailure { errors.append(error) }
                catch { XCTFail("Unexpected error: \(error)") }
            })
            if attempt < 2 { await eventually { await model.pendingCount == attempt + 1 } }
            else { await eventually { errors.count == attempt + 1 } }
            XCTAssertLessThanOrEqual(workflow.inFlightWorkerCount, AutomaticMeasurementWorkflow.maximumInFlightWorkers)
        }
        XCTAssertEqual(camera.calls, 2)
        XCTAssertEqual(workflow.inFlightWorkerCount, 2)
        XCTAssertEqual(errors.filter { $0.code == .cancelled }.count, 2)
        XCTAssertEqual(errors.filter { $0.code == .busy }.count, 8)
        for value in values.prefix(2) { await model.resume(frameID: value.snapshot.frame.frameID, points: value.points) }
        await eventually { workflow.inFlightWorkerCount == 0 }
        for task in tasks { await task.value }

        // Capacity becomes reusable after the uncooperative work actually exits.
        var recovered: AutomaticMeasurementOutput?
        let recovery = Task { recovered = try? await workflow.run(orientation: .up) }
        await eventually { await model.pendingCount == 1 }
        await model.resume(frameID: values[2].snapshot.frame.frameID, points: values[2].points)
        await eventually { recovered != nil }
        XCTAssertEqual(recovered?.snapshot.frame.frameID, values[2].snapshot.frame.frameID)
        await recovery.value
    }

    func testCooperativeRetakesDoNotHitTheDrainingWorkerLimit() async {
        let values = (0..<10).map { _ in fixture() }
        let model = CooperativeWorkflowModel()
        let workflow = AutomaticMeasurementWorkflow(camera: ImmediateWorkflowCamera(values.map(\.snapshot)),
            landmarks: model, definitions: [.testDistance])
        var tasks: [Task<Void, Never>] = []
        var errors: [AutomaticMeasurementWorkflowFailure] = []
        for attempt in 0..<10 {
            tasks.append(Task {
                do { _ = try await workflow.run(orientation: .up) }
                catch let error as AutomaticMeasurementWorkflowFailure { errors.append(error) }
                catch { XCTFail("Unexpected error: \(error)") }
            })
            await eventually { await model.calls == attempt + 1 }
            XCTAssertLessThanOrEqual(workflow.inFlightWorkerCount, 2)
        }
        workflow.cancel()
        await eventually { errors.count == 10 && workflow.inFlightWorkerCount == 0 }
        XCTAssertTrue(errors.allSatisfy { $0.code == .cancelled })
        for task in tasks { await task.value }
    }

    func testInvalidTimeoutConfigurationDoesNotStartProviders() async {
        for timeout in [0.0, -1, .infinity, .nan, 301] {
            let camera = ImmediateWorkflowCamera([])
            let workflow = AutomaticMeasurementWorkflow(camera: camera,
                landmarks: RecordingWorkflowModel(answers: [:]), definitions: [.testDistance], timeoutSeconds: timeout)
            let error = await failure { try await workflow.run(orientation: .up) }
            XCTAssertEqual(error?.code, .invalidConfiguration)
            XCTAssertEqual(camera.calls, 0)
            XCTAssertEqual(workflow.inFlightWorkerCount, 0)
        }
    }

    func testLiveProvenanceContractRejectsManualOriginMissingVersionAndSyntheticCameraData() async {
        for scenario in 0..<5 {
            var value = fixture()
            // This is fabricated adapter input inside a unit test, never a saved
            // sensor observation or a physical-accuracy fixture/report.
            value.snapshot.frame.source = .sceneDepth
            switch scenario {
            case 0: value.points.origin = .manual
            case 1: value.points.modelVersion = nil
            case 2: value.points.modelVersion = " \n\t"
            case 3: value.snapshot.frame.source = .synthetic
            default: value.points.origin = .synthetic
            }
            var phases: [AutomaticMeasurementPhase] = []
            let workflow = AutomaticMeasurementWorkflow(camera: ImmediateWorkflowCamera([value.snapshot]),
                landmarks: RecordingWorkflowModel(answers: [value.snapshot.frame.frameID: value.points]),
                definitions: [.testDistance], expectedLandmarkOrigin: .model,
                onPhaseChange: { phases.append($0) })
            let error = await failure { try await workflow.run(orientation: .up) }
            XCTAssertEqual(error?.code, .invalidProvenance, "scenario \(scenario)")
            XCTAssertEqual(error?.stage, .landmarks)
            XCTAssertNil(workflow.lastResult)
            XCTAssertFalse(phases.contains(.measuring))
        }
    }

    func testValidModelProvenanceDoesNotTurnMissingConfidenceIntoValidMeasurement() async throws {
        var value = fixture()
        value.snapshot.frame.source = .sceneDepth // Fabricated adapter metadata, not physical validation.
        value.points.points[0].confidence = nil
        let workflow = AutomaticMeasurementWorkflow(camera: ImmediateWorkflowCamera([value.snapshot]),
            landmarks: RecordingWorkflowModel(answers: [value.snapshot.frame.frameID: value.points]),
            definitions: [.testDistance], expectedLandmarkOrigin: .model)
        let output = try await workflow.run(orientation: .up)
        XCTAssertEqual(output.result.values.first?.status, .uncertain)
        XCTAssertEqual(output.landmarks.origin, .model)
        XCTAssertEqual(output.landmarks.modelVersion, value.points.modelVersion)
        XCTAssertNil(output.landmarks.points[0].confidence)
    }

    func testSyntheticContractRequiresSyntheticCameraAndLandmarkOrigin() async throws {
        for scenario in 0..<3 {
            var value = fixture()
            value.points.origin = .synthetic
            value.points.modelVersion = nil
            if scenario == 1 { value.points.origin = .model }
            if scenario == 2 { value.snapshot.frame.source = .sceneDepth }
            let workflow = AutomaticMeasurementWorkflow(camera: ImmediateWorkflowCamera([value.snapshot]),
                landmarks: RecordingWorkflowModel(answers: [value.snapshot.frame.frameID: value.points]),
                definitions: [.testDistance], expectedLandmarkOrigin: .synthetic)
            if scenario == 0 {
                let output = try await workflow.run(orientation: .up)
                XCTAssertEqual(output.snapshot.frame.source, .synthetic)
                XCTAssertEqual(output.landmarks.origin, .synthetic)
            } else {
                let error = await failure { try await workflow.run(orientation: .up) }
                XCTAssertEqual(error?.code, .invalidProvenance)
                XCTAssertNil(workflow.lastResult)
            }
        }
    }

    func testProviderTypedFailureCodesArePreservedAtTheCurrentStage() async {
        for stage in [AutomaticMeasurementStage.capture, .landmarks] {
            for code in [AutomaticMeasurementFailureCode.timedOut, .interrupted, .cancelled] {
                let value = fixture()
                let typed = ClassifiedWorkflowTestError(automaticMeasurementFailureCode: code)
                let camera = ImmediateWorkflowCamera([value.snapshot], error: stage == .capture ? typed : nil)
                let model = RecordingWorkflowModel(answers: [:], error: stage == .landmarks ? typed : nil)
                var events: [AutomaticMeasurementTerminalEvent] = []
                let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: model,
                    definitions: [.testDistance], onTerminal: { events.append($0) })
                let error = await failure { try await workflow.run(orientation: .up) }
                XCTAssertEqual(error?.code, code)
                XCTAssertEqual(error?.stage, stage)
                XCTAssertEqual(error?.message, typed.localizedDescription)
                XCTAssertEqual(events.count, 1)
                XCTAssertEqual(events.first?.failure?.code, code)
                XCTAssertEqual(events.first?.stage, stage)
                XCTAssertEqual(events.first?.status, code == .cancelled ? .cancelled : .failed)
            }
        }
    }

    func testEmptyDuplicateOrBlankDefinitionIDsFailBeforeCapture() async {
        let tooMany = (0..<101).map { MeasurementDefinition(id: "item-\($0)", title: "Item", landmarkIDs: ["A", "B"]) }
        let invalid: [[MeasurementDefinition]] = [[], [.testDistance, .testDistance],
            [.init(id: "", title: "Blank", landmarkIDs: ["A", "B"])],
            [.init(id: " \n", title: "Blank", landmarkIDs: ["A", "B"])], tooMany]
        for definitions in invalid {
            let camera = ImmediateWorkflowCamera([])
            let workflow = AutomaticMeasurementWorkflow(camera: camera,
                landmarks: RecordingWorkflowModel(answers: [:]), definitions: definitions)
            let error = await failure { try await workflow.run(orientation: .up) }
            XCTAssertEqual(error?.code, .invalidConfiguration)
            XCTAssertEqual(error?.stage, .capture)
            XCTAssertEqual(camera.calls, 0)
            XCTAssertEqual(workflow.inFlightWorkerCount, 0)
        }
    }
}

private enum WorkflowTestError: Error { case capture, landmarks, missingFixture }

private struct ClassifiedWorkflowTestError: AutomaticMeasurementFailureClassifying, LocalizedError {
    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode
    var errorDescription: String? { "Typed provider error: \(automaticMeasurementFailureCode.rawValue)" }
}

@MainActor
private final class ImmediateWorkflowCamera: CaptureSnapshotProviding {
    private let snapshots: [CaptureSnapshot]
    private let error: (any Error)?
    private(set) var calls = 0
    private(set) var orientations: [ImageOrientation] = []
    init(_ snapshots: [CaptureSnapshot], error: (any Error)? = nil) {
        self.snapshots = snapshots; self.error = error
    }
    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        orientations.append(orientation)
        let index = calls
        calls += 1
        if let error { throw error }
        guard snapshots.indices.contains(index) else { throw WorkflowTestError.missingFixture }
        return snapshots[index]
    }
}

@MainActor
private final class ControlledWorkflowCamera: CaptureSnapshotProviding {
    private var continuation: CheckedContinuation<CaptureSnapshot, Error>?
    var isPending: Bool { continuation != nil }
    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resume(_ snapshot: CaptureSnapshot) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: snapshot)
    }
}

private actor RecordingWorkflowModel: GarmentLandmarkProviding {
    let answers: [UUID: GarmentLandmarkSet]
    let error: (any Error)?
    private(set) var observedSnapshots: [CaptureSnapshot] = []
    init(answers: [UUID: GarmentLandmarkSet], error: (any Error)? = nil) {
        self.answers = answers; self.error = error
    }
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        observedSnapshots.append(snapshot)
        if let error { throw error }
        guard let points = answers[snapshot.frame.frameID] else { throw WorkflowTestError.missingFixture }
        return points
    }
}

/// Deliberately never checks Task cancellation, to test the workflow boundary.
private actor ControlledWorkflowModel: GarmentLandmarkProviding {
    private var pending: [UUID: CheckedContinuation<GarmentLandmarkSet, Error>] = [:]
    var pendingCount: Int { pending.count }
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        try await withCheckedThrowingContinuation { pending[snapshot.frame.frameID] = $0 }
    }
    func resume(frameID: UUID, points: GarmentLandmarkSet) {
        pending.removeValue(forKey: frameID)?.resume(returning: points)
    }
}

private actor CooperativeWorkflowModel: GarmentLandmarkProviding {
    private(set) var calls = 0
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        calls += 1
        try await Task.sleep(for: .seconds(60))
        throw WorkflowTestError.missingFixture
    }
}

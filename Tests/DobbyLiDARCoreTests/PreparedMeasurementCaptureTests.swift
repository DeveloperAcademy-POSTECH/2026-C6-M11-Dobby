import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Fabricated adapter contracts on analytic depth. Prepared reuse is not
/// evidence of camera/model performance or physical centimetre accuracy.
@MainActor
final class PreparedMeasurementCaptureTests: XCTestCase {
    private func fixture(kind: AutomaticGarmentKind = .top,
                         orientation: ImageOrientation = .right) -> PreparedMeasurementCapture {
        var scene = SyntheticFixtures.scene(tilted: true)
        scene.frame.frameID = UUID()
        scene.frame.orientation = orientation
        scene.frame.source = .sceneDepth // Adapter metadata only; the depth is synthetic.
        scene.landmarks.frameID = scene.frame.frameID
        scene.landmarks.origin = .model
        scene.landmarks.modelVersion = kind.modelVersion
        scene.landmarks.garmentKind = kind
        // Current automatic captures use an interior garment mask and the
        // representative-plane sampling convention (integer depth pixel rays).
        // Keep the old local-engine SyntheticFixtures contract untouched.
        let depthSize = scene.frame.depth.size
        var mask = [UInt8](repeating: 0, count: depthSize.width * depthSize.height)
        for y in 0..<depthSize.height { for x in 0..<depthSize.width {
            let rayX = (Double(x) * Double(scene.frame.imageSize.width) / Double(depthSize.width)
                        - scene.frame.intrinsics.cx) / scene.frame.intrinsics.fx
            scene.frame.depth.values[y * depthSize.width + x] = Float(1.15 / (1 - tan(25 * .pi / 180) * rayX))
            if x >= 10 && x < depthSize.width - 10 && y >= 10 && y < depthSize.height - 10 {
                mask[y * depthSize.width + x] = 1
            }
        } }
        scene.landmarks.mask = .init(size: depthSize, values: mask)
        return .init(snapshot: .init(frame: scene.frame, imageJPEG: Data([1, 2, 3])),
                     landmarks: scene.landmarks)
    }

    private func failure(_ body: () async throws -> AutomaticMeasurementOutput,
                         file: StaticString = #filePath, line: UInt = #line) async -> AutomaticMeasurementWorkflowFailure? {
        do {
            _ = try await body()
            XCTFail("Expected workflow failure", file: file, line: line)
            return nil
        } catch let error as AutomaticMeasurementWorkflowFailure { return error }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line); return nil }
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

    func testPreparedResultSkipsInferenceAndPreservesDynamicDefinitionsPhasesJournalAndArchive() async throws {
        let value = fixture(), camera = ImmediatePreparedWorkflowCamera([value])
        // A mistaken regular-capture call would freeze a different frame.
        camera.regularAnswers = [fixture().snapshot]
        let provider = PreparedWorkflowModel(answers: [:])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DobbyPreparedCapture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = MeasurementAttemptJournal(folder: folder.appendingPathComponent("attempts"))
        let archive = MeasurementArchive(folder: folder.appendingPathComponent("measurements"))
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: provider,
            definitions: [.init(id: "stale-preview", title: "Stale", landmarkIDs: ["missing", "point"])],
            expectedLandmarkOrigin: .model)
        let service = RecordedMeasurementService(workflow: workflow, journal: journal)
        var phases: [AutomaticMeasurementPhase] = []
        var snapshots: [CaptureSnapshot] = []
        var snapshotPhase: AutomaticMeasurementPhase?
        let recorded = try await service.run(orientation: .right, purpose: .fixture, isSynthetic: true,
            onPhaseChange: { phases.append($0) }, onSnapshot: {
                snapshots.append($0)
                snapshotPhase = workflow.phase
            })
        let output = recorded.workflowOutput
        let inferenceCalls = await provider.observedSnapshots
        XCTAssertTrue(inferenceCalls.isEmpty)
        XCTAssertEqual(camera.captureCalls, 0)
        XCTAssertEqual(camera.preparedCalls, 1)
        XCTAssertEqual(camera.preparedOrientations, [.right])
        XCTAssertEqual(phases, [.capturing, .detectingLandmarks, .measuring, .completed])
        XCTAssertEqual(snapshotPhase, .capturing)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.frame.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(output.snapshot.imageJPEG, value.snapshot.imageJPEG)
        XCTAssertEqual(output.landmarks.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(output.landmarks.garmentKind, .top)
        XCTAssertEqual(output.landmarks.modelVersion, AutomaticGarmentKind.top.modelVersion)
        XCTAssertEqual(output.definitions.map(\.id), ["top-prepared-distance", "top-prepared-missing"])
        XCTAssertEqual(output.result.values.map(\.status), [.valid, .unavailable])
        XCTAssertEqual(output.result.values.last?.failure, .missingLandmark)
        XCTAssertEqual(try XCTUnwrap(output.result.values.first?.meters), 0.5, accuracy: 0.00001)
        XCTAssertNil(recorded.recordingError)

        let attempts = try await journal.records()
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempt.phase, .measurement)
        XCTAssertEqual(attempt.outcome, .partial)
        XCTAssertEqual(attempt.frameID, output.snapshot.frame.frameID)
        XCTAssertEqual(attempt.sessionID, output.snapshot.frame.sessionID)
        XCTAssertEqual(attempt.timings.captureSeconds, output.timings.captureSeconds)
        XCTAssertEqual(attempt.timings.landmarksSeconds, output.timings.landmarksSeconds)
        XCTAssertEqual(attempt.timings.measurementSeconds, output.timings.measurementSeconds)
        XCTAssertNotNil(output.timings.captureSeconds)
        XCTAssertNotNil(output.timings.landmarksSeconds)
        XCTAssertNotNil(output.timings.measurementSeconds)

        let record = try AutomaticMeasurement(output: output).makeRecord()
        _ = try await archive.save(record)
        let loaded = try await archive.load(record.id)
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertEqual(loaded.snapshot.frame.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(loaded.landmarks.modelVersion, output.landmarks.modelVersion)
        XCTAssertEqual(loaded.definitions.map(\.id), output.definitions.map(\.id))
        XCTAssertEqual(loaded.result.values.map(\.meters), output.result.values.map(\.meters))
        let snapshotJSON = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(loaded.snapshot)) as? [String: Any])
        XCTAssertEqual(Set(snapshotJSON.keys), ["frame", "imageJPEG"],
            "Runtime prepared evidence must not add fields to CaptureSnapshot persistence")
    }

    func testPreparedRetakesResolveEachFrozenKindsDefinitionsWithoutRunningEitherInference() async throws {
        let top = fixture(), bottoms = fixture(kind: .bottoms)
        let camera = ImmediatePreparedWorkflowCamera([top, bottoms])
        let provider = PreparedWorkflowModel(answers: [:])
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: provider,
            definitions: [], expectedLandmarkOrigin: .model)
        for (value, prefix) in [(top, "top"), (bottoms, "bottom")] {
            let output = try await workflow.run(orientation: .right)
            XCTAssertEqual(output.landmarks.garmentKind, value.landmarks?.garmentKind)
            XCTAssertEqual(output.landmarks.modelVersion, value.landmarks?.modelVersion)
            XCTAssertEqual(output.definitions.map(\.id), ["\(prefix)-prepared-distance", "\(prefix)-prepared-missing"])
            XCTAssertEqual(output.result.frameID, value.snapshot.frame.frameID)
            XCTAssertEqual(output.result.values.first?.status, .valid)
        }
        let observed = await provider.observedSnapshots
        XCTAssertTrue(observed.isEmpty)
        XCTAssertEqual(camera.preparedCalls, 2)
        XCTAssertEqual(camera.captureCalls, 0)
    }

    func testPreparedSessionAndFrameMismatchFailBeforeResolverAndNeverRetryInference() async {
        for mismatchSession in [false, true] {
            var value = fixture()
            if mismatchSession { value.landmarks?.sessionID = UUID() }
            else { value.landmarks?.frameID = UUID() }
            // Missing kind would fail resolution, so frame mismatch must win first.
            value.landmarks?.garmentKind = nil
            let provider = PreparedWorkflowModel(answers: [:])
            var phases: [AutomaticMeasurementPhase] = []
            var events: [AutomaticMeasurementTerminalEvent] = []
            let workflow = AutomaticMeasurementWorkflow(camera: ImmediatePreparedWorkflowCamera([value]),
                landmarks: provider, definitions: [], expectedLandmarkOrigin: .model,
                onPhaseChange: { phases.append($0) }, onTerminal: { events.append($0) })
            let error = await failure { try await workflow.run(orientation: .right) }
            XCTAssertEqual(error?.code, .frameMismatch)
            XCTAssertEqual(error?.stage, .landmarks)
            XCTAssertFalse(phases.contains(.measuring))
            XCTAssertNil(workflow.lastResult)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.snapshot?.frame.frameID, value.snapshot.frame.frameID)
            let observed = await provider.observedSnapshots
            XCTAssertTrue(observed.isEmpty)
        }
    }

    func testPreparedOriginSourceAndMissingModelVersionStillUseLiveProvenanceChecks() async {
        for scenario in 0..<5 {
            var value = fixture()
            switch scenario {
            case 0: value.landmarks?.origin = .manual
            case 1: value.landmarks?.origin = .synthetic
            case 2: value.snapshot.frame.source = .synthetic
            case 3: value.landmarks?.modelVersion = nil
            default: value.landmarks?.modelVersion = " \n\t"
            }
            let provider = PreparedWorkflowModel(answers: [:])
            var phases: [AutomaticMeasurementPhase] = []
            let workflow = AutomaticMeasurementWorkflow(camera: ImmediatePreparedWorkflowCamera([value]),
                landmarks: provider, definitions: [], expectedLandmarkOrigin: .model,
                onPhaseChange: { phases.append($0) })
            let error = await failure { try await workflow.run(orientation: .right) }
            XCTAssertEqual(error?.code, .invalidProvenance, "scenario \(scenario)")
            XCTAssertEqual(error?.stage, .landmarks)
            XCTAssertFalse(phases.contains(.measuring))
            XCTAssertNil(workflow.lastResult)
            let observed = await provider.observedSnapshots
            XCTAssertTrue(observed.isEmpty)
        }
    }

    func testPreparedInvalidModelKindOrUnknownPointIDCannotBypassProviderResolver() async {
        for scenario in 0..<3 {
            var value = fixture()
            switch scenario {
            case 0: value.landmarks?.modelVersion = "unrelated-model"
            case 1: value.landmarks?.garmentKind = nil
            default: value.landmarks?.points[0].id = "unrelated-point"
            }
            let provider = PreparedWorkflowModel(answers: [:])
            let workflow = AutomaticMeasurementWorkflow(camera: ImmediatePreparedWorkflowCamera([value]),
                landmarks: provider, definitions: [.testDistance], expectedLandmarkOrigin: .model)
            let error = await failure { try await workflow.run(orientation: .right) }
            XCTAssertEqual(error?.code, .invalidProvenance)
            XCTAssertEqual(error?.stage, .landmarks)
            XCTAssertNil(workflow.lastResult)
            let observed = await provider.observedSnapshots
            XCTAssertTrue(observed.isEmpty)
        }
    }

    func testPreparedDynamicEmptyAndDuplicateDefinitionsFailBeforeMeasurement() async {
        for invalid in [[], [.testDistance, .testDistance]] as [[MeasurementDefinition]] {
            let value = fixture()
            let provider = PreparedWorkflowModel(answers: [:], overrideDefinitions: invalid)
            var phases: [AutomaticMeasurementPhase] = []
            let workflow = AutomaticMeasurementWorkflow(camera: ImmediatePreparedWorkflowCamera([value]),
                landmarks: provider, definitions: [.testDistance], expectedLandmarkOrigin: .model,
                onPhaseChange: { phases.append($0) })
            let error = await failure { try await workflow.run(orientation: .right) }
            XCTAssertEqual(error?.code, .invalidConfiguration)
            XCTAssertEqual(error?.stage, .landmarks)
            XCTAssertFalse(phases.contains(.measuring))
        }
    }

    func testNilPreparedPointsRunExistingInferenceOnTheExactCapturedSnapshot() async throws {
        let value = fixture(orientation: .left)
        var empty = value
        empty.landmarks = nil
        let camera = ImmediatePreparedWorkflowCamera([empty])
        let provider = PreparedWorkflowModel(answers: [value.snapshot.frame.frameID: try XCTUnwrap(value.landmarks)])
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: provider,
            definitions: [], expectedLandmarkOrigin: .model)
        let output = try await workflow.run(orientation: .left)
        let observed = await provider.observedSnapshots
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.imageJPEG, value.snapshot.imageJPEG)
        XCTAssertEqual(observed.first?.frame.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(observed.first?.frame.orientation, .left)
        XCTAssertEqual(camera.preparedCalls, 1)
        XCTAssertEqual(camera.captureCalls, 0)
        XCTAssertEqual(output.landmarks.garmentKind, .top)
        XCTAssertEqual(output.result.values.first?.status, .valid)
    }

    func testPreparedCameraWithStaticProviderKeepsRegularCaptureAndInferencePath() async throws {
        let value = fixture(), camera = ImmediatePreparedWorkflowCamera([fixture()])
        camera.regularAnswers = [value.snapshot]
        let provider = StaticPreparedWorkflowModel(points: try XCTUnwrap(value.landmarks))
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: provider,
            definitions: [.testDistance], expectedLandmarkOrigin: .model)
        let output = try await workflow.run(orientation: .right)
        let observed = await provider.observedSnapshots
        XCTAssertEqual(camera.captureCalls, 1)
        XCTAssertEqual(camera.preparedCalls, 0)
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.frame.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(output.definitions.map(\.id), [MeasurementDefinition.testDistance.id])
        XCTAssertEqual(output.result.values.first?.status, .valid)
    }

    func testPreparedReuseDoesNotPromoteUnknownOrLowModelConfidenceToValidMeasurements() async throws {
        for confidence: Double? in [nil, 0.1] {
            var value = fixture()
            value.landmarks?.points[0].confidence = confidence
            let workflow = AutomaticMeasurementWorkflow(camera: ImmediatePreparedWorkflowCamera([value]),
                landmarks: PreparedWorkflowModel(answers: [:]), definitions: [], expectedLandmarkOrigin: .model)
            let output = try await workflow.run(orientation: .right)
            XCTAssertEqual(output.landmarks.points[0].confidence, confidence)
            XCTAssertEqual(output.result.values.first?.status, confidence == nil ? .uncertain : .unavailable)
            XCTAssertEqual(output.result.values.first?.failure, confidence == nil ? nil : .lowLandmarkConfidence)
        }
    }

    func testLatePreparedCaptureAfterCallerCancellationCannotPublishSnapshotOrLandmarks() async throws {
        let value = fixture(), camera = ControlledPreparedWorkflowCamera()
        let provider = PreparedWorkflowModel(answers: [:])
        var phases: [AutomaticMeasurementPhase] = []
        var events: [AutomaticMeasurementTerminalEvent] = []
        var snapshotCount = 0
        var cancelledFailure: AutomaticMeasurementWorkflowFailure?
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: provider,
            definitions: [], expectedLandmarkOrigin: .model,
            onPhaseChange: { phases.append($0) }, onTerminal: { events.append($0) },
            onSnapshot: { _ in snapshotCount += 1 })
        let caller = Task {
            do { _ = try await workflow.run(orientation: .right); XCTFail("Cancelled caller received success") }
            catch { cancelledFailure = error as? AutomaticMeasurementWorkflowFailure }
        }
        await eventually { camera.isPending }
        caller.cancel()
        await caller.value
        XCTAssertEqual(cancelledFailure?.code, .cancelled)
        XCTAssertEqual(cancelledFailure?.stage, .capture)
        XCTAssertEqual(workflow.inFlightWorkerCount, 1, "The uncooperative camera remains bounded while draining")
        camera.resume(value)
        await eventually { workflow.inFlightWorkerCount == 0 }
        XCTAssertEqual(snapshotCount, 0)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.snapshot)
        XCTAssertEqual(phases, [.capturing, .cancelled])
        XCTAssertNil(workflow.lastResult)
        let observed = await provider.observedSnapshots
        XCTAssertTrue(observed.isEmpty)
    }

    func testCancellationFromPreparedSnapshotCallbackStopsBeforeResolutionAndMeasurement() async {
        let value = fixture(), provider = PreparedWorkflowModel(answers: [:])
        let workflow = AutomaticMeasurementWorkflow(camera: ImmediatePreparedWorkflowCamera([value]),
            landmarks: provider, definitions: [], expectedLandmarkOrigin: .model)
        var snapshotCount = 0
        var phases: [AutomaticMeasurementPhase] = []
        workflow.onPhaseChange = { phases.append($0) }
        workflow.onSnapshot = { _ in snapshotCount += 1; workflow.cancel() }
        let error = await failure { try await workflow.run(orientation: .right) }
        XCTAssertEqual(error?.code, .cancelled)
        XCTAssertEqual(error?.stage, .capture)
        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(phases, [.capturing, .cancelled])
        XCTAssertNil(workflow.lastResult)
        let observed = await provider.observedSnapshots
        XCTAssertTrue(observed.isEmpty)
    }
}

private enum PreparedWorkflowFixtureError: Error { case missingAnswer }

@MainActor
private final class ImmediatePreparedWorkflowCamera: PreparedCaptureSnapshotProviding {
    var preparedAnswers: [PreparedMeasurementCapture]
    var regularAnswers: [CaptureSnapshot]
    private(set) var captureCalls = 0
    private(set) var preparedCalls = 0
    private(set) var preparedOrientations: [ImageOrientation] = []

    init(_ answers: [PreparedMeasurementCapture]) {
        preparedAnswers = answers
        regularAnswers = answers.map(\.snapshot)
    }

    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        let index = captureCalls
        captureCalls += 1
        guard regularAnswers.indices.contains(index) else { throw PreparedWorkflowFixtureError.missingAnswer }
        return regularAnswers[index]
    }

    func capturePrepared(orientation: ImageOrientation) async throws -> PreparedMeasurementCapture {
        let index = preparedCalls
        preparedCalls += 1
        preparedOrientations.append(orientation)
        guard preparedAnswers.indices.contains(index) else { throw PreparedWorkflowFixtureError.missingAnswer }
        return preparedAnswers[index]
    }
}

/// Deliberately ignores cancellation until resumed, exercising the workflow's
/// guard after the prepared camera returns rather than cooperative adapter code.
@MainActor
private final class ControlledPreparedWorkflowCamera: PreparedCaptureSnapshotProviding {
    private var continuation: CheckedContinuation<PreparedMeasurementCapture, Error>?
    var isPending: Bool { continuation != nil }

    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        throw PreparedWorkflowFixtureError.missingAnswer
    }

    func capturePrepared(orientation: ImageOrientation) async throws -> PreparedMeasurementCapture {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume(_ prepared: PreparedMeasurementCapture) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: prepared)
    }
}

private actor PreparedWorkflowModel: GarmentMeasurementDefinitionProviding {
    private let answers: [UUID: GarmentLandmarkSet]
    nonisolated let overrideDefinitions: [MeasurementDefinition]?
    private(set) var observedSnapshots: [CaptureSnapshot] = []

    init(answers: [UUID: GarmentLandmarkSet], overrideDefinitions: [MeasurementDefinition]? = nil) {
        self.answers = answers
        self.overrideDefinitions = overrideDefinitions
    }

    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        observedSnapshots.append(snapshot)
        guard let answer = answers[snapshot.frame.frameID] else { throw PreparedWorkflowFixtureError.missingAnswer }
        return answer
    }

    nonisolated func measurementDefinitions(for landmarks: GarmentLandmarkSet) throws -> [MeasurementDefinition] {
        let ids = landmarks.points.map(\.id)
        guard landmarks.origin == .model, let kind = landmarks.garmentKind,
              landmarks.modelVersion == kind.modelVersion,
              !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: ["A", "B"]) else {
            throw AutomaticMeasurementWorkflowFailure(stage: .landmarks, code: .invalidProvenance,
                message: "Prepared fixture kind, model or keypoints do not match")
        }
        if let overrideDefinitions { return overrideDefinitions }
        let prefix = kind == .top ? "top" : "bottom"
        return [.init(id: "\(prefix)-prepared-distance", title: "Distance", landmarkIDs: ["A", "B"]),
                .init(id: "\(prefix)-prepared-missing", title: "Missing", landmarkIDs: ["A", "missing"])]
    }
}

private actor StaticPreparedWorkflowModel: GarmentLandmarkProviding {
    private let points: GarmentLandmarkSet
    private(set) var observedSnapshots: [CaptureSnapshot] = []

    init(points: GarmentLandmarkSet) { self.points = points }

    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        observedSnapshots.append(snapshot)
        return points
    }
}

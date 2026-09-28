import Foundation
import XCTest
@testable import DobbyLiDARCore

@MainActor
final class RecordedMeasurementServiceTests: XCTestCase {
    private struct Fixture {
        var snapshot: CaptureSnapshot
        var points: GarmentLandmarkSet
    }

    private func fixture() -> Fixture {
        var scene = SyntheticFixtures.scene()
        scene.frame.frameID = UUID()
        scene.landmarks.frameID = scene.frame.frameID
        scene.landmarks.origin = .synthetic
        return .init(snapshot: .init(frame: scene.frame, imageJPEG: Data([1, 2, 3])), points: scene.landmarks)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-service-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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

    private func onlyRecord(_ journal: MeasurementAttemptJournal,
                            file: StaticString = #filePath, line: UInt = #line) async throws -> MeasurementAttemptRecord {
        let records = try await journal.records()
        XCTAssertEqual(records.count, 1, file: file, line: line)
        return try XCTUnwrap(records.first, file: file, line: line)
    }

    func testPartialCalculationPreservesAllResultsAndRecordsOneTerminalWithStageTimings() async throws {
        let value = fixture()
        let journal = MeasurementAttemptJournal(folder: try folder())
        let camera = RecordedTestCamera(value.snapshot)
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: RecordedTestModel(value.points),
            definitions: [.testDistance, .init(id: "missing", title: "Missing", landmarkIDs: ["A", "missing"])])
        let service = RecordedMeasurementService(workflow: workflow, journal: journal)
        var phases: [AutomaticMeasurementPhase] = []
        let output = try await service.run(orientation: .left, purpose: .fixture, isSynthetic: true,
            deviceContext: "Service fixture", onPhaseChange: { phases.append($0) })
        XCTAssertNil(output.recordingError)
        XCTAssertEqual(output.workflowOutput.result.values.map(\.status), [.valid, .unavailable])
        XCTAssertEqual(camera.orientations, [.left])
        XCTAssertEqual(phases, [.capturing, .detectingLandmarks, .measuring, .completed])
        let record = try await onlyRecord(journal)
        XCTAssertEqual(record.outcome, .partial)
        XCTAssertEqual(record.phase, .measurement)
        XCTAssertEqual(record.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(record.sessionID, value.snapshot.frame.sessionID)
        XCTAssertEqual(record.deviceContext, "Service fixture")
        XCTAssertEqual(record.timings.captureSeconds, output.workflowOutput.timings.captureSeconds)
        XCTAssertEqual(record.timings.landmarksSeconds, output.workflowOutput.timings.landmarksSeconds)
        XCTAssertEqual(record.timings.measurementSeconds, output.workflowOutput.timings.measurementSeconds)
        XCTAssertEqual(record.timings.totalSeconds, output.workflowOutput.timings.totalSeconds)
        let report = try await journal.report()
        XCTAssertEqual(report.synthetic.partialAttempts, 1)
        XCTAssertEqual(report.physical.totalAttempts, 0)
    }

    func testFullyUnavailableResultIsNotRecordedAsSuccess() async throws {
        var value = fixture()
        value.points.points = []
        let journal = MeasurementAttemptJournal(folder: try folder())
        let service = RecordedMeasurementService(workflow: .init(camera: RecordedTestCamera(value.snapshot),
            landmarks: RecordedTestModel(value.points), definitions: [.testDistance]), journal: journal)
        _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true)
        let record = try await onlyRecord(journal)
        XCTAssertEqual(record.outcome, .unavailable)
        XCTAssertEqual(record.phase, .measurement)
        let report = try await journal.report()
        XCTAssertEqual(report.synthetic.successfulAttempts, 0)
        XCTAssertEqual(report.synthetic.failureCount, 1)
    }

    func testProviderFailuresRetainTypedCodeStageAndFailedStageStatistics() async throws {
        for stage in [AutomaticMeasurementStage.capture, .landmarks] {
            for code in [AutomaticMeasurementFailureCode.providerFailure, .timedOut, .interrupted, .cancelled] {
                let value = fixture()
                let journal = MeasurementAttemptJournal(folder: try folder())
                let providerError = RecordedProviderError(automaticMeasurementFailureCode: code)
                let service = RecordedMeasurementService(workflow: .init(
                    camera: RecordedTestCamera(value.snapshot, error: stage == .capture ? providerError : nil),
                    landmarks: RecordedTestModel(value.points, error: stage == .landmarks ? providerError : nil),
                    definitions: [.testDistance]), journal: journal)
                do {
                    _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true)
                    XCTFail("Expected provider failure")
                } catch let failure as AutomaticMeasurementWorkflowFailure {
                    XCTAssertEqual(failure.code, code)
                    XCTAssertEqual(failure.stage, stage)
                }
                let record = try await onlyRecord(journal)
                let expected: MeasurementAttemptOutcome
                switch code {
                case .timedOut: expected = .timedOut
                case .interrupted: expected = .interrupted
                case .cancelled: expected = .cancelled
                default: expected = stage == .capture ? .captureFailed : .landmarkFailed
                }
                XCTAssertEqual(record.outcome, expected)
                XCTAssertEqual(record.phase, stage == .capture ? .capture : .landmarks)
                XCTAssertNotNil(record.timings.captureSeconds)
                XCTAssertEqual(record.timings.landmarksSeconds == nil, stage == .capture)
                XCTAssertNil(record.timings.measurementSeconds)
                let report = try await journal.report()
                XCTAssertEqual(report.synthetic.captureLatency.sampleCount, stage == .capture ? 0 : 1)
                XCTAssertEqual(report.synthetic.landmarksLatency.sampleCount, 0)
                XCTAssertEqual(report.synthetic.totalLatency.sampleCount, 1)
            }
        }
    }

    func testConcurrentRunIsRejectedWithoutStartingAnotherAttempt() async throws {
        let value = fixture(), model = RecordedControlledModel()
        let journal = MeasurementAttemptJournal(folder: try folder())
        let workflow = AutomaticMeasurementWorkflow(camera: RecordedTestCamera(value.snapshot),
            landmarks: model, definitions: [.testDistance])
        let service = RecordedMeasurementService(workflow: workflow, journal: journal)
        let first = Task { try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true) }
        await eventually { await model.pendingCount == 1 }
        do {
            _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true)
            XCTFail("Expected concurrent run rejection")
        } catch let error as RecordedMeasurementServiceError { XCTAssertEqual(error, .alreadyRunning) }
        service.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        service.cancel()
        await model.resume(value.points)
        await eventually { workflow.inFlightWorkerCount == 0 }
        let record = try await onlyRecord(journal)
        XCTAssertEqual(record.outcome, .cancelled)
    }

    func testCancellationAfterBeginBeforeCaptureFinalizesAttemptWithoutStartingCamera() async throws {
        let value = fixture(), camera = RecordedTestCamera(fixture().snapshot)
        let journal = MeasurementAttemptJournal(folder: try folder())
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: RecordedTestModel(value.points),
            definitions: [.testDistance])
        let service = RecordedMeasurementService(workflow: workflow, journal: journal)
        do {
            _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true,
                onPhaseChange: { if $0 == .capturing { service.cancel() } })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(camera.calls, 0)
        let record = try await onlyRecord(journal)
        XCTAssertEqual(record.outcome, .cancelled)
        XCTAssertEqual(record.phase, .capture)
        XCTAssertNil(record.frameID)
        XCTAssertEqual(workflow.inFlightWorkerCount, 0)
    }

    func testAlreadyCancelledTaskDoesNotBeginAttempt() async throws {
        let value = fixture(), camera = RecordedTestCamera(fixture().snapshot)
        let journal = MeasurementAttemptJournal(folder: try folder())
        let service = RecordedMeasurementService(workflow: .init(camera: camera,
            landmarks: RecordedTestModel(value.points), definitions: [.testDistance]), journal: journal)
        let task = Task { try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let records = try await journal.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(camera.calls, 0)
    }

    func testCallerCancellationAndLateProviderCannotOverwriteRetakeOrDuplicateTerminal() async throws {
        let value = fixture(), model = RecordedControlledModel()
        let journal = MeasurementAttemptJournal(folder: try folder())
        let workflow = AutomaticMeasurementWorkflow(camera: RecordedTestCamera(value.snapshot),
            landmarks: model, definitions: [.testDistance])
        let service = RecordedMeasurementService(workflow: workflow, journal: journal)
        let first = Task { try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true) }
        await eventually { await model.pendingCount == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let second = Task { try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true) }
        await eventually { await model.pendingCount == 2 }
        await model.resume(value.points, index: 1)
        let result = try await second.value
        await model.resume(value.points)
        await eventually { workflow.inFlightWorkerCount == 0 }
        service.cancel()
        let records = try await journal.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.filter { $0.outcome == .cancelled }.count, 1)
        XCTAssertEqual(records.filter { $0.outcome == .success }.count, 1)
        XCTAssertEqual(workflow.lastResult?.runID, result.workflowOutput.runID)
    }

    func testCancellationAtCompletedBoundaryDoesNotTurnCompletedCalculationIntoCancellationStatistic() async throws {
        let value = fixture()
        let journal = MeasurementAttemptJournal(folder: try folder())
        let service = RecordedMeasurementService(workflow: .init(camera: RecordedTestCamera(value.snapshot),
            landmarks: RecordedTestModel(value.points), definitions: [.testDistance]), journal: journal)
        do {
            _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true,
                onPhaseChange: { if $0 == .completed { service.cancel() } })
            XCTFail("Cancelled caller must not receive a result to present")
        } catch is CancellationError { }
        let record = try await onlyRecord(journal)
        XCTAssertEqual(record.outcome, .success)
        XCTAssertEqual(record.phase, .measurement)
        let report = try await journal.report()
        XCTAssertEqual(report.synthetic.successfulAttempts, 1)
        XCTAssertEqual(report.synthetic.cancellations, 0)
    }

    func testCancellationAtFailedBoundaryPreservesFirstTypedTerminalInStatistics() async throws {
        let value = fixture()
        let journal = MeasurementAttemptJournal(folder: try folder())
        let service = RecordedMeasurementService(workflow: .init(camera: RecordedTestCamera(value.snapshot,
            error: RecordedProviderError(automaticMeasurementFailureCode: .timedOut)),
            landmarks: RecordedTestModel(value.points), definitions: [.testDistance]), journal: journal)
        do {
            _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true,
                onPhaseChange: { if $0 == .failed { service.cancel() } })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        let record = try await onlyRecord(journal)
        XCTAssertEqual(record.outcome, .timedOut)
    }

    func testWorkflowTimeoutFinalizesWithoutWaitingForUncooperativeProvider() async throws {
        let value = fixture(), model = RecordedControlledModel()
        let journal = MeasurementAttemptJournal(folder: try folder())
        let workflow = AutomaticMeasurementWorkflow(camera: RecordedTestCamera(value.snapshot),
            landmarks: model, definitions: [.testDistance], timeoutSeconds: 0.03)
        let service = RecordedMeasurementService(workflow: workflow, journal: journal)
        do {
            _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true)
            XCTFail("Expected timeout")
        } catch let failure as AutomaticMeasurementWorkflowFailure {
            XCTAssertEqual(failure.code, .timedOut)
        }
        let record = try await onlyRecord(journal)
        XCTAssertEqual(record.outcome, .timedOut)
        XCTAssertEqual(record.phase, .landmarks)
        XCTAssertNotNil(record.timings.landmarksSeconds)
        XCTAssertNil(record.timings.measurementSeconds)
        XCTAssertEqual(workflow.inFlightWorkerCount, 1)
        await model.resume(value.points)
        await eventually { workflow.inFlightWorkerCount == 0 }
        let finalRecord = try await onlyRecord(journal)
        XCTAssertEqual(finalRecord, record)
    }

    func testSuccessfulCalculationSurvivesJournalFinishErrorAndRemainsUnfinished() async throws {
        let value = fixture(), directory = try folder()
        let journal = MeasurementAttemptJournal(folder: directory)
        let service = RecordedMeasurementService(workflow: .init(camera: RecordedTestCamera(value.snapshot),
            landmarks: RecordedTestModel(value.points), definitions: [.testDistance]), journal: journal)
        var original: (URL, Data)?
        let output = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true,
            onPhaseChange: { phase in
                if phase == .completed { original = self.corruptSingleRecord(in: directory) }
            })
        XCTAssertNotNil(output.recordingError)
        XCTAssertEqual(output.workflowOutput.result.values.first?.status, .valid)
        let restore = try XCTUnwrap(original)
        try restore.1.write(to: restore.0, options: .atomic)
        let record = try await onlyRecord(journal)
        XCTAssertNil(record.outcome)
        XCTAssertNil(record.finishedAt)
        let report = try await journal.report()
        XCTAssertEqual(report.synthetic.unfinishedAttempts, 1)
        XCTAssertEqual(report.synthetic.landmarkFailures, 0)
    }

    func testWorkflowFailureAndJournalFailureRemainSeparate() async throws {
        let value = fixture(), directory = try folder()
        let journal = MeasurementAttemptJournal(folder: directory)
        let service = RecordedMeasurementService(workflow: .init(camera: RecordedTestCamera(value.snapshot,
            error: RecordedProviderError(automaticMeasurementFailureCode: .interrupted)),
            landmarks: RecordedTestModel(value.points), definitions: [.testDistance]), journal: journal)
        do {
            _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true,
                onPhaseChange: { phase in
                    if phase == .failed { _ = self.corruptSingleRecord(in: directory) }
                })
            XCTFail("Expected both failure diagnostics")
        } catch let failure as RecordedMeasurementRunFailure {
            XCTAssertEqual(failure.workflowFailure.stage, .capture)
            XCTAssertEqual(failure.automaticMeasurementFailureCode, .interrupted)
            XCTAssertFalse(failure.recordingError.isEmpty)
        }
    }

    func testJournalBeginFailureDoesNotStartCameraAndServiceCanBeReusedAfterRepair() async throws {
        let value = fixture(), directory = try folder(), camera = RecordedTestCamera(fixture().snapshot)
        let path = directory.appendingPathComponent("attempts")
        try Data([1]).write(to: path)
        let journal = MeasurementAttemptJournal(folder: path)
        let service = RecordedMeasurementService(workflow: .init(camera: camera,
            landmarks: RecordedTestModel(value.points), definitions: [.testDistance]), journal: journal)
        do {
            _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true)
            XCTFail("Expected journal begin error")
        } catch { XCTAssertFalse(error is AutomaticMeasurementWorkflowFailure) }
        XCTAssertEqual(camera.calls, 0)
        try FileManager.default.removeItem(at: path)
        camera.snapshot = value.snapshot
        _ = try await service.run(orientation: .up, purpose: .fixture, isSynthetic: true)
        XCTAssertEqual(camera.calls, 1)
        let record = try await onlyRecord(journal)
        XCTAssertEqual(record.outcome, .success)
    }

    private func corruptSingleRecord(in folder: URL) -> (URL, Data)? {
        do {
            let paths = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            let path = try XCTUnwrap(paths.first)
            let data = try Data(contentsOf: path)
            try Data("invalid JSON".utf8).write(to: path, options: .atomic)
            return (path, data)
        } catch { XCTFail("Could not simulate a damaged journal file: \(error)"); return nil }
    }
}

private struct RecordedProviderError: AutomaticMeasurementFailureClassifying {
    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode
}

@MainActor
private final class RecordedTestCamera: CaptureSnapshotProviding {
    var snapshot: CaptureSnapshot
    let error: (any Error)?
    private(set) var calls = 0
    private(set) var orientations: [ImageOrientation] = []
    init(_ snapshot: CaptureSnapshot, error: (any Error)? = nil) { self.snapshot = snapshot; self.error = error }
    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        calls += 1
        orientations.append(orientation)
        if let error { throw error }
        return snapshot
    }
}

private actor RecordedTestModel: GarmentLandmarkProviding {
    let points: GarmentLandmarkSet
    let error: (any Error)?
    init(_ points: GarmentLandmarkSet, error: (any Error)? = nil) { self.points = points; self.error = error }
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        if let error { throw error }
        return points
    }
}

private actor RecordedControlledModel: GarmentLandmarkProviding {
    private var pending: [CheckedContinuation<GarmentLandmarkSet, Error>] = []
    var pendingCount: Int { pending.count }
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resume(_ points: GarmentLandmarkSet, index: Int = 0) {
        guard pending.indices.contains(index) else { return }
        pending.remove(at: index).resume(returning: points)
    }
}

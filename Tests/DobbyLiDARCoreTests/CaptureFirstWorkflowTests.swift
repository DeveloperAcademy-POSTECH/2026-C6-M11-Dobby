import Foundation
import XCTest
@testable import DobbyLiDARCore

/// The camera implements only fresh snapshot capture, with no prepared-result
/// capability. All RGB bytes and sensor metadata here are fabricated fixtures;
/// these tests verify workflow ordering and provenance, not physical accuracy.
@MainActor
final class CaptureFirstWorkflowTests: XCTestCase {
    private struct Fixture {
        var snapshot: CaptureSnapshot
        var points: GarmentLandmarkSet
    }

    private func fixture() -> Fixture {
        var scene = SyntheticFixtures.scene(tilted: true)
        scene.frame.frameID = UUID()
        scene.frame.source = .sceneDepth
        scene.frame.orientation = .right
        scene.landmarks.frameID = scene.frame.frameID
        scene.landmarks.origin = .model
        scene.landmarks.garmentKind = .top
        scene.landmarks.modelVersion = AutomaticGarmentKind.top.modelVersion
        var smoothed = scene.frame
        smoothed.source = .smoothedSceneDepth
        let quality = CaptureFrameQuality.evaluate(depth: scene.frame.depth,
            timestamp: scene.frame.timestamp, trackingNormal: true,
            translationSpeedMetersPerSecond: 0, angularSpeedRadiansPerSecond: 0)
        let summary = CaptureSelectionSummary(observedFrameCount: 3, eligibleCandidateCount: 2,
            waitingDurationSeconds: 0.4, selectionWindowSeconds: CaptureFrameSelector.windowDuration,
            selectedFrameTimestamp: scene.frame.timestamp, selectedQuality: quality)
        return .init(snapshot: .init(frame: scene.frame, imageJPEG: Data([0xFA, 0xCE, 0x01]),
                                    smoothedFrame: smoothed, selectionSummary: summary),
                     points: scene.landmarks)
    }

    func testFreshCapturePublishesExactSnapshotBeforeDynamicInferenceAndMeasurement() async throws {
        let value = fixture(), timeline = CaptureFirstTimeline()
        let camera = CaptureFirstCamera(timeline: timeline)
        let provider = CaptureFirstModel(timeline: timeline)
        var snapshots: [CaptureSnapshot] = []
        var terminal: [AutomaticMeasurementTerminalEvent] = []
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: provider,
            definitions: [.init(id: "stale-preview-bottom", title: "Stale preview",
                                landmarkIDs: ["missing", "point"])], expectedLandmarkOrigin: .model,
            onPhaseChange: { timeline.record("phase.\($0.rawValue)") },
            onTerminal: { terminal.append($0); timeline.record("terminal.\($0.status.rawValue)") },
            onSnapshot: { snapshots.append($0); timeline.record("snapshot") })
        let task = Task { try await workflow.run(orientation: .right) }

        await eventually { camera.isPending }
        XCTAssertEqual(timeline.events, ["phase.capturing", "capture.request"])
        XCTAssertTrue(snapshots.isEmpty)
        let beforeCapture = await provider.observedSnapshots
        XCTAssertTrue(beforeCapture.isEmpty, "Inference must not delay the shutter before RGB/depth are frozen")

        camera.resume(value.snapshot)
        await eventually { await provider.isPending }
        XCTAssertEqual(timeline.events, ["phase.capturing", "capture.request", "capture.returned",
                                        "snapshot", "phase.detectingLandmarks", "inference"])
        XCTAssertEqual(snapshots.count, 1)
        try assertSameSnapshot(snapshots.first, value.snapshot)
        let observed = await provider.observedSnapshots
        XCTAssertEqual(observed.count, 1)
        try assertSameSnapshot(observed.first, value.snapshot)
        XCTAssertNil(workflow.lastResult)
        XCTAssertTrue(terminal.isEmpty)

        await provider.succeed(value.points)
        let output = try await task.value
        XCTAssertEqual(timeline.events, ["phase.capturing", "capture.request", "capture.returned",
                                        "snapshot", "phase.detectingLandmarks", "inference",
                                        "phase.measuring", "phase.completed", "terminal.completed"])
        XCTAssertEqual(camera.orientations, [.right])
        XCTAssertEqual(snapshots.count, 1)
        try assertSameSnapshot(output.snapshot, value.snapshot)
        XCTAssertEqual(output.landmarks.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(output.result.sessionID, value.snapshot.frame.sessionID)
        XCTAssertEqual(output.result.frameID, value.snapshot.frame.frameID)
        XCTAssertEqual(output.definitions.map(\.id), ["top-captured-distance"])
        XCTAssertEqual(output.result.values.map(\.id), ["top-captured-distance"])
        XCTAssertEqual(output.result.values.first?.status, .valid)
        XCTAssertEqual(try XCTUnwrap(output.result.values.first?.meters), 0.5, accuracy: 0.00001)
        XCTAssertEqual(terminal.count, 1)
        try assertSameSnapshot(terminal.first?.snapshot, value.snapshot)
    }

    func testInferenceFailureKeepsPublishedFreshSnapshotWithoutMeasurement() async throws {
        let value = fixture(), timeline = CaptureFirstTimeline()
        let camera = CaptureFirstCamera(timeline: timeline)
        let provider = CaptureFirstModel(timeline: timeline)
        var snapshots: [CaptureSnapshot] = []
        var phases: [AutomaticMeasurementPhase] = []
        var terminal: [AutomaticMeasurementTerminalEvent] = []
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: provider,
            definitions: [], expectedLandmarkOrigin: .model,
            onPhaseChange: { phases.append($0) }, onTerminal: { terminal.append($0) },
            onSnapshot: { snapshots.append($0) })
        let task = Task { try await workflow.run(orientation: .right) }
        await eventually { camera.isPending }
        camera.resume(value.snapshot)
        await eventually { await provider.isPending }
        XCTAssertEqual(snapshots.count, 1)
        try assertSameSnapshot(snapshots.first, value.snapshot)

        await provider.fail()
        let failure = await workflowFailure { try await task.value }
        XCTAssertEqual(failure?.stage, .landmarks)
        XCTAssertEqual(failure?.code, .providerFailure)
        XCTAssertEqual(phases, [.capturing, .detectingLandmarks, .failed])
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(terminal.count, 1)
        XCTAssertEqual(terminal.first?.status, .failed)
        try assertSameSnapshot(terminal.first?.snapshot, value.snapshot)
        XCTAssertNil(terminal.first?.result)
        XCTAssertNil(terminal.first?.timings.measurementSeconds)
        XCTAssertNil(workflow.lastResult)
    }

    func testCancelledShutterRejectsLateSnapshotBeforePublicationOrInference() async {
        let value = fixture(), timeline = CaptureFirstTimeline()
        let camera = CaptureFirstCamera(timeline: timeline)
        let provider = CaptureFirstModel(timeline: timeline)
        var snapshots: [CaptureSnapshot] = []
        var phases: [AutomaticMeasurementPhase] = []
        var terminal: [AutomaticMeasurementTerminalEvent] = []
        let workflow = AutomaticMeasurementWorkflow(camera: camera, landmarks: provider,
            definitions: [], expectedLandmarkOrigin: .model,
            onPhaseChange: { phases.append($0) }, onTerminal: { terminal.append($0) },
            onSnapshot: { snapshots.append($0) })
        let task = Task { try await workflow.run(orientation: .right) }
        await eventually { camera.isPending }
        workflow.cancel()
        let failure = await workflowFailure { try await task.value }
        XCTAssertEqual(failure?.stage, .capture)
        XCTAssertEqual(failure?.code, .cancelled)
        XCTAssertTrue(camera.isPending, "Cancellation must finish without waiting for an uncooperative camera")

        camera.resume(value.snapshot)
        await eventually { workflow.inFlightWorkerCount == 0 }
        XCTAssertTrue(snapshots.isEmpty, "A cancelled shutter cannot replace the processing photo")
        let observed = await provider.observedSnapshots
        XCTAssertTrue(observed.isEmpty)
        XCTAssertEqual(phases, [.capturing, .cancelled])
        XCTAssertEqual(terminal.count, 1)
        XCTAssertEqual(terminal.first?.status, .cancelled)
        XCTAssertNil(terminal.first?.snapshot)
        XCTAssertNil(terminal.first?.timings.landmarksSeconds)
        XCTAssertNil(workflow.lastResult)
        XCTAssertEqual(workflow.phase, .cancelled)
    }

    private func assertSameSnapshot(_ actual: CaptureSnapshot?, _ expected: CaptureSnapshot,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let snapshot = try XCTUnwrap(actual, file: file, line: line)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Includes RGB bytes, raw/smoothed depths, confidence, calibration,
        // orientation, timestamps and the selector's original decision.
        XCTAssertEqual(try encoder.encode(snapshot), try encoder.encode(expected), file: file, line: line)
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

    private func workflowFailure(_ body: () async throws -> AutomaticMeasurementOutput,
                                 file: StaticString = #filePath, line: UInt = #line) async -> AutomaticMeasurementWorkflowFailure? {
        do {
            _ = try await body()
            XCTFail("Expected workflow failure", file: file, line: line)
        } catch let failure as AutomaticMeasurementWorkflowFailure {
            return failure
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
        return nil
    }
}

@MainActor
private final class CaptureFirstTimeline {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// Deliberately ignores cancellation so the workflow must reject late frames.
@MainActor
private final class CaptureFirstCamera: CaptureSnapshotProviding {
    let timeline: CaptureFirstTimeline
    private var continuation: CheckedContinuation<CaptureSnapshot, Error>?
    private(set) var orientations: [ImageOrientation] = []
    var isPending: Bool { continuation != nil }
    init(timeline: CaptureFirstTimeline) { self.timeline = timeline }

    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        orientations.append(orientation)
        timeline.record("capture.request")
        let snapshot: CaptureSnapshot = try await withCheckedThrowingContinuation { continuation = $0 }
        timeline.record("capture.returned")
        return snapshot
    }

    func resume(_ snapshot: CaptureSnapshot) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: snapshot)
    }
}

private enum CaptureFirstTestFailure: Error { case inference, invalidFrozenKind }

private actor CaptureFirstModel: GarmentMeasurementDefinitionProviding {
    let timeline: CaptureFirstTimeline
    private var continuation: CheckedContinuation<GarmentLandmarkSet, Error>?
    private(set) var observedSnapshots: [CaptureSnapshot] = []
    var isPending: Bool { continuation != nil }
    init(timeline: CaptureFirstTimeline) { self.timeline = timeline }

    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        observedSnapshots.append(snapshot)
        await timeline.record("inference")
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func succeed(_ points: GarmentLandmarkSet) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: points)
    }

    func fail() {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CaptureFirstTestFailure.inference)
    }

    nonisolated func measurementDefinitions(for landmarks: GarmentLandmarkSet) throws -> [MeasurementDefinition] {
        guard landmarks.garmentKind == .top,
              landmarks.modelVersion == AutomaticGarmentKind.top.modelVersion else {
            throw CaptureFirstTestFailure.invalidFrozenKind
        }
        return [.init(id: "top-captured-distance", title: "Captured top", landmarkIDs: ["A", "B"])]
    }
}

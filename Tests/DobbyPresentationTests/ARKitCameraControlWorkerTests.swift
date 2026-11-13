import ARKit
import AVFoundation
import Foundation
import SwiftUI
import XCTest
@testable import Dobby

/// Uses the actual SwiftUI camera-view factory without starting camera capture.
/// Simulator construction validates ownership, not physical camera readiness.
@MainActor
final class CameraPreviewConstructionTests: XCTestCase {
    func testPreviewKeepsCaptureSessionWithoutSelfDelegatingARKitCallbacks() {
        let session = ARSession()
        let preview = CameraPreview(session: session, readiness: .waiting, orientation: .constant(.right))
        let view = preview.makePreviewView()

        XCTAssertTrue(view.session === session)
        XCTAssertNil(view.delegate,
            "Self-delegating ARSCNView forwards inherited rotation callbacks back to itself and overflows the stack.")
    }
}

/// Exercises queue ownership and session lifetime without acquiring a camera.
/// Nil-device receipts cannot establish real autofocus or exposure settling.
@MainActor
final class ARKitCameraControlWorkerTests: XCTestCase {
    func testWideDeviceLimitsRestoredAndRequestedExposureToTwoStops() async throws {
        let device = ScriptedCameraDevice(capabilities: .init(focusSupported: true, meteringSupported: true,
            exposureRange: .init(minimum: -8, maximum: 8)))
        let worker = ARKitCameraControlWorker(), session = UUID()
        let capabilities = await worker.activate(sessionID: session, hardware: device, exposureBias: 7)
        XCTAssertEqual(capabilities.exposureRange, CameraExposureRange(minimum: -2, maximum: 2))
        XCTAssertEqual(device.observation().exposureTargetBias, 2)
        for (requested, expected) in [(-8.0, -2.0), (8.0, 2.0), (0.1, 0.1), (0.0, 0.0)] {
            let receipt = try await worker.exposure(requested, sessionID: session)
            XCTAssertEqual(receipt.exposureBias, expected)
            XCTAssertEqual(device.observation().exposureTargetBias, expected)
        }
        let restarted = UUID()
        _ = await worker.activate(sessionID: restarted, hardware: device, exposureBias: -7)
        let capture = try await worker.beginCapture(sessionID: restarted)
        XCTAssertEqual(capture.exposureBias, -2)
        XCTAssertEqual(device.observation().exposureTargetBias, -2)
        worker.endCapture(sessionID: restarted)
        worker.deactivate()
    }

    func testNarrowDeviceRangeStillLimitsExposureInsideTwoStops() async throws {
        let device = ScriptedCameraDevice(capabilities: .init(exposureRange: .init(minimum: -1, maximum: 1.5)))
        let worker = ARKitCameraControlWorker(), session = UUID()
        let capabilities = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        XCTAssertEqual(capabilities.exposureRange, CameraExposureRange(minimum: -1, maximum: 1.5))
        for (requested, expected) in [(-2.0, -1.0), (2.0, 1.5)] {
            let receipt = try await worker.exposure(requested, sessionID: session)
            XCTAssertEqual(receipt.exposureBias, expected)
            XCTAssertEqual(device.observation().exposureTargetBias, expected)
        }
        worker.deactivate()
    }

    private enum ExpectedFailure { case unavailable, busy, staleSession }

    private nonisolated final class CompletionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Result<CameraHardwareReceipt, Error>] = []

        func append(_ result: Result<CameraHardwareReceipt, Error>) {
            lock.withLock { stored.append(result) }
        }

        var results: [Result<CameraHardwareReceipt, Error>] {
            lock.withLock { stored }
        }
    }

    private func assertFailure(_ error: Error, expected: ExpectedFailure,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? CameraHardwareControlError else {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
            return
        }
        switch (expected, error) {
        case (.unavailable, .unavailable), (.busy, .busy), (.staleSession, .staleSession): break
        default: XCTFail("Wrong camera-control failure: \(error)", file: file, line: line)
        }
    }

    private func assertThrows(_ expected: ExpectedFailure,
                              file: StaticString = #filePath, line: UInt = #line,
                              operation: () async throws -> CameraHardwareReceipt) async {
        do {
            _ = try await operation()
            XCTFail("A rejected control must not produce a receipt.", file: file, line: line)
        } catch {
            assertFailure(error, expected: expected, file: file, line: line)
        }
    }

    func testMissingConfigurableDeviceDoesNotInventCapabilitiesOrBlockSnapshotBarrier() async throws {
        let worker = ARKitCameraControlWorker(), session = UUID()
        let capabilities = await worker.activate(sessionID: session, device: nil, exposureBias: 1.5)
        XCTAssertEqual(capabilities, .unavailable)
        XCTAssertFalse(capabilities.focusSupported)
        XCTAssertNil(capabilities.exposureRange)
        XCTAssertTrue(capabilities.availableZooms.isEmpty)

        let receipt = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(receipt.revision, 0)
        XCTAssertNil(receipt.focusPoint, "No autofocus request was accepted by a device.")
        XCTAssertEqual(receipt.exposureBias, 0, "An unsupported requested EV is not an accepted EV.")
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testMissingDeviceRejectsFocusAndExposureWithoutMutatingReceipt() async throws {
        let worker = ARKitCameraControlWorker(), session = UUID()
        _ = await worker.activate(sessionID: session, device: nil, exposureBias: 0)
        await assertThrows(.unavailable) {
            try await worker.focus(at: .init(x: 0.2, y: 0.7), sessionID: session)
        }
        await assertThrows(.unavailable) { try await worker.exposure(1, sessionID: session) }
        let receipt = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(receipt.revision, 0)
        XCTAssertNil(receipt.focusPoint)
        XCTAssertEqual(receipt.exposureBias, 0)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testShutterBarrierDrainsAlreadySubmittedCommandsAndTheirCompletions() async throws {
        let worker = ARKitCameraControlWorker(), session = UUID(), log = CompletionLog()
        _ = await worker.activate(sessionID: session, device: nil, exposureBias: 0)
        // Submit synchronously, as the provider does. Separate Swift tasks could
        // enter the queue after the shutter and would not test this ordering.
        worker.submitFocus(at: .init(x: 0.4, y: 0.3), sessionID: session) { log.append($0) }
        worker.submitExposure(0.5, sessionID: session) { log.append($0) }
        let receipt = try await worker.beginCapture(sessionID: session)

        let results = log.results
        XCTAssertEqual(results.count, 2, "Both prior commands must finish before the barrier returns.")
        for result in results {
            switch result {
            case .success: XCTFail("A nil-device command cannot be accepted.")
            case .failure(let error): assertFailure(error, expected: .unavailable)
            }
        }
        XCTAssertEqual(receipt.revision, 0)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testCaptureRejectsLaterControlsAndEndCaptureRestoresControlEligibility() async throws {
        let worker = ARKitCameraControlWorker(), session = UUID()
        _ = await worker.activate(sessionID: session, device: nil, exposureBias: 0)
        _ = try await worker.beginCapture(sessionID: session)
        await assertThrows(.busy) {
            try await worker.focus(at: .init(x: 0.5, y: 0.5), sessionID: session)
        }
        await assertThrows(.busy) { try await worker.exposure(0.5, sessionID: session) }

        worker.endCapture(sessionID: session)
        await assertThrows(.unavailable) { try await worker.exposure(0.5, sessionID: session) }
        worker.deactivate()
    }

    func testStaleGenerationCannotCaptureOrSubmitControls() async throws {
        let worker = ARKitCameraControlWorker(), current = UUID(), stale = UUID()
        _ = await worker.activate(sessionID: current, device: nil, exposureBias: 0)
        await assertThrows(.staleSession) { try await worker.beginCapture(sessionID: stale) }
        await assertThrows(.staleSession) {
            try await worker.focus(at: .init(x: 0.5, y: 0.5), sessionID: stale)
        }
        await assertThrows(.staleSession) { try await worker.exposure(0.5, sessionID: stale) }
        let receipt = try await worker.beginCapture(sessionID: current)
        XCTAssertEqual(receipt.revision, 0)
        worker.endCapture(sessionID: current)
        worker.deactivate()
    }

    func testDeactivateAndRestartIgnoreOldEndCaptureAndOldCommands() async throws {
        let worker = ARKitCameraControlWorker(), old = UUID(), current = UUID()
        _ = await worker.activate(sessionID: old, device: nil, exposureBias: 0)
        _ = try await worker.beginCapture(sessionID: old)
        worker.deactivate()
        await assertThrows(.staleSession) { try await worker.beginCapture(sessionID: old) }

        _ = await worker.activate(sessionID: current, device: nil, exposureBias: -1)
        let receipt = try await worker.beginCapture(sessionID: current)
        XCTAssertEqual(receipt.revision, 0)
        XCTAssertNil(receipt.focusPoint)
        XCTAssertEqual(receipt.exposureBias, 0)
        worker.endCapture(sessionID: old)
        await assertThrows(.staleSession) { try await worker.exposure(0.5, sessionID: old) }
        await assertThrows(.busy) { try await worker.exposure(0.5, sessionID: current) }
        worker.endCapture(sessionID: current)
        await assertThrows(.unavailable) { try await worker.exposure(0.5, sessionID: current) }
        worker.deactivate()
    }
}

/// Scripted hardware proves command/state semantics, not optical focus quality.
nonisolated private final class ScriptedCameraDevice: CameraHardwareDevice, @unchecked Sendable {
    private let lock = NSLock()
    let capabilities: CameraControlCapabilities
    init(capabilities: CameraControlCapabilities = .init(focusSupported: true, meteringSupported: true,
        aeafLockSupported: true, exposureRange: .init(minimum: -2, maximum: 2), availableZooms: [.standard])) {
        self.capabilities = capabilities
    }
    private var point: ImagePoint?
    private var stored = CameraHardwareObservation(observedAtUptime: 100,
        focusMode: .continuous, exposureMode: .continuous, isAdjustingFocus: false,
        isAdjustingExposure: false, lensPosition: 0.4, exposureDurationSeconds: 0.008, iso: 100, exposureTargetBias: 0)
    private var failBias = false
    var meteredPoint: ImagePoint? { lock.withLock { point } }

    func restoreAutomatic(exposureBias: Double) throws {
        lock.withLock {
            point = nil
            stored.focusMode = .continuous
            stored.exposureMode = .continuous
            stored.exposureTargetBias = exposureBias
        }
    }
    func focusAndMeter(at point: ImagePoint, lock wantsLock: Bool, resetExposureBias: Double?) throws {
        lock.withLock {
            self.point = point
            stored.focusMode = .single
            stored.exposureMode = wantsLock ? .single : .continuous
            stored.isAdjustingFocus = true
            stored.isAdjustingExposure = true
            if let resetExposureBias { stored.exposureTargetBias = resetExposureBias }
        }
    }
    func applyExposureBias(_ bias: Double) throws {
        try lock.withLock {
            if failBias { throw CameraHardwareControlError.configuration("scripted failure") }
            stored.exposureTargetBias = bias
        }
    }
    func controlObservation() -> CameraHardwareObservation {
        lock.withLock {
            var observation = stored
            observation.lensPosition = nil
            observation.exposureDurationSeconds = nil
            observation.iso = nil
            observation.exposureTargetBias = nil
            return observation
        }
    }
    func observation() -> CameraHardwareObservation { lock.withLock { stored } }
    func completeLock() {
        lock.withLock {
            stored.focusMode = .locked
            stored.exposureMode = .locked
            stored.isAdjustingFocus = false
            stored.isAdjustingExposure = false
        }
    }
    func completeExposureAdjustment() {
        lock.withLock { stored.isAdjustingExposure = false }
    }
    func completePointAdjustment() {
        lock.withLock {
            stored.focusMode = .locked
            stored.exposureMode = .continuous
            stored.isAdjustingFocus = false
            stored.isAdjustingExposure = false
        }
    }
    func rejectNextBias() { lock.withLock { failBias = true } }
}

@MainActor
final class CameraTapFocusSupportTests: XCTestCase {
    func testTapSelectsSingleAutofocusWhenAvailable() {
        XCTAssertEqual(CameraTapFocusMode.select(pointOfInterestSupported: true,
            singleSupported: true, continuousSupported: true), .autoFocus)
    }

    func testTapCanUseContinuousAutofocusWhenSingleModeIsUnavailable() {
        XCTAssertEqual(CameraTapFocusMode.select(pointOfInterestSupported: true,
            singleSupported: false, continuousSupported: true), .continuousAutoFocus)
    }

    func testTapRejectsFixedFocusOrMissingPointOfInterest() {
        XCTAssertNil(CameraTapFocusMode.select(pointOfInterestSupported: true,
            singleSupported: false, continuousSupported: false))
        XCTAssertNil(CameraTapFocusMode.select(pointOfInterestSupported: false,
            singleSupported: true, continuousSupported: true))
    }

    func testMeteringSupportCannotProduceAnAcceptedFocusReceipt() async throws {
        let hardware = ScriptedCameraDevice(capabilities: .init(focusSupported: false,
            meteringSupported: true, exposureRange: .init(minimum: -2, maximum: 2)))
        let worker = ARKitCameraControlWorker(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: hardware, exposureBias: 0)
        do {
            _ = try await worker.focus(at: .init(x: 0.25, y: 0.75), sessionID: session)
            XCTFail("Metering alone cannot accept an autofocus request.")
        } catch {
            guard case .unavailable? = error as? CameraHardwareControlError else {
                return XCTFail("Unexpected failure: \(error)")
            }
        }
        let receipt = try await worker.beginCapture(sessionID: session)
        XCTAssertNil(receipt.focusPoint)
        XCTAssertNil(hardware.meteredPoint)
        XCTAssertEqual(receipt.revision, 0)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testRecentTapIsProtectedEvenWhenExposureAdjustmentIsUnsupported() async throws {
        let hardware = ScriptedCameraDevice(capabilities: .init(focusSupported: true))
        let worker = ARKitCameraControlWorker(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: hardware, exposureBias: 0)
        let point = ImagePoint(x: 0.25, y: 0.75)
        _ = try await worker.focus(at: point, sessionID: session)
        hardware.completePointAdjustment()
        worker.subjectAreaChanged(sessionID: session)
        let receipt = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(receipt.focusPoint, point,
            "The grace period belongs to the AF tap even if there was no EV command.")
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testSubjectAreaNotificationCannotCancelAnAutofocusStillInProgress() async throws {
        let hardware = ScriptedCameraDevice(), worker = ARKitCameraControlWorker(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: hardware, exposureBias: 0)
        let point = ImagePoint(x: 0.25, y: 0.75)
        _ = try await worker.focus(at: point, sessionID: session)
        hardware.completeExposureAdjustment()
        // Pass the existing neutral-EV grace period so this exercises the
        // independent AF guard, rather than the exposure timing guard.
        try await Task.sleep(for: .milliseconds(200))
        worker.subjectAreaChanged(sessionID: session)
        let receipt = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(receipt.focusPoint, point)
        XCTAssertTrue(receipt.observation?.isAdjustingFocus == true)
        XCTAssertEqual(hardware.meteredPoint, point)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }
}

@MainActor
final class CameraLockLifecycleTests: XCTestCase {
    func testSceneChangeRestoresAutomaticAfterTapButPreservesExplicitLock() async throws {
        let device = ScriptedCameraDevice(), worker = ARKitCameraControlWorker(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0.5)
        _ = try await worker.focus(at: .init(x: 0.3, y: 0.4), sessionID: session)
        device.completePointAdjustment()
        // The tap now also submits neutral EV. A genuine later scene change
        // must occur after its existing 150 ms anti-recentering grace period.
        try await Task.sleep(for: .milliseconds(200))
        worker.subjectAreaChanged(sessionID: session)
        let automatic = try await worker.beginCapture(sessionID: session)
        XCTAssertNil(automatic.focusPoint)
        XCTAssertEqual(automatic.observation?.focusMode, .continuous)
        XCTAssertEqual(automatic.exposureBias, 0, "A short tap establishes a neutral exposure before later scene tracking.")
        worker.endCapture(sessionID: session)
        _ = try await worker.focus(at: .init(x: 0.8, y: 0.6), sessionID: session, lock: true)
        device.completeLock()
        worker.subjectAreaChanged(sessionID: session)
        let locked = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(locked.focusPoint, .init(x: 0.8, y: 0.6))
        XCTAssertEqual(locked.aeafStatus, .locked)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testTapMetersAtSameSensorPointAndUnlocksAnEarlierLock() async throws {
        let device = ScriptedCameraDevice(), worker = ARKitCameraControlWorker(), session = UUID()
        let caps = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        XCTAssertTrue(caps.aeafLockSupported && caps.meteringSupported)
        _ = try await worker.focus(at: .init(x: 0.2, y: 0.8), sessionID: session, lock: true)
        device.completeLock()
        let locked = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(locked.aeafStatus, .locked)
        worker.endCapture(sessionID: session)
        let tapped = try await worker.focus(at: .init(x: 0.7, y: 0.4), sessionID: session)
        XCTAssertEqual(device.meteredPoint, .init(x: 0.7, y: 0.4))
        XCTAssertEqual(tapped.focusPoint, device.meteredPoint)
        XCTAssertEqual(tapped.aeafStatus, .unlocked)
        XCTAssertNil(tapped.observation, "A tap acknowledges configuration without a synchronous camera poll.")
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(captured.observation?.exposureMode, .continuous)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testShutterDoesNotWaitForFocusOrExposureToSettle() async throws {
        let device = ScriptedCameraDevice(), worker = ARKitCameraControlWorker(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        let focus = try await worker.focus(at: .init(x: 0.4, y: 0.5), sessionID: session, lock: true)
        XCTAssertEqual(focus.aeafStatus, .locking)
        XCTAssertTrue(focus.observation?.isAdjustingFocus == true)
        let receipt = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(receipt.aeafStatus, .locking)
        XCTAssertFalse(receipt.observation?.hasObservedAEAFLock ?? true)
        XCTAssertEqual(receipt.revision, 1)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testExposureKeepsObservedLockAndRejectDoesNotInventAcceptedBias() async throws {
        let device = ScriptedCameraDevice(), worker = ARKitCameraControlWorker(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.focus(at: .init(x: 0.4, y: 0.5), sessionID: session, lock: true)
        device.completeLock()
        let exposed = try await worker.exposure(3, sessionID: session)
        XCTAssertEqual(exposed.exposureBias, 2)
        XCTAssertEqual(exposed.aeafStatus, .locked)
        XCTAssertEqual(exposed.observation?.exposureMode, .locked)
        device.rejectNextBias()
        do { _ = try await worker.exposure(-1, sessionID: session); XCTFail("Must reject failed hardware configuration") }
        catch { XCTAssertNotNil(error as? CameraHardwareControlError) }
        let receipt = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(receipt.exposureBias, 2)
        XCTAssertEqual(receipt.revision, exposed.revision, "A failed command must not invent an accepted configuration revision.")
        XCTAssertEqual(receipt.observation?.exposureTargetBias, 2)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testOldLockObservationCannotPublishIntoRestartedSession() async throws {
        let device = ScriptedCameraDevice(), worker = ARKitCameraControlWorker(), old = UUID(), current = UUID()
        let stale = expectation(description: "old observation must be discarded")
        stale.isInverted = true
        _ = await worker.activate(sessionID: old, hardware: device, exposureBias: 0) { _, _, _ in stale.fulfill() }
        _ = try await worker.focus(at: .init(x: 0.5, y: 0.5), sessionID: old, lock: true)
        worker.deactivate()
        _ = await worker.activate(sessionID: current, hardware: device, exposureBias: 0)
        device.completeLock()
        await fulfillment(of: [stale], timeout: 0.25)
        let receipt = try await worker.beginCapture(sessionID: current)
        XCTAssertEqual(receipt.revision, 0)
        XCTAssertNil(receipt.focusPoint)
        XCTAssertEqual(receipt.aeafStatus, .unlocked)
        worker.endCapture(sessionID: current)
        worker.deactivate()
    }
}

/// No first-buffer callback exists in this fake. isAdjustingExposure can stay
/// true indefinitely, independently of successfully accepting a target EV.
nonisolated private final class DirectExposureDevice: CameraHardwareDevice, @unchecked Sendable {
    enum Command: Equatable, Sendable {
        case restore(Double), focus(ImagePoint, Bool), exposure(Double)
    }
    private let lock = NSLock()
    private let supportedCapabilities = CameraControlCapabilities(focusSupported: true, meteringSupported: true,
        aeafLockSupported: true, exposureRange: .init(minimum: -2, maximum: 2), availableZooms: [.standard])
    private var commands: [Command] = []
    private var rejectsNextExposure = false
    private var rejectsNextFocus = false
    private var capabilitiesReads = 0
    private var controlReads = 0
    private var fullReads = 0
    private var nextExposureGate: DispatchSemaphore?
    private var nextExposureStarted: (@Sendable () -> Void)?
    private var nextFocusGate: DispatchSemaphore?
    private var nextFocusStarted: (@Sendable () -> Void)?
    private var observed = CameraHardwareObservation(observedAtUptime: 100,
        focusMode: .continuous, exposureMode: .continuous, isAdjustingFocus: false,
        isAdjustingExposure: false, lensPosition: 0.5, exposureDurationSeconds: 0.008, iso: 100, exposureTargetBias: 0)

    var recordedCommands: [Command] { lock.withLock { commands } }
    var capabilities: CameraControlCapabilities {
        lock.withLock { capabilitiesReads += 1; return supportedCapabilities }
    }
    var readCounts: (capabilities: Int, control: Int, full: Int) {
        lock.withLock { (capabilitiesReads, controlReads, fullReads) }
    }
    var exposureCommands: [Double] {
        recordedCommands.compactMap { if case .exposure(let bias) = $0 { bias } else { nil } }
    }
    func restoreAutomatic(exposureBias: Double) throws {
        lock.withLock {
            commands.append(.restore(exposureBias))
            observed.focusMode = .continuous
            observed.exposureMode = .continuous
            observed.exposureTargetBias = exposureBias
        }
    }
    func focusAndMeter(at point: ImagePoint, lock wantsLock: Bool, resetExposureBias: Double?) throws {
        let (gate, started) = try lock.withLock { () throws -> (DispatchSemaphore?, (@Sendable () -> Void)?) in
            if rejectsNextFocus {
                rejectsNextFocus = false
                throw CameraHardwareControlError.configuration("scripted focus failure")
            }
            commands.append(.focus(point, wantsLock))
            observed.focusMode = wantsLock ? .locked : .single
            observed.exposureMode = wantsLock ? .locked : .continuous
            if let resetExposureBias {
                commands.append(.exposure(resetExposureBias))
                observed.exposureTargetBias = resetExposureBias
            }
            let blocking = (nextFocusGate, nextFocusStarted)
            nextFocusGate = nil
            nextFocusStarted = nil
            return blocking
        }
        started?()
        gate?.wait()
    }
    func applyExposureBias(_ bias: Double) throws {
        let (gate, started) = try lock.withLock { () throws -> (DispatchSemaphore?, (@Sendable () -> Void)?) in
            if rejectsNextExposure {
                rejectsNextExposure = false
                throw CameraHardwareControlError.configuration("scripted exposure failure")
            }
            commands.append(.exposure(bias))
            observed.exposureTargetBias = bias
            let blocking = (nextExposureGate, nextExposureStarted)
            nextExposureGate = nil
            nextExposureStarted = nil
            return blocking
        }
        // Model a synchronous capture-service call without holding the fake's
        // state lock. Other threads can submit newer targets while it blocks.
        started?()
        gate?.wait()
    }
    func controlObservation() -> CameraHardwareObservation {
        lock.withLock {
            controlReads += 1
            var observation = observed
            observation.lensPosition = nil
            observation.exposureDurationSeconds = nil
            observation.iso = nil
            observation.exposureTargetBias = nil
            return observation
        }
    }
    func observation() -> CameraHardwareObservation {
        lock.withLock { fullReads += 1; return observed }
    }
    func blockNextExposure(until gate: DispatchSemaphore, onStart: @escaping @Sendable () -> Void) {
        lock.withLock { nextExposureGate = gate; nextExposureStarted = onStart }
    }
    func blockNextFocus(until gate: DispatchSemaphore, onStart: @escaping @Sendable () -> Void) {
        lock.withLock { nextFocusGate = gate; nextFocusStarted = onStart }
    }
    func rejectNextExposure() { lock.withLock { rejectsNextExposure = true } }
    func rejectNextFocus() { lock.withLock { rejectsNextFocus = true } }
    func setExposureAdjusting(_ adjusting: Bool) { lock.withLock { observed.isAdjustingExposure = adjusting } }
}

nonisolated private final class ExposureCompletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Result<CameraHardwareReceipt, Error>] = []
    func append(_ result: Result<CameraHardwareReceipt, Error>) { lock.withLock { stored.append(result) } }
    var results: [Result<CameraHardwareReceipt, Error>] { lock.withLock { stored } }
    var supersededCount: Int {
        results.filter {
            if case .failure(let error) = $0, let cameraError = error as? CameraHardwareControlError,
               case .superseded = cameraError { true } else { false }
        }.count
    }
}

/// Command delivery and observations only. These scripted tests do not prove
/// lens speed, camera sharpness, or parity with the system Camera app.
@MainActor
final class CameraFocusDeliveryTests: XCTestCase {
    func testTapsQueuedDuringSlowFocusApplyOnlyTheFirstAndNewestPoint() async throws {
        let worker = ARKitCameraControlWorker(), device = DirectExposureDevice(), session = UUID()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); worker.deactivate() }
        let entered = expectation(description: "first synchronous AF setter entered")
        let complete = expectation(description: "every focus request finishes once")
        complete.expectedFulfillmentCount = 4
        let log = ExposureCompletionLog()
        let points = [ImagePoint(x: 0.1, y: 0.2), .init(x: 0.3, y: 0.4),
                      .init(x: 0.5, y: 0.6), .init(x: 0.7, y: 0.8)]
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        device.blockNextFocus(until: gate) { entered.fulfill() }
        worker.submitFocus(at: points[0], sessionID: session) { log.append($0); complete.fulfill() }
        await fulfillment(of: [entered], timeout: 1)
        for point in points.dropFirst() {
            // Mirrors the provider's idempotent end-gesture call before taps.
            worker.setExposureAdjustmentActive(false, sessionID: session)
            worker.submitFocus(at: point, sessionID: session) { log.append($0); complete.fulfill() }
        }
        gate.signal()
        await fulfillment(of: [complete], timeout: 1)
        let commandsBeforeCapture = device.recordedCommands
        XCTAssertEqual(commandsBeforeCapture, [.restore(0), .focus(points[0], false), .exposure(0),
            .focus(points[3], false), .exposure(0)])
        XCTAssertEqual(log.supersededCount, 2)
        XCTAssertEqual(device.readCounts.control, 1, "Normal taps must not perform mode/adjusting polls.")
        XCTAssertEqual(device.readCounts.full, 0)
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(captured.focusPoint, points[3])
        XCTAssertEqual(captured.revision, 2)
        worker.endCapture(sessionID: session)
    }

    func testExposureAndExplicitLockAreOrderingBarriersBetweenFocusBursts() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); worker.deactivate() }
        let entered = expectation(description: "seed focus blocks the device queue")
        let log = ExposureCompletionLog()
        let seed = ImagePoint(x: 0.1, y: 0.2), beforeEV = ImagePoint(x: 0.3, y: 0.4)
        let locked = ImagePoint(x: 0.5, y: 0.6), skipped = ImagePoint(x: 0.6, y: 0.7)
        let latest = ImagePoint(x: 0.7, y: 0.8)
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        device.blockNextFocus(until: gate) { entered.fulfill() }
        worker.submitFocus(at: seed, sessionID: session) { log.append($0) }
        await fulfillment(of: [entered], timeout: 1)
        worker.submitFocus(at: beforeEV, sessionID: session) { log.append($0) }
        worker.submitExposure(0.7, sessionID: session) { log.append($0) }
        worker.submitFocus(at: locked, sessionID: session, lock: true) { log.append($0) }
        worker.submitFocus(at: skipped, sessionID: session) { log.append($0) }
        worker.submitFocus(at: latest, sessionID: session) { log.append($0) }
        gate.signal()
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(device.recordedCommands, [.restore(0), .focus(seed, false), .exposure(0),
            .focus(beforeEV, false), .exposure(0), .exposure(0.7), .focus(locked, true),
            .focus(latest, false), .exposure(0)])
        XCTAssertEqual(captured.focusPoint, latest)
        XCTAssertEqual(captured.exposureBias, 0)
        XCTAssertEqual(captured.revision, 5)
        XCTAssertEqual(log.results.count, 6)
        XCTAssertEqual(log.supersededCount, 1,
            "A tap after the EV/lock boundary must not replace a tap before that boundary.")
        XCTAssertEqual(device.readCounts.control, 2, "Activation and the explicit lock keep their observations.")
        worker.endCapture(sessionID: session)
    }

    func testShutterFlushesPendingFocusAndRejectsATapSubmittedAfterCaptureBegins() async throws {
        let worker = ARKitCameraControlWorker(), device = DirectExposureDevice(), session = UUID()
        let accepted = ExposureCompletionLog(), later = ExposureCompletionLog()
        let point = ImagePoint(x: 0.2, y: 0.7)
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        worker.submitFocus(at: point, sessionID: session) { accepted.append($0) }
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(captured.focusPoint, point)
        XCTAssertEqual(accepted.results.count, 1)
        XCTAssertNotNil(captured.observation, "Only capture reads full sensor facts for the photograph.")
        let rejected = expectation(description: "later tap rejected while capture owns the device")
        worker.submitFocus(at: .init(x: 0.8, y: 0.3), sessionID: session) { later.append($0); rejected.fulfill() }
        await fulfillment(of: [rejected], timeout: 1)
        guard case .failure(let error)? = later.results.first,
              case .busy? = error as? CameraHardwareControlError else {
            worker.endCapture(sessionID: session); worker.deactivate()
            return XCTFail("A later tap cannot overtake the shutter")
        }
        XCTAssertEqual(device.recordedCommands, [.restore(0), .focus(point, false), .exposure(0)])
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testSessionChangeCancelsPendingFocusWithoutApplyingItToEitherDevice() async throws {
        let worker = ARKitCameraControlWorker(), oldDevice = DirectExposureDevice(), newDevice = DirectExposureDevice()
        let old = UUID(), current = UUID(), gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); worker.deactivate() }
        let entered = expectation(description: "exposure blocks the old device before pending focus is admitted")
        let log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: old, hardware: oldDevice, exposureBias: 0)
        oldDevice.blockNextExposure(until: gate) { entered.fulfill() }
        worker.submitExposure(0.2, sessionID: old) { _ in }
        await fulfillment(of: [entered], timeout: 1)
        worker.submitFocus(at: .init(x: 0.3, y: 0.7), sessionID: old) { log.append($0) }
        worker.deactivate()
        gate.signal()
        _ = await worker.activate(sessionID: current, hardware: newDevice, exposureBias: 0)
        let captured = try await worker.beginCapture(sessionID: current)
        XCTAssertEqual(oldDevice.recordedCommands, [.restore(0), .exposure(0.2)])
        XCTAssertEqual(newDevice.recordedCommands, [.restore(0)])
        XCTAssertNil(captured.focusPoint)
        XCTAssertEqual(log.results.count, 1)
        guard case .failure(let error)? = log.results.first,
              case .staleSession? = error as? CameraHardwareControlError else {
            worker.endCapture(sessionID: current)
            return XCTFail("Every cancelled focus continuation must receive its stale-session result")
        }
        worker.endCapture(sessionID: current)
    }

    func testFailedPlainFocusDoesNotPollOrPreventANewerTapAndCapture() async throws {
        let worker = ARKitCameraControlWorker(), device = DirectExposureDevice(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        device.rejectNextFocus()
        do {
            _ = try await worker.focus(at: .init(x: 0.2, y: 0.7), sessionID: session)
            XCTFail("Scripted focus must fail")
        } catch {
            let failure = (error as? CameraHardwareControlError)?.focusFailureReceipt
            XCTAssertNotNil(failure)
            XCTAssertNil(failure?.observation)
            XCTAssertEqual(failure?.revision, 0)
        }
        let point = ImagePoint(x: 0.8, y: 0.3)
        let accepted = try await worker.focus(at: point, sessionID: session)
        XCTAssertNil(accepted.observation)
        XCTAssertEqual(device.readCounts.control, 1)
        XCTAssertEqual(device.readCounts.full, 0)
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(captured.focusPoint, point)
        XCTAssertEqual(captured.revision, 1)
        XCTAssertNotNil(captured.observation)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }
}

@MainActor
final class CameraFocusReceiptPresentationTests: XCTestCase {
    private func observation(uptime: Double, locked: Bool) -> CameraHardwareObservation {
        .init(observedAtUptime: uptime, focusMode: locked ? .locked : .single,
            exposureMode: locked ? .locked : .continuous, isAdjustingFocus: false,
            isAdjustingExposure: false, lensPosition: nil, exposureDurationSeconds: nil,
            iso: nil, exposureTargetBias: nil)
    }

    func testNeutralFocusReceiptPreservesAnAlreadyRequestedNewDrag() {
        var controls = CameraControlState()
        controls.focusStatus = .requested
        controls.exposureBias = 1.5
        controls.requestedExposureBias = 0.8
        controls.settingsRevision = 1
        let receipt = CameraHardwareReceipt(revision: 2, focusPoint: .init(x: 0.3, y: 0.7),
            exposureBias: 0, aeafStatus: .unlocked, observation: observation(uptime: 20, locked: false))
        let updated = controls.acceptingFocusReceipt(receipt, isCapturing: false)
        XCTAssertEqual(updated.exposureBias, 0)
        XCTAssertEqual(updated.requestedExposureBias, 0.8, "The focus receipt cannot move a newer drag's requested thumb value.")
        XCTAssertEqual(updated.settingsRevision, 2)
        XCTAssertEqual(updated.focusStatus, .accepted)
    }

    func testLateFocusReceiptCannotReplaceNewerAcceptedEVAndObservation() {
        var controls = CameraControlState()
        controls.exposureBias = 0.8
        controls.requestedExposureBias = 0.8
        controls.settingsRevision = 3
        controls.aeafStatus = .locked
        controls.hardwareObservation = observation(uptime: 30, locked: true)
        let receipt = CameraHardwareReceipt(revision: 2, focusPoint: .init(x: 0.3, y: 0.7),
            exposureBias: 0, aeafStatus: .unlocked, observation: observation(uptime: 20, locked: false))
        let updated = controls.acceptingFocusReceipt(receipt, isCapturing: true)
        XCTAssertEqual(updated.exposureBias, 0.8)
        XCTAssertEqual(updated.requestedExposureBias, 0.8)
        XCTAssertEqual(updated.settingsRevision, 3)
        XCTAssertEqual(updated.hardwareObservation, controls.hardwareObservation)
        XCTAssertEqual(updated.aeafStatus, .locked)
        XCTAssertEqual(updated.focusStatus, .idle)
    }

    func testSameRevisionFocusReceiptKeepsLaterObservedLockState() {
        var controls = CameraControlState()
        controls.settingsRevision = 2
        controls.aeafStatus = .locked
        controls.hardwareObservation = observation(uptime: 30, locked: true)
        let receipt = CameraHardwareReceipt(revision: 2, focusPoint: .init(x: 0.3, y: 0.7),
            exposureBias: 0, aeafStatus: .locking, observation: observation(uptime: 20, locked: false))
        let updated = controls.acceptingFocusReceipt(receipt, isCapturing: false)
        XCTAssertEqual(updated.aeafStatus, .locked)
        XCTAssertEqual(updated.hardwareObservation, controls.hardwareObservation)
    }

    func testFailedTapReconcilesFlushedEVAndRollsBackOnlyItsOwnNeutralRequest() {
        var controls = CameraControlState()
        controls.exposureBias = 0.4
        controls.requestedExposureBias = 0
        controls.settingsRevision = 1
        let receipt = CameraHardwareReceipt(revision: 2, focusPoint: nil, exposureBias: 1.5)
        let error = CameraHardwareControlError.focusConfiguration("scripted failure", receipt)
        let rolledBack = controls.reconcilingFailedFocus(error, lock: false, hasNewerExposureRequest: false)
        XCTAssertEqual(rolledBack.exposureBias, 1.5)
        XCTAssertEqual(rolledBack.requestedExposureBias, 1.5)
        XCTAssertEqual(rolledBack.settingsRevision, 2)
        XCTAssertEqual(rolledBack.focusStatus, .failed)

        controls.requestedExposureBias = -0.8
        let newerDrag = controls.reconcilingFailedFocus(error, lock: false, hasNewerExposureRequest: true)
        XCTAssertEqual(newerDrag.exposureBias, 1.5)
        XCTAssertEqual(newerDrag.requestedExposureBias, -0.8)

        controls.settingsRevision = 3
        controls.exposureBias = -0.8
        let newerAcceptedDrag = controls.reconcilingFailedFocus(error, lock: false, hasNewerExposureRequest: true)
        XCTAssertEqual(newerAcceptedDrag.exposureBias, -0.8)
        XCTAssertEqual(newerAcceptedDrag.settingsRevision, 3)
    }
}

@MainActor
final class CameraExposureDeliveryTests: XCTestCase {
    func testShortTapCancelsOldPendingEVAndResetsEVInsideItsFocusConfiguration() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let point = ImagePoint(x: 0.3, y: 0.7), pending = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.exposure(0.4, sessionID: session)
        worker.submitExposure(1.5, sessionID: session) { pending.append($0) }
        // The provider ends a possible gesture before each tap. An already
        // inactive gesture must not force an obsolete EV through hardware.
        worker.setExposureAdjustmentActive(false, sessionID: session)
        let focused = try await worker.focus(at: point, sessionID: session)
        let captured = try await worker.beginCapture(sessionID: session)

        XCTAssertEqual(device.recordedCommands, [.restore(0), .exposure(0.4), .focus(point, false), .exposure(0)])
        XCTAssertEqual(focused.exposureBias, 0)
        XCTAssertEqual(focused.revision, 2, "Neutral EV and AF are one configuration, with no obsolete EV submission.")
        XCTAssertEqual(focused.focusPoint, point)
        XCTAssertEqual(focused.aeafStatus, .unlocked)
        XCTAssertNil(focused.observation)
        XCTAssertEqual(captured.revision, focused.revision)
        XCTAssertEqual(captured.focusRequestID, focused.focusRequestID)
        XCTAssertEqual(captured.observation?.exposureTargetBias, 0)
        XCTAssertEqual(pending.results.count, 1)
        XCTAssertEqual(pending.supersededCount, 1)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testLongPressFlushesPendingExposureAndPreservesEVWhenLocking() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let point = ImagePoint(x: 0.3, y: 0.7), pending = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.exposure(0.4, sessionID: session)
        worker.submitExposure(1.5, sessionID: session) { pending.append($0) }
        let locked = try await worker.focus(at: point, sessionID: session, lock: true)
        let captured = try await worker.beginCapture(sessionID: session)

        XCTAssertEqual(device.recordedCommands, [.restore(0), .exposure(0.4), .exposure(1.5), .focus(point, true)])
        XCTAssertEqual(locked.exposureBias, 1.5)
        XCTAssertEqual(locked.revision, 3)
        XCTAssertEqual(locked.aeafStatus, .locked)
        XCTAssertEqual(captured.exposureBias, 1.5)
        XCTAssertEqual(captured.observation?.exposureTargetBias, 1.5)
        XCTAssertEqual(pending.results.count, 1)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testNewDragAfterShortTapWinsAtAnImmediateCaptureBarrier() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let point = ImagePoint(x: 0.2, y: 0.8), log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.exposure(1.2, sessionID: session)
        let focused = try await worker.focus(at: point, sessionID: session)
        worker.submitExposure(-0.8, sessionID: session) { log.append($0) }
        let captured = try await worker.beginCapture(sessionID: session)

        XCTAssertEqual(focused.exposureBias, 0)
        XCTAssertEqual(device.exposureCommands, [1.2, 0, -0.8])
        XCTAssertEqual(captured.exposureBias, -0.8)
        XCTAssertEqual(captured.revision, focused.revision + 1)
        XCTAssertEqual(captured.focusPoint, point)
        XCTAssertEqual(captured.focusRequestID, focused.focusRequestID)
        XCTAssertEqual(log.results.count, 1)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testFailedShortTapKeepsLastAcceptedEVWithoutApplyingTheCancelledDrag() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let pending = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.exposure(0.4, sessionID: session)
        worker.submitExposure(1.5, sessionID: session) { pending.append($0) }
        device.rejectNextFocus()
        var failedReceipt: CameraHardwareReceipt?
        do {
            _ = try await worker.focus(at: .init(x: 0.3, y: 0.7), sessionID: session)
            XCTFail("The scripted AF/AE configuration must fail")
        } catch {
            failedReceipt = (error as? CameraHardwareControlError)?.focusFailureReceipt
        }
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertNotNil(failedReceipt)
        XCTAssertEqual(failedReceipt?.exposureBias, 0.4)
        XCTAssertEqual(failedReceipt?.revision, 1)
        XCTAssertNil(failedReceipt?.focusPoint)
        XCTAssertNil(failedReceipt?.focusRequestID)
        XCTAssertNil(failedReceipt?.observation)
        XCTAssertEqual(device.exposureCommands, [0.4], "Neither a cancelled drag nor a failed neutral reset reached hardware.")
        XCTAssertEqual(captured.exposureBias, 0.4)
        XCTAssertEqual(captured.revision, 1)
        XCTAssertEqual(device.readCounts.control, 1)
        XCTAssertEqual(pending.results.count, 1)
        XCTAssertEqual(pending.supersededCount, 1)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testShortTapResetsExposureAgainAtTheSameSensorPoint() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let point = ImagePoint(x: 0.4, y: 0.6)
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        let firstTap = try await worker.focus(at: point, sessionID: session)
        // The capture barrier applies the later EV without waiting out cadence.
        worker.submitExposure(1.3, sessionID: session) { _ in }
        _ = try await worker.beginCapture(sessionID: session)
        worker.endCapture(sessionID: session)
        let secondTap = try await worker.focus(at: point, sessionID: session)
        XCTAssertEqual(device.exposureCommands, [0, 1.3, 0])
        XCTAssertEqual(secondTap.exposureBias, 0)
        XCTAssertEqual(secondTap.revision, firstTap.revision + 2)
        XCTAssertNotEqual(secondTap.focusRequestID, firstTap.focusRequestID)
        worker.deactivate()
    }

    func testUnlockedExposureAvoidsSynchronousObservationsAndCaptureObtainsFreshMetadata() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        XCTAssertEqual(device.readCounts.capabilities, 1)
        let initialControlReads = device.readCounts.control
        XCTAssertEqual(device.readCounts.full, 0)

        let first = try await worker.exposure(0.4, sessionID: session)
        XCTAssertNil(first.observation,
            "An unlocked EV receipt must neither poll hardware nor re-date its activation observation.")
        XCTAssertEqual(device.readCounts.control, initialControlReads)
        XCTAssertEqual(device.readCounts.full, 0)

        let log = ExposureCompletionLog()
        worker.submitExposure(0.8, sessionID: session) { log.append($0) }
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(device.readCounts.capabilities, 1, "Static device capabilities stay cached.")
        XCTAssertEqual(device.readCounts.control, initialControlReads,
            "Barrier-flushed EV also avoids mode/adjusting getters; capture owns its separate full observation.")
        XCTAssertEqual(device.readCounts.full, 1)
        XCTAssertEqual(device.exposureCommands, [0.4, 0.8])
        XCTAssertEqual(captured.exposureBias, 0.8)
        XCTAssertEqual(captured.observation?.lensPosition, 0.5)
        XCTAssertEqual(captured.observation?.exposureDurationSeconds, 0.008)
        XCTAssertEqual(captured.observation?.iso, 100)
        XCTAssertEqual(captured.observation?.exposureTargetBias, 0.8)
        guard case .success(let flushed)? = log.results.first else {
            worker.endCapture(sessionID: session); worker.deactivate()
            return XCTFail("The latest EV must complete before capture metadata is read")
        }
        XCTAssertNil(flushed.observation,
            "A fresh capture observation must not leak backward into a preceding EV command receipt.")
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testPlainFocusAndExposureAvoidModePollsWhilePreservingTheSameFocusRequest() async throws {
        let worker = ARKitCameraControlWorker(), device = DirectExposureDevice(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        let focus = try await worker.focus(at: .init(x: 0.3, y: 0.7), sessionID: session)
        XCTAssertNil(focus.observation, "Plain focus acknowledges the command without synchronously polling the camera.")
        let controlReadsAfterFocus = device.readCounts.control
        XCTAssertEqual(controlReadsAfterFocus, 1, "Only activation obtained a control observation.")
        let exposure = try await worker.exposure(0.8, sessionID: session)
        XCTAssertNil(exposure.observation)
        XCTAssertEqual(device.readCounts.control, controlReadsAfterFocus)
        XCTAssertEqual(device.readCounts.full, 0)
        XCTAssertEqual(exposure.focusPoint, focus.focusPoint)
        XCTAssertEqual(exposure.focusRequestID, focus.focusRequestID)
        worker.deactivate()
    }

    func testTargetsQueuedDuringSlowSetterCoalesceBeforeTheNextHardwareSubmission() async throws {
        let worker = ARKitCameraControlWorker(), device = DirectExposureDevice(), session = UUID()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); worker.deactivate() }
        let firstEntered = expectation(description: "first synchronous device setter entered")
        let completed = expectation(description: "all accepted or superseded requests complete")
        completed.expectedFulfillmentCount = 4
        let log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        device.blockNextExposure(until: gate) { firstEntered.fulfill() }
        worker.submitExposure(0.2, sessionID: session) { log.append($0); completed.fulfill() }
        await fulfillment(of: [firstEntered], timeout: 1)
        for target in [0.6, -0.4, 1.2] {
            worker.submitExposure(target, sessionID: session) { log.append($0); completed.fulfill() }
        }
        // Longer than the default cadence: obsolete queued inputs must still
        // coalesce after a slow synchronous setter, rather than each replaying.
        try await Task.sleep(for: .milliseconds(40))
        gate.signal()
        await fulfillment(of: [completed], timeout: 1)
        let commandsBeforeBarrier = device.exposureCommands
        let completionsBeforeBarrier = log.results.count
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(commandsBeforeBarrier, [0.2, 1.2],
            "Only the latest of the targets queued during the blocked setter reaches hardware, including direction reversals.")
        XCTAssertEqual(completionsBeforeBarrier, 4, "A later capture flush must not hide a stalled delivery.")
        XCTAssertEqual(log.supersededCount, 2)
        XCTAssertEqual(captured.exposureBias, 1.2)
        XCTAssertEqual(captured.revision, 2)
        XCTAssertEqual(device.readCounts.control, 1,
            "Slow setters must not acquire additional synchronous observations between coalesced targets.")
        worker.endCapture(sessionID: session)
    }

    func testFirstTargetIsAcceptedImmediatelyDespiteLongCadenceWithoutCaptureFlush() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let accepted = expectation(description: "first complete target accepted without a timer or applied-frame callback")
        let log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        worker.submitExposure(1.5, sessionID: session) { log.append($0); accepted.fulfill() }
        await fulfillment(of: [accepted], timeout: 1)
        // Record BEFORE the barrier so a flush cannot hide a delayed first
        // request. Still flush afterwards to clean up even if this test fails.
        let commandsBeforeBarrier = device.exposureCommands
        let completionsBeforeBarrier = log.results
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(commandsBeforeBarrier, [1.5], "The actual target must be sent, with no intermediate software ramp.")
        XCTAssertEqual(completionsBeforeBarrier.count, 1)
        guard case .success(let receipt)? = completionsBeforeBarrier.first else {
            worker.endCapture(sessionID: session); worker.deactivate()
            return XCTFail("First command must complete before capture flush")
        }
        XCTAssertEqual(receipt.exposureBias, 1.5)
        XCTAssertEqual(captured.exposureBias, 1.5)
        XCTAssertEqual(captured.revision, 1)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testUnsettledSensorExposureDoesNotBlockLaterTargetsOrCapture() async throws {
        let worker = ARKitCameraControlWorker(), device = DirectExposureDevice(), session = UUID()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        device.setExposureAdjusting(true)
        let firstAccepted = expectation(description: "first target accepted while AE keeps adjusting")
        let firstLog = ExposureCompletionLog()
        worker.submitExposure(0.4, sessionID: session) { firstLog.append($0); firstAccepted.fulfill() }
        await fulfillment(of: [firstAccepted], timeout: 1)
        let firstBeforeLaterRequest = firstLog.results
        let accepted = expectation(description: "next target accepted while AE remains adjusting")
        let log = ExposureCompletionLog()
        worker.submitExposure(-1.2, sessionID: session) { log.append($0); accepted.fulfill() }
        await fulfillment(of: [accepted], timeout: 1)
        let commandsBeforeBarrier = device.exposureCommands
        let completionsBeforeBarrier = log.results
        let captured = try await worker.beginCapture(sessionID: session)
        if case .success(let first)? = firstBeforeLaterRequest.first {
            XCTAssertEqual(first.exposureBias, 0.4)
            XCTAssertNil(first.observation, "A command receipt does not poll or claim sensor AE convergence.")
        } else { XCTFail("A sensor that stays adjusting must not prevent the first command receipt.") }
        XCTAssertEqual(commandsBeforeBarrier, [0.4, -1.2])
        XCTAssertEqual(completionsBeforeBarrier.count, 1)
        XCTAssertEqual(captured.exposureBias, -1.2)
        XCTAssertTrue(captured.observation?.isAdjustingExposure == true,
            "Accepting a command and permitting capture must not claim AE has settled.")
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testBurstSendsFirstAndLatestTargetAndCompletesEverySupersededRequest() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        let first = try await worker.exposure(0.01, sessionID: session)
        log.append(.success(first))
        for index in 2...100 {
            worker.submitExposure(Double(index) / 100, sessionID: session) { log.append($0) }
        }
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(device.exposureCommands, [0.01, 1], "After the accepted first input, obsolete queued settings must not replay.")
        XCTAssertEqual(captured.exposureBias, 1)
        XCTAssertEqual(captured.revision, 2)
        XCTAssertEqual(log.results.count, 100)
        XCTAssertEqual(log.supersededCount, 98)
        guard case .success(let completed)? = log.results.last else { return XCTFail("Latest target must be accepted at the barrier") }
        XCTAssertEqual(completed.exposureBias, 1)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testFocusIsAnOrderingBoundaryBetweenDirectExposureBursts() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let log = ExposureCompletionLog(), point = ImagePoint(x: 0.3, y: 0.7)
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        log.append(.success(try await worker.exposure(0.2, sessionID: session)))
        worker.submitExposure(0.6, sessionID: session) { log.append($0) }
        _ = try await worker.focus(at: point, sessionID: session, lock: true)
        worker.submitExposure(-0.4, sessionID: session) { log.append($0) }
        worker.submitExposure(-0.8, sessionID: session) { log.append($0) }
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(device.recordedCommands, [.restore(0), .exposure(0.2), .exposure(0.6), .focus(point, true), .exposure(-0.8)])
        XCTAssertEqual(log.results.count, 4)
        XCTAssertEqual(log.supersededCount, 1)
        XCTAssertEqual(captured.exposureBias, -0.8)
        XCTAssertEqual(captured.focusPoint, point)
        XCTAssertEqual(captured.aeafStatus, .locked)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testReturningToAlreadyAcceptedValueCancelsAnObsoletePendingTarget() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.exposure(0.4, sessionID: session)
        worker.submitExposure(1.2, sessionID: session) { log.append($0) }
        worker.submitExposure(0.4, sessionID: session) { log.append($0) }
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(device.exposureCommands, [0.4])
        XCTAssertEqual(captured.exposureBias, 0.4)
        XCTAssertEqual(captured.revision, 1)
        XCTAssertEqual(log.results.count, 2)
        XCTAssertEqual(log.supersededCount, 1)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testDeactivateCompletesPendingTargetStaleAndNewSessionDoesNotReceiveIt() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), oldDevice = DirectExposureDevice(), old = UUID(), current = UUID()
        let log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: old, hardware: oldDevice, exposureBias: 0)
        _ = try await worker.exposure(0.2, sessionID: old)
        worker.submitExposure(1.5, sessionID: old) { log.append($0) }
        worker.deactivate()
        let newDevice = DirectExposureDevice()
        _ = await worker.activate(sessionID: current, hardware: newDevice, exposureBias: -0.4)
        guard case .failure(let error)? = log.results.first, let cameraError = error as? CameraHardwareControlError,
              case .staleSession = cameraError else {
            worker.deactivate()
            return XCTFail("The old pending request must finish with a stale-session failure")
        }
        let captured = try await worker.beginCapture(sessionID: current)
        XCTAssertEqual(log.results.count, 1)
        XCTAssertEqual(oldDevice.exposureCommands, [0.2])
        XCTAssertEqual(newDevice.recordedCommands, [.restore(-0.4)])
        XCTAssertEqual(captured.exposureBias, -0.4)
        XCTAssertEqual(captured.revision, 0)
        XCTAssertNil(captured.focusPoint)
        worker.endCapture(sessionID: current)
        worker.deactivate()
    }

    func testActiveExposureGestureProtectsItsMeteringPointAfterTheGracePeriod() async throws {
        let worker = ARKitCameraControlWorker(), device = DirectExposureDevice(), session = UUID()
        let point = ImagePoint(x: 0.2, y: 0.7)
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.focus(at: point, sessionID: session)
        worker.setExposureAdjustmentActive(true, sessionID: session)
        // No pending EV and no sensor adjustment remain: the active gesture
        // itself must protect the selected subject while the finger is still.
        try await Task.sleep(for: .milliseconds(200))
        worker.subjectAreaChanged(sessionID: session)
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(captured.focusPoint, point)
        XCTAssertEqual(device.recordedCommands.filter { if case .restore = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(device.readCounts.control, 1,
            "Neither a plain tap nor an ignored scene notification may poll during the active drag.")
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testEndingExposureGestureFlushesItsFinalValueWithoutACaptureOrCadenceWait() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let complete = expectation(description: "both final and superseded drag requests complete at gesture end")
        complete.expectedFulfillmentCount = 2
        let log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.exposure(0.4, sessionID: session)
        worker.setExposureAdjustmentActive(true, sessionID: session)
        worker.submitExposure(1.2, sessionID: session) { log.append($0); complete.fulfill() }
        worker.submitExposure(1.6, sessionID: session) { log.append($0); complete.fulfill() }
        worker.setExposureAdjustmentActive(false, sessionID: session)
        await fulfillment(of: [complete], timeout: 1)
        // Assert before a shutter can hide a missing final-gesture flush.
        XCTAssertEqual(device.exposureCommands, [0.4, 1.6])
        XCTAssertEqual(log.supersededCount, 1)
        XCTAssertEqual(log.results.count, 2)
        XCTAssertEqual(device.readCounts.control, 1)
        XCTAssertEqual(device.readCounts.full, 0)
        guard case .success(let final)? = log.results.last else {
            worker.deactivate()
            return XCTFail("The final target must be delivered at the gesture boundary")
        }
        XCTAssertEqual(final.exposureBias, 1.6)
        XCTAssertNil(final.observation)
        worker.deactivate()
    }

    func testImmediateCaptureFlushesLatestEVAndClearsTheExposureGesture() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let point = ImagePoint(x: 0.2, y: 0.7), log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.focus(at: point, sessionID: session)
        worker.setExposureAdjustmentActive(true, sessionID: session)
        worker.submitExposure(0.6, sessionID: session) { log.append($0) }
        worker.submitExposure(1.4, sessionID: session) { log.append($0) }
        device.setExposureAdjusting(true)
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(captured.exposureBias, 1.4)
        XCTAssertEqual(captured.focusPoint, point)
        XCTAssertTrue(captured.observation?.isAdjustingExposure == true,
            "Capture remains immediate even when sensor AE has not settled.")
        XCTAssertEqual(device.exposureCommands, [0, 1.4])
        XCTAssertEqual(log.results.count, 2)
        worker.endCapture(sessionID: session)
        device.setExposureAdjusting(false)
        try await Task.sleep(for: .milliseconds(200))
        worker.subjectAreaChanged(sessionID: session)
        let subsequentCapture = try await worker.beginCapture(sessionID: session)
        XCTAssertNil(subsequentCapture.focusPoint,
            "A capture must release the drag lifetime even if the finger-up event never arrives.")
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testRestartClearsExposureGestureAndIgnoresStaleGestureUpdates() async throws {
        let worker = ARKitCameraControlWorker(), old = UUID(), current = UUID()
        let oldDevice = DirectExposureDevice(), device = DirectExposureDevice()
        _ = await worker.activate(sessionID: old, hardware: oldDevice, exposureBias: 0)
        worker.setExposureAdjustmentActive(true, sessionID: old)
        worker.deactivate()
        _ = await worker.activate(sessionID: current, hardware: device, exposureBias: 0)
        _ = try await worker.focus(at: .init(x: 0.2, y: 0.7), sessionID: current)
        worker.setExposureAdjustmentActive(true, sessionID: old)
        try await Task.sleep(for: .milliseconds(200))
        worker.subjectAreaChanged(sessionID: current)
        let captured = try await worker.beginCapture(sessionID: current)
        XCTAssertNil(captured.focusPoint,
            "Neither the preceding session's active drag nor its late callbacks may affect the new session.")
        XCTAssertEqual(device.recordedCommands.filter { if case .restore = $0 { true } else { false } }.count, 2)
        worker.endCapture(sessionID: current)
        worker.deactivate()
    }

    func testDelayedSceneNotificationDoesNotReMeterWhileSensorIsStillAdjustingAfterGrace() async throws {
        let worker = ARKitCameraControlWorker(), device = DirectExposureDevice(), session = UUID()
        let point = ImagePoint(x: 0.2, y: 0.7)
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        _ = try await worker.focus(at: point, sessionID: session)
        _ = try await worker.exposure(1.5, sessionID: session)
        device.setExposureAdjusting(true)
        // Deliberately exceed the 150ms request/command grace. The remaining
        // protection must be the actual device observation, not a hidden wait.
        try await Task.sleep(for: .milliseconds(200))
        worker.subjectAreaChanged(sessionID: session)
        let adjustingCapture = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(adjustingCapture.focusPoint, point)
        XCTAssertTrue(adjustingCapture.observation?.isAdjustingExposure == true)
        XCTAssertEqual(device.recordedCommands.filter { if case .restore = $0 { true } else { false } }.count, 1)
        worker.endCapture(sessionID: session)
        device.setExposureAdjusting(false)
        worker.subjectAreaChanged(sessionID: session)
        let settledCapture = try await worker.beginCapture(sessionID: session)
        XCTAssertNil(settledCapture.focusPoint, "A later genuine scene change may restore automatic metering after AE finishes.")
        XCTAssertEqual(device.recordedCommands.filter { if case .restore = $0 { true } else { false } }.count, 2)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testIntentionalExposureAdjustmentKeepsAnAlreadyObservedAEAFLockWithoutSettlingGate() async throws {
        let worker = ARKitCameraControlWorker(), device = DirectExposureDevice(), session = UUID()
        let noFalseLockError = expectation(description: "no false lock failure")
        noFalseLockError.isInverted = true
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0) { _, _, error in
            if case .lockNotSettled? = error { noFalseLockError.fulfill() }
        }
        let locked = try await worker.focus(at: .init(x: 0.4, y: 0.6), sessionID: session, lock: true)
        XCTAssertEqual(locked.aeafStatus, .locked)
        device.setExposureAdjusting(true)
        let accepted = try await worker.exposure(1, sessionID: session)
        XCTAssertEqual(accepted.exposureBias, 1)
        XCTAssertEqual(device.exposureCommands, [1])
        await fulfillment(of: [noFalseLockError], timeout: 0.15)
        let captured = try await worker.beginCapture(sessionID: session)
        XCTAssertEqual(captured.aeafStatus, .locked)
        XCTAssertTrue(captured.observation?.isAdjustingExposure == true)
        XCTAssertFalse(captured.observation?.hasObservedAEAFLock ?? true,
            "Accepting EV does not turn an adjusting sensor observation into a settled one.")
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }

    func testFailedDirectTargetReturnsLastAcceptedReceiptAndKeepsCaptureAvailable() async throws {
        let worker = ARKitCameraControlWorker(exposureCadence: 10), device = DirectExposureDevice(), session = UUID()
        let log = ExposureCompletionLog()
        _ = await worker.activate(sessionID: session, hardware: device, exposureBias: 0)
        let first = try await worker.exposure(0.6, sessionID: session)
        device.rejectNextExposure()
        worker.submitExposure(1.5, sessionID: session) { log.append($0) }
        let captured = try await worker.beginCapture(sessionID: session)
        guard case .failure(let error)? = log.results.first,
              let failed = (error as? CameraHardwareControlError)?.exposureFailureReceipt else {
            worker.endCapture(sessionID: session); worker.deactivate()
            return XCTFail("Failure must carry the last accepted command receipt in the same completion")
        }
        XCTAssertEqual(log.results.count, 1)
        XCTAssertEqual(device.exposureCommands, [0.6])
        XCTAssertEqual(failed.exposureBias, first.exposureBias)
        XCTAssertEqual(failed.revision, first.revision)
        XCTAssertNil(failed.observation,
            "A failed unlocked EV must not poll hardware or attach a stale observation.")
        XCTAssertEqual(device.readCounts.control, 1)
        XCTAssertEqual(device.readCounts.capabilities, 1)
        XCTAssertEqual(device.readCounts.full, 1, "The only full observation is the subsequent capture barrier.")
        XCTAssertEqual(captured.exposureBias, failed.exposureBias)
        XCTAssertEqual(captured.revision, failed.revision)
        worker.endCapture(sessionID: session)
        worker.deactivate()
    }
}

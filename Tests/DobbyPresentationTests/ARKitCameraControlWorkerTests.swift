import Foundation
import XCTest
@testable import Dobby

/// Exercises queue ownership and session lifetime without acquiring a camera.
/// Nil-device receipts cannot establish real autofocus or exposure settling.
@MainActor
final class ARKitCameraControlWorkerTests: XCTestCase {
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

// Created by mason on 10/21/26.
import XCTest
@testable import Dobby

@MainActor
final class DetailCameraOptionsRegressionTests: XCTestCase {
    func testDragCoalescesWaitingValuesAndInvalidationClearsQueue() async {
        let first = expectation(description: "first"), latest = expectation(description: "latest")
        let driver = SuspendedExposureControls(started: [first, latest])
        let model = DetailCameraOptions(controller: driver)
        await model.refreshCapabilities()
        model.requestExposure(0.25)
        await fulfillment(of: [first], timeout: 2)
        model.requestExposure(0.5)
        model.requestExposure(1)
        await driver.finish(0.25, returning: 0.25)
        await fulfillment(of: [latest], timeout: 2)
        let received = await driver.received
        XCTAssertEqual(received, [0.25, 1])
        model.requestExposure(-1)
        model.invalidate()
        await driver.finish(1, returning: 1)
        XCTAssertNil(model.appliedExposure)
        XCTAssertFalse(model.isApplying)
    }

    func testOlderExposureCompletionCannotReplaceLatestRequest() async {
        let first = expectation(description: "first"), second = expectation(description: "second")
        let driver = SuspendedExposureControls(started: [first, second])
        let model = DetailCameraOptions(controller: driver)
        await model.refreshCapabilities()
        let older = Task { await model.apply(.exposure(0.5)) }
        await fulfillment(of: [first], timeout: 2)
        let latest = Task { await model.apply(.exposure(1)) }
        await fulfillment(of: [second], timeout: 2)
        await driver.finish(0.5, returning: 0.5)
        await older.value
        XCTAssertTrue(model.isApplying)
        XCTAssertEqual(model.requested, .exposure(1))
        XCTAssertEqual(model.appliedExposure, 0)
        await driver.finish(1, returning: 0.75)
        await latest.value
        XCTAssertEqual(model.appliedExposure, 0.75)
        XCTAssertFalse(model.isApplying)
    }

    func testCancelledRequestIgnoresSuccessAndAllowsRetry() async {
        let first = expectation(description: "cancel"), second = expectation(description: "retry")
        let driver = SuspendedExposureControls(started: [first, second])
        let model = DetailCameraOptions(controller: driver)
        await model.refreshCapabilities()
        model.photoAspectRatio = .sixteenNine
        let cancelled = Task { await model.apply(.exposure(0.5)) }
        await fulfillment(of: [first], timeout: 2)
        cancelled.cancel()
        await driver.finish(0.5, returning: 0.5)
        await cancelled.value
        XCTAssertEqual(model.appliedExposure, 0)
        XCTAssertFalse(model.isApplying)
        XCTAssertNil(model.failure)
        let retry = Task { await model.resetExposure() }
        await fulfillment(of: [second], timeout: 2)
        await driver.finish(0, returning: 0)
        await retry.value
        XCTAssertEqual(model.requested, .exposure(0))
        XCTAssertEqual(model.photoAspectRatio, .sixteenNine)
        XCTAssertFalse(model.isApplying)
    }

    func testInvalidDeviceValuesPreservePreviouslyAppliedExposure() async {
        for invalid in [Double.nan, .infinity, -2, 2] {
            let model = DetailCameraOptions(controller: InvalidExposureControls(value: invalid))
            await model.refreshCapabilities()
            await model.apply(.exposure(0.5))
            XCTAssertEqual(model.failure, .deviceFailure)
            XCTAssertEqual(model.appliedExposure, 0)
            XCTAssertFalse(model.isApplying)
        }
    }
}

private actor SuspendedExposureControls: DetailCameraControlling {
    private(set) var received: [Double] = []
    private var started: [XCTestExpectation]
    private var pending: [Double: CheckedContinuation<Double, Error>] = [:]
    init(started: [XCTestExpectation]) { self.started = started }
    func capabilities() async throws -> DetailCameraCapabilities {
        .init(exposure: .init(minimum: -1, maximum: 1), exposureBias: 0)
    }
    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        guard case .exposure(let value) = request else { throw DetailCameraControlFailure.unsupported }
        return try await withCheckedThrowingContinuation {
            received.append(value)
            pending[value] = $0
            started.removeFirst().fulfill()
        }
    }
    func finish(_ value: Double, returning applied: Double) {
        pending.removeValue(forKey: value)?.resume(returning: applied)
    }
}

private struct InvalidExposureControls: DetailCameraControlling {
    let value: Double
    func capabilities() async throws -> DetailCameraCapabilities {
        .init(exposure: .init(minimum: -1, maximum: 1), exposureBias: 0)
    }
    func apply(_ request: DetailCameraControlRequest) async throws -> Double { value }
}

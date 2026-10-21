// Created by mason on 10/21/26.
import XCTest
@testable import Dobby

@MainActor
final class DetailCameraOptionsTests: XCTestCase {
    func testUnsupportedDefaultsDoNotInventAppliedValuesOrCrop() async {
        let model = DetailCameraOptions()
        await model.refreshCapabilities()
        await model.apply(.exposure(1))
        XCTAssertEqual(model.failure, .unsupported)
        XCTAssertNil(model.appliedExposure)
        XCTAssertNil(model.appliedZoom)
        XCTAssertNil(model.photoAspectRatio)
    }
    func testLimitsRejectInvalidRangesAndValues() {
        XCTAssertNil(DetailCameraControlRange(minimum: .nan, maximum: 2))
        XCTAssertNil(DetailCameraControlRange(minimum: 2, maximum: 1))
        let range = DetailCameraControlRange(minimum: -1, maximum: 1)!
        XCTAssertNil(range.clamped(.infinity))
        XCTAssertEqual(range.clamped(-2), -1)
        XCTAssertEqual(range.clamped(2), 1)
    }
    func testRequestedValueDiffersFromClampedRequestAndAppliedValue() async {
        let driver = DeferredDetailControls()
        let subject = DetailCameraOptions(controller: driver)
        await subject.refreshCapabilities()
        let task = Task { await subject.apply(.exposure(3)) }
        await driver.waitForRequest()
        XCTAssertTrue(subject.isApplying)
        await subject.apply(.exposure(.nan))
        XCTAssertEqual(subject.failure, .invalidValue)
        XCTAssertTrue(subject.isApplying, "잘못된 입력이 진행 중인 정상 요청을 해제하면 안 됩니다.")
        XCTAssertEqual(subject.requested, .exposure(3))
        let received = await driver.received
        XCTAssertEqual(received, .exposure(1))
        await driver.complete(0.75)
        await task.value
        XCTAssertEqual(subject.appliedExposure, 0.75)
        await subject.apply(.exposure(.nan))
        XCTAssertEqual(subject.failure, .invalidValue)
        XCTAssertEqual(subject.appliedExposure, 0.75)
    }
    func testInvalidationDiscardsLateCompletionAndPreservesRatioChoice() async {
        let driver = DeferredDetailControls()
        let subject = DetailCameraOptions(controller: driver)
        await subject.refreshCapabilities()
        subject.photoAspectRatio = .square
        let task = Task { await subject.apply(.exposure(0.5)) }
        await driver.waitForRequest()
        subject.invalidate()
        await driver.complete(0.5)
        await task.value
        XCTAssertNil(subject.appliedExposure)
        XCTAssertNil(subject.capabilities.exposure)
        XCTAssertFalse(subject.isApplying)
        XCTAssertEqual(subject.photoAspectRatio, .square)
    }
}
private actor DeferredDetailControls: DetailCameraControlling {
    private(set) var received: DetailCameraControlRequest?
    private var completion: CheckedContinuation<Double, Never>?
    func capabilities() async throws -> DetailCameraCapabilities {
        .init(exposure: .init(minimum: -1, maximum: 1))
    }
    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        received = request
        return await withCheckedContinuation { completion = $0 }
    }
    func waitForRequest() async { while completion == nil { await Task.yield() } }
    func complete(_ value: Double) { completion?.resume(returning: value); completion = nil }
}

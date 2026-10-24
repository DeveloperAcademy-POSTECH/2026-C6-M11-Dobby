// Created by mason on 10/21/26.
import XCTest
@testable import Dobby

@MainActor
final class DetailExposureControlTests: XCTestCase {
    func testNewRequestCancelsPreviousAndIgnoresOldOrDuplicateCallbacks() throws {
        let completion = DetailExposureCompletion()
        var oldResults: [Result<Double, Error>] = [], newResults: [Result<Double, Error>] = []
        let old = completion.begin { oldResults.append($0) }
        let latest = completion.begin { newResults.append($0) }
        XCTAssertEqual(oldResults.count, 1)
        if case .failure(let error) = oldResults[0] { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("교체된 요청은 취소되어야 합니다.") }
        completion.finish(old, with: .success(0.5))
        XCTAssertTrue(completion.isPending)
        completion.finish(latest, with: .success(0.75))
        completion.finish(latest, with: .success(1))
        XCTAssertEqual(newResults.count, 1)
        XCTAssertEqual(try newResults[0].get(), 0.75)
        XCTAssertFalse(completion.isPending)
    }
    func testStopAndTimeoutResolveOnceAndDoNotAffectRestartedRequest() {
        let completion = DetailExposureCompletion()
        var count = 0
        let stopped = completion.begin { _ in count += 1 }
        completion.cancel()
        completion.cancel()
        let restarted = completion.begin { _ in count += 1 }
        completion.finish(stopped, with: .success(1))
        XCTAssertEqual(count, 1)
        XCTAssertTrue(completion.isPending)
        completion.finish(restarted, with: .failure(DetailCameraControlFailure.unavailable))
        completion.finish(restarted, with: .success(0))
        XCTAssertEqual(count, 2)
        XCTAssertFalse(completion.isPending)
    }
    func testRefreshReadsDeviceValueAndResetUsesControllerIncludingFailure() async {
        let model = DetailCameraOptions(controller: ExposureFixture())
        await model.refreshCapabilities()
        XCTAssertEqual(model.appliedExposure, 0.5)
        await model.resetExposure()
        XCTAssertEqual(model.requested, .exposure(0))
        XCTAssertEqual(model.appliedExposure, 0)
        await model.apply(.exposure(1))
        XCTAssertEqual(model.failure, .deviceFailure)
        XCTAssertEqual(model.appliedExposure, 0)
        XCTAssertFalse(model.isApplying)
    }
}
private struct ExposureFixture: DetailCameraControlling {
    func capabilities() async throws -> DetailCameraCapabilities {
        .init(exposure: .init(minimum: -2, maximum: 2), exposureBias: 0.5)
    }
    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        guard request == .exposure(0) else { throw DetailCameraControlFailure.deviceFailure }
        return 0
    }
}

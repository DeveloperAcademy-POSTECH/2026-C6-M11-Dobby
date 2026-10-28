// Created by mason on 10/21/26.
import XCTest
@testable import Dobby

@MainActor
final class DetailCameraOptionsTests: XCTestCase {
    func testZoomStopsBounceAndSkipUnsupportedUltraWide() {
        for (minimum, expected) in [(0.5, [2.0, 1, 0.5, 1, 2]), (1.0, [2.0, 1, 2, 1, 2])] {
            var stops = DetailZoomStops()
            var value = 1.0
            for target in expected {
                value = stops.next(from: value, range: .init(minimum: minimum, maximum: 2)!)
                XCTAssertEqual(value, target)
            }
        }
    }
    func testZoomClampsAndRestoresDeviceValueAfterRestart() async {
        let driver = DeferredDetailControls()
        let model = DetailCameraOptions(controller: driver)
        await model.refreshCapabilities()
        let task = Task { await model.apply(.zoom(4)) }
        await driver.waitForRequest()
        let received = await driver.received
        XCTAssertEqual(received, .zoom(2))
        await driver.complete(2)
        await task.value
        XCTAssertEqual(model.appliedZoom, 2)
        model.invalidate()
        await model.refreshCapabilities()
        XCTAssertEqual(model.appliedZoom, 1)
    }
    func testButtonStopsStayAtTwoWithLargerDeviceMaximum() {
        for minimum in [0.5, 1.0] {
            let range = DetailCameraControlRange(minimum: minimum, maximum: 40)!
            let expected = minimum < 1 ? [2.0, 1, 0.5, 1, 2] : [2.0, 1, 2, 1, 2]
            var stops = DetailZoomStops()
            var value = 1.0
            for target in expected {
                value = stops.next(from: value, range: range)
                XCTAssertEqual(value, target)
            }
            // 핀치가 끝나면 UI에서 버튼 순환 방향도 초기화한다.
            stops = DetailZoomStops()
            value = 12
            for target in expected {
                value = stops.next(from: value, range: range)
                XCTAssertEqual(value, target)
            }
        }
    }
    func testButtonStopsRespectDeviceLimitBelowTwo() {
        var stops = DetailZoomStops()
        let range = DetailCameraControlRange(minimum: 1, maximum: 1.5)!
        XCTAssertEqual(stops.next(from: 1, range: range), 1.5)
        XCTAssertEqual(stops.next(from: 1.5, range: range), 1)
    }
    func testExtendedZoomUsesDeviceLimitAndReportsAppliedValue() async {
        let driver = DeferredDetailControls(maximumZoom: 20)
        let model = DetailCameraOptions(controller: driver)
        await model.refreshCapabilities()
        for (requested, limited, applied) in [(8.0, 8.0, 7.9), (100.0, 20.0, 20.0)] {
            let task = Task { await model.apply(.zoom(requested)) }
            await driver.waitForRequest()
            let received = await driver.received
            XCTAssertEqual(received, .zoom(limited))
            await driver.complete(applied)
            await task.value
            XCTAssertEqual(model.appliedZoom, applied)
            XCTAssertNil(model.failure)
        }
    }
    func testDefaultRatioIsFourThreeWithoutInventingDeviceValues() async {
        let model = DetailCameraOptions()
        await model.refreshCapabilities()
        await model.apply(.exposure(1))
        XCTAssertEqual(model.failure, .unsupported)
        XCTAssertNil(model.appliedExposure)
        XCTAssertNil(model.appliedZoom)
        XCTAssertEqual(model.photoAspectRatio, .fourThree)
    }
    func testPreviewRatioMatchesSavedCropInBothOrientations() throws {
        for ratio in DetailPhotoAspectRatio.allCases {
            for landscape in [false, true] {
                let crop = try XCTUnwrap(DetailPhotoCropGeometry(
                    pixelWidth: 4032, pixelHeight: 3024,
                    orientation: landscape ? .up : .right, aspectRatio: ratio))
                XCTAssertEqual(ratio.previewRatio(isLandscape: landscape),
                               crop.outputPixelSize.width / crop.outputPixelSize.height, accuracy: 0.0001)
            }
        }
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
    let maximumZoom: Double
    init(maximumZoom: Double = 2) { self.maximumZoom = maximumZoom }
    private(set) var received: DetailCameraControlRequest?
    private var completion: CheckedContinuation<Double, Never>?
    func capabilities() async throws -> DetailCameraCapabilities {
        .init(exposure: .init(minimum: -1, maximum: 1),
              zoom: .init(minimum: 0.5, maximum: maximumZoom), zoomFactor: 1)
    }
    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        received = request
        return await withCheckedContinuation { completion = $0 }
    }
    func waitForRequest() async { while completion == nil { await Task.yield() } }
    func complete(_ value: Double) { completion?.resume(returning: value); completion = nil }
}

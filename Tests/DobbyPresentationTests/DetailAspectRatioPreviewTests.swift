// Created by mason on 10/24/26.
import AVFoundation
import SwiftUI
import XCTest
@testable import Dobby

/// 실제 카메라 프레임 대신 UIKit 프리뷰 레이어의 배치를 계측한다.
@MainActor
final class DetailAspectRatioPreviewTests: XCTestCase {
    func testViewportIsCenteredAndMatchesSavedCropAcrossContainerSizes() throws {
        for size in [CGSize(width: 400, height: 800), CGSize(width: 800, height: 400),
                     CGSize(width: 320, height: 320), CGSize(width: 320, height: 480)] {
            for ratio in DetailPhotoAspectRatio.allCases {
                let frame = DetailAspectRatioPreviewLayout(containerSize: size, aspectRatio: ratio).frame
                let crop = try XCTUnwrap(DetailPhotoCropGeometry(pixelWidth: 4032, pixelHeight: 3024,
                    orientation: size.width > size.height ? .up : .right, aspectRatio: ratio))
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.001)
                XCTAssertGreaterThanOrEqual(frame.minY, -0.001)
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.001)
                XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.001)
                XCTAssertEqual(frame.midX, size.width / 2, accuracy: 0.001)
                XCTAssertEqual(frame.midY, size.height / 2, accuracy: 0.001)
                XCTAssertEqual(frame.width / frame.height,
                    crop.outputPixelSize.width / crop.outputPixelSize.height, accuracy: 0.0001)
                XCTAssertTrue(abs(frame.width - size.width) < 0.001 || abs(frame.height - size.height) < 0.001)
            }
        }
    }

    func testRatioTransitionDeliversIntermediateSizesWithoutRecreatingPreview() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "중간 크기 검증은 동작 줄이기가 꺼진 환경에서 실행합니다.")
        let fixture = try host()
        defer { fixture.close() }
        try await waitForSize(fixture, height: 400 * 4 / 3)
        fixture.samples.sizes.removeAll()
        fixture.options.photoAspectRatio = .sixteenNine
        try await waitForSize(fixture, height: 400 * 16 / 9)
        XCTAssertTrue(fixture.samples.sizes.contains { $0.height > 535 && $0.height < 710 },
                      "최종 크기로 즉시 교체하지 않고 UIKit에 중간 크기를 전달해야 합니다.")
        fixture.options.photoAspectRatio = .square
        try await waitForSize(fixture, height: 400)
        fixture.options.photoAspectRatio = .fourThree
        try await waitForSize(fixture, height: 400 * 4 / 3)
        XCTAssertEqual(fixture.samples.creations, 1)
        XCTAssertEqual(fixture.options.photoAspectRatio, .fourThree)
    }

    func testSelectionDuringTransitionFinishesAtLatestRatio() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "전환 중 재선택 검증은 동작 줄이기가 꺼진 환경에서 실행합니다.")
        let fixture = try host()
        defer { fixture.close() }
        try await waitForSize(fixture, height: 400 * 4 / 3)
        fixture.samples.sizes.removeAll()
        fixture.options.photoAspectRatio = .sixteenNine
        // 고정 시간 대신 실제 중간 프레임이 도착한 뒤 재선택한다.
        try await eventually("16:9 전환 중간 크기가 전달되어야 합니다.") {
            fixture.samples.sizes.last.map { $0.height > 535 && $0.height < 710 } ?? false
        }
        fixture.options.photoAspectRatio = .square
        XCTAssertEqual(fixture.options.photoAspectRatio, .square, "저장에 쓰는 비율은 즉시 최신 선택값이어야 합니다.")
        try await waitForSize(fixture, height: 400)
        XCTAssertEqual(fixture.samples.creations, 1)
    }

    func testInitialSelectedRatioDoesNotStartAtDefaultFourThree() async throws {
        let fixture = try host(ratio: .square)
        defer { fixture.close() }
        try await waitForSize(fixture, height: 400)
        XCTAssertTrue(fixture.samples.sizes.filter { $0.height > 0 }.allSatisfy { abs($0.height - 400) < 0.5 })
        XCTAssertEqual(fixture.options.photoAspectRatio, .square)
        XCTAssertEqual(fixture.samples.creations, 1)
    }

    func testBackdropFillsContainerWithoutFollowingCaptureRatio() async throws {
        let fixture = try host()
        defer { fixture.close() }
        for ratio in DetailPhotoAspectRatio.allCases {
            fixture.options.photoAspectRatio = ratio
            let frame = DetailAspectRatioPreviewLayout(containerSize: CGSize(width: 400, height: 800),
                                                       aspectRatio: ratio).frame
            try await waitForSize(fixture, height: frame.height)
            XCTAssertEqual(fixture.backdrop.sizes.last, CGSize(width: 400, height: 800))
        }
        XCTAssertEqual(fixture.samples.creations, 1)
        XCTAssertEqual(fixture.backdrop.creations, 1)
        XCTAssertTrue(fixture.backdrop.sizes.filter { $0 != .zero }
            .allSatisfy { $0 == CGSize(width: 400, height: 800) })
    }

    private struct Fixture {
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let options: DetailCameraOptions
        let samples: PreviewSamples
        let backdrop: PreviewSamples
        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
    }

    private func host(ratio: DetailPhotoAspectRatio = .fourThree) throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let options = DetailCameraOptions()
        options.photoAspectRatio = ratio
        let samples = PreviewSamples()
        let backdrop = PreviewSamples()
        window.rootViewController = UIHostingController(rootView:
            PreviewHarness(options: options, samples: samples, backdrop: backdrop))
        window.makeKeyAndVisible()
        return Fixture(window: window, previousKeyWindow: previousKeyWindow, options: options,
                       samples: samples, backdrop: backdrop)
    }

    private func waitForSize(_ fixture: Fixture, height: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually("프리뷰가 400×\(height)에 도착해야 합니다.", file: file, line: line) {
            fixture.samples.sizes.last.map { abs($0.width - 400) < 0.5 && abs($0.height - height) < 0.5 } ?? false
        }
    }

    private enum AwaitFailure: Error { case timedOut }
    private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                            condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message, file: file, line: line)
        throw AwaitFailure.timedOut
    }
}

@MainActor private final class PreviewSamples {
    var sizes: [CGSize] = []
    var creations = 0
}

private struct PreviewHarness: View {
    let options: DetailCameraOptions
    let samples: PreviewSamples
    let backdrop: PreviewSamples
    var body: some View {
        DetailAspectRatioPreview(aspectRatio: options.photoAspectRatio) {
            PreviewProbe(samples: samples)
        } backdrop: {
            PreviewProbe(samples: backdrop)
        }
        .frame(width: 400, height: 800)
    }
}

private struct PreviewProbe: UIViewRepresentable {
    let samples: PreviewSamples
    func makeUIView(context: Context) -> RecordingPreviewView {
        samples.creations += 1
        let view = RecordingPreviewView()
        view.samples = samples
        (view.layer as? AVCaptureVideoPreviewLayer)?.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: RecordingPreviewView, context: Context) {}
}

private final class RecordingPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var samples: PreviewSamples?
    override func layoutSubviews() {
        super.layoutSubviews()
        samples?.sizes.append(bounds.size)
    }
}

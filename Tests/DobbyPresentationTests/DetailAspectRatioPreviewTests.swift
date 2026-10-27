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

    func testRatioChangesKeepOneFullscreenPreview() async throws {
        let fixture = try host()
        defer { fixture.close() }
        for ratio in DetailPhotoAspectRatio.allCases {
            fixture.options.photoAspectRatio = ratio
            try await waitForSize(fixture, height: 800)
            try await Task.sleep(for: .milliseconds(400))
        }
        XCTAssertEqual(fixture.samples.creations, 1)
        XCTAssertTrue(fixture.samples.sizes.filter { $0 != .zero }
            .allSatisfy { $0 == CGSize(width: 400, height: 800) })
    }

    func testResizeChangesSinglePreviewBounds() async throws {
        let fixture = try host(ratio: .square)
        defer { fixture.close() }
        try await waitForSize(fixture, height: 800)
        let host = try XCTUnwrap(fixture.window.rootViewController as? UIHostingController<PreviewHarness>)
        host.rootView = PreviewHarness(options: fixture.options, samples: fixture.samples,
                                      size: CGSize(width: 800, height: 400))
        try await eventually("회전 후에도 단일 프리뷰가 화면을 채워야 합니다.") {
            fixture.samples.sizes.last == CGSize(width: 800, height: 400)
        }
        XCTAssertEqual(fixture.samples.creations, 1)
    }

    func testGlassLeavesOnlyRatioViewportClearAndProtectsControls() {
        let size = CGSize(width: 390, height: 844)
        for ratio in DetailPhotoAspectRatio.allCases {
            let frame = DetailAspectRatioPreviewLayout(containerSize: size, aspectRatio: ratio,
                                                       topInset: 110, bottomInset: 148).frame
            XCTAssertGreaterThanOrEqual(frame.minY, 110)
            XCTAssertLessThanOrEqual(frame.maxY, 696)
            XCTAssertEqual(frame.width / frame.height, ratio.previewRatio(isLandscape: false), accuracy: 0.0001)
            let mask = DetailPreviewGlassMask(viewport: frame).path(in: CGRect(origin: .zero, size: size))
            XCTAssertFalse(mask.contains(CGPoint(x: frame.midX, y: frame.midY), eoFill: true))
            XCTAssertTrue(mask.contains(CGPoint(x: 195, y: 55), eoFill: true))
            XCTAssertTrue(mask.contains(CGPoint(x: 195, y: 770), eoFill: true))
        }
    }

    private struct Fixture {
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let options: DetailCameraOptions
        let samples: PreviewSamples
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
        window.rootViewController = UIHostingController(rootView:
            PreviewHarness(options: options, samples: samples))
        window.makeKeyAndVisible()
        return Fixture(window: window, previousKeyWindow: previousKeyWindow, options: options,
                       samples: samples)
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
    var size = CGSize(width: 400, height: 800)
    var body: some View {
        DetailAspectRatioPreview(aspectRatio: options.photoAspectRatio) { _ in
            PreviewProbe(samples: samples)
        }
        .frame(width: size.width, height: size.height)
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

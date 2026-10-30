// Created by mason on 10/24/26.
import AVFoundation
import SwiftUI
import XCTest
@testable import Dobby

/// 실제 카메라 프레임 대신 UIKit 프리뷰 레이어의 배치를 계측한다.
@MainActor
final class DetailAspectRatioPreviewTests: XCTestCase {
    func testViewportMatchesMeasurementPlacementAndSavedCropAcrossContainerSizes() throws {
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
                let expected = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(
                    containerWidth: Double(size.width), containerHeight: Double(size.height),
                    photoAspectRatio: ratio.previewRatio(isLandscape: size.width > size.height)))
                XCTAssertEqual(frame.midX, expected.x + expected.width / 2, accuracy: 0.001)
                XCTAssertEqual(frame.minX, expected.x, accuracy: 0.001)
                XCTAssertEqual(frame.minY, expected.y, accuracy: 0.001)
                XCTAssertEqual(frame.width, expected.width, accuracy: 0.001)
                XCTAssertEqual(frame.height, expected.height, accuracy: 0.001)
                XCTAssertEqual(frame.width / frame.height,
                    crop.outputPixelSize.width / crop.outputPixelSize.height, accuracy: 0.0001)
            }
        }
    }

    func testRatioChangesKeepOnePhotoSizedPreview() async throws {
        let fixture = try host()
        defer { fixture.close() }
        for ratio in DetailPhotoAspectRatio.allCases {
            fixture.options.photoAspectRatio = ratio
            let expected = DetailAspectRatioPreviewLayout(containerSize: CGSize(width: 400, height: 800),
                aspectRatio: ratio).frame.size
            try await waitForSize(fixture, size: expected)
            try await Task.sleep(for: .milliseconds(400))
        }
        XCTAssertEqual(fixture.samples.creations, 1)
        XCTAssertFalse(fixture.samples.sizes.contains(CGSize(width: 400, height: 800)))
    }

    func testResizeChangesSinglePreviewBounds() async throws {
        let fixture = try host(ratio: .square)
        defer { fixture.close() }
        try await waitForSize(fixture, size: CGSize(width: 400, height: 400))
        let host = try XCTUnwrap(fixture.window.rootViewController as? UIHostingController<PreviewHarness>)
        host.rootView = PreviewHarness(options: fixture.options, samples: fixture.samples,
                                      size: CGSize(width: 800, height: 400))
        try await eventually("회전 후에도 프리뷰가 정사각형 사진 영역에 맞아야 합니다.") {
            fixture.samples.sizes.last == CGSize(width: 400, height: 400)
        }
        XCTAssertEqual(fixture.samples.creations, 1)
    }

    func testTransitionUpdatesActualLayerBoundsWithTheMaskViewport() async throws {
        let fixture = try host()
        defer { fixture.close() }
        let initial = DetailAspectRatioPreviewLayout(containerSize: CGSize(width: 400, height: 800),
            aspectRatio: .fourThree).frame.size
        try await waitForSize(fixture, size: initial)
        fixture.samples.sizes.removeAll()
        fixture.samples.framings.removeAll()
        fixture.options.photoAspectRatio = .square
        try await waitForSize(fixture, size: CGSize(width: 400, height: 400))
        XCTAssertTrue(fixture.samples.sizes.contains { $0.height > 401 && $0.height < initial.height - 1 },
                      "실제 레이어가 중간 크기를 거쳐야 하며 최종 크기로 바로 점프하면 안 됩니다.")
        for (bounds, viewport) in fixture.samples.framings where !bounds.isEmpty {
            XCTAssertEqual(bounds.width, viewport.width, accuracy: 1)
            XCTAssertEqual(bounds.height, viewport.height, accuracy: 1)
        }
        XCTAssertEqual(fixture.samples.creations, 1)
    }

    func testRapidChangesSettleOnLatestRatioWithoutReplacingPreview() async throws {
        let fixture = try host(ratio: .square)
        defer { fixture.close() }
        try await waitForSize(fixture, size: CGSize(width: 400, height: 400))
        fixture.options.photoAspectRatio = .sixteenNine
        try await Task.sleep(for: .milliseconds(60))
        fixture.options.photoAspectRatio = .fourThree
        let expected = DetailAspectRatioPreviewLayout(containerSize: CGSize(width: 400, height: 800),
            aspectRatio: .fourThree).frame.size
        try await waitForSize(fixture, size: expected)
        try await Task.sleep(for: .milliseconds(400))
        try await waitForSize(fixture, size: expected)
        XCTAssertEqual(fixture.samples.creations, 1)
    }

    func testDisabledAnimationsChangePhotoBoundsWithoutIntermediateSizes() async throws {
        let fixture = try host(disablesAnimations: true)
        defer { fixture.close() }
        let initial = DetailAspectRatioPreviewLayout(containerSize: CGSize(width: 400, height: 800),
            aspectRatio: .fourThree).frame.size
        try await waitForSize(fixture, size: initial)
        fixture.samples.sizes.removeAll()
        fixture.options.photoAspectRatio = .square
        try await waitForSize(fixture, size: CGSize(width: 400, height: 400))
        XCTAssertFalse(fixture.samples.sizes.contains { $0.height > 401 && $0.height < initial.height - 1 })
        XCTAssertEqual(fixture.samples.creations, 1)
    }

    func testPortraitRatiosUseTheSamePhotoWindowAndBlackMaskAsMeasurement() throws {
        for size in [CGSize(width: 375, height: 667), CGSize(width: 390, height: 844),
                     CGSize(width: 440, height: 956)] {
            let standard = DetailAspectRatioPreviewLayout(containerSize: size, aspectRatio: .fourThree).frame
            let tall = DetailAspectRatioPreviewLayout(containerSize: size, aspectRatio: .sixteenNine).frame
            let square = DetailAspectRatioPreviewLayout(containerSize: size, aspectRatio: .square).frame
            for (ratio, frame) in [(DetailPhotoAspectRatio.fourThree, standard), (.sixteenNine, tall), (.square, square)] {
                let expected = try XCTUnwrap(MeasurementCameraChromeLayout.photoViewport(
                    containerWidth: Double(size.width), containerHeight: Double(size.height),
                    photoAspectRatio: ratio.previewRatio(isLandscape: false)))
                XCTAssertEqual(frame.minX, expected.x, accuracy: 0.001)
                XCTAssertEqual(frame.minY, expected.y, accuracy: 0.001)
                XCTAssertEqual(frame.width, expected.width, accuracy: 0.001)
                XCTAssertEqual(frame.height, expected.height, accuracy: 0.001)
                let mask = DetailPreviewGlassMask(viewport: frame).path(in: CGRect(origin: .zero, size: size))
                XCTAssertFalse(mask.contains(CGPoint(x: frame.midX, y: frame.midY), eoFill: true))
            }
            XCTAssertLessThan(tall.minY, standard.minY)
            XCTAssertGreaterThan(tall.maxY, standard.maxY)
            XCTAssertGreaterThan(standard.height, square.height)
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

    private func host(ratio: DetailPhotoAspectRatio = .fourThree, disablesAnimations: Bool = false) throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let options = DetailCameraOptions()
        options.photoAspectRatio = ratio
        let samples = PreviewSamples()
        window.rootViewController = UIHostingController(rootView:
            PreviewHarness(options: options, samples: samples, disablesAnimations: disablesAnimations))
        window.makeKeyAndVisible()
        return Fixture(window: window, previousKeyWindow: previousKeyWindow, options: options,
                       samples: samples)
    }

    private func waitForSize(_ fixture: Fixture, size: CGSize,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually("프리뷰가 \(size)에 도착해야 합니다.", file: file, line: line) {
            fixture.samples.sizes.last.map { abs($0.width - size.width) < 0.5 && abs($0.height - size.height) < 0.5 } ?? false
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
    var framings: [(CGRect, CGRect)] = []
    var creations = 0
}

private struct PreviewHarness: View {
    let options: DetailCameraOptions
    let samples: PreviewSamples
    var size = CGSize(width: 400, height: 800)
    var disablesAnimations = false
    var body: some View {
        DetailAspectRatioPreview(aspectRatio: options.photoAspectRatio) { viewport in
            PreviewProbe(samples: samples, viewport: viewport)
        }
        .frame(width: size.width, height: size.height)
        .transaction { if disablesAnimations { $0.disablesAnimations = true } }
    }
}

private struct PreviewProbe: UIViewRepresentable {
    let samples: PreviewSamples
    let viewport: CGRect
    func makeUIView(context: Context) -> RecordingPreviewView {
        samples.creations += 1
        let view = RecordingPreviewView()
        view.samples = samples
        view.viewport = viewport
        (view.layer as? AVCaptureVideoPreviewLayer)?.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: RecordingPreviewView, context: Context) { uiView.viewport = viewport }
}

private final class RecordingPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var samples: PreviewSamples?
    var viewport: CGRect = .zero
    override func layoutSubviews() {
        super.layoutSubviews()
        samples?.sizes.append(bounds.size)
        samples?.framings.append((bounds, viewport))
    }
}

import Foundation
import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Dobby

/// Records actual UIKit view bounds and position through the production
/// modifier. This verifies layout interpolation, not camera or optical response.
@MainActor
final class MeasurementPhotoViewportAnimationTests: XCTestCase {
    private let initial = CGRect(x: 0, y: 146, width: 402, height: 536)
    private let portraitSixteenNine = CGRect(x: 50.25, y: 146, width: 301.5, height: 536)
    private let square = CGRect(x: 0, y: 213, width: 402, height: 402)

    func testRatioAnimationDeliversIntermediateUIKitBoundsWithoutRecreatingThePreview() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled,
                      "Intermediate animation frames require Reduce Motion off; the test never changes that setting.")
        let fixture = try host()
        defer { fixture.close() }
        try await waitForFrame(initial, in: fixture)
        fixture.samples.sizes.removeAll()

        let completion = ViewportAnimationCompletion()
        withAnimation(.smooth(duration: 0.3), completionCriteria: .removed) {
            fixture.model.rect = portraitSixteenNine
        } completion: {
            completion.finish()
        }
        try await eventually("UIKit must receive a real intermediate width, rather than a scaled snapshot") {
            fixture.samples.sizes.contains { $0.width > 303 && $0.width < 400 }
        }
        try await eventually("The ratio animation should finish") { completion.isFinished }
        try await waitForFrame(portraitSixteenNine, in: fixture)
        XCTAssertEqual(fixture.samples.creations, 1)
        XCTAssertEqual(fixture.model.rect, portraitSixteenNine)
        XCTAssertEqual(try XCTUnwrap(fixture.samples.preview).bounds.width, 301.5, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(fixture.samples.preview).bounds.height, 536, accuracy: 0.5)
    }

    func testSelectionDuringInterpolationFinishesAtTheLatestSquareWithoutRecreatingThePreview() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled,
                      "Interrupted animation verification requires Reduce Motion off; no global setting is overridden.")
        let fixture = try host()
        defer { fixture.close() }
        try await waitForFrame(initial, in: fixture)
        fixture.samples.sizes.removeAll()

        withAnimation(.smooth(duration: 0.3)) {
            fixture.model.rect = portraitSixteenNine
        }
        // Observe the CURRENT UIKit width so this cannot accidentally become a
        // second selection made after the first animation has already finished.
        try await eventually("The first transition must still be moving when square is selected") {
            guard let width = fixture.samples.preview?.bounds.width else { return false }
            return width > 303 && width < 400
        }
        XCTAssertTrue(fixture.samples.sizes.contains { $0.width > 303 && $0.width < 400 })

        let completion = ViewportAnimationCompletion()
        withAnimation(.smooth(duration: 0.3), completionCriteria: .removed) {
            fixture.model.rect = square
        } completion: {
            completion.finish()
        }
        XCTAssertEqual(fixture.model.rect, square, "The logical selection must update immediately")
        try await eventually("The latest animation should finish") { completion.isFinished }
        try await waitForFrame(square, in: fixture)
        XCTAssertEqual(fixture.samples.creations, 1)
        XCTAssertEqual(try XCTUnwrap(fixture.samples.preview).bounds.size, CGSize(width: 402, height: 402))
    }

    private struct Fixture {
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let model: ViewportAnimationModel
        let samples: ViewportAnimationSamples

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
    }

    private func host() throws -> Fixture {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let model = ViewportAnimationModel(rect: initial)
        let samples = ViewportAnimationSamples()
        window.rootViewController = UIHostingController(rootView: ViewportAnimationHarness(model: model, samples: samples))
        window.makeKeyAndVisible()
        return Fixture(window: window, previousKeyWindow: previousKeyWindow, model: model, samples: samples)
    }

    private func waitForFrame(_ expected: CGRect, in fixture: Fixture,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually("The actual UIKit preview must reach \(expected)", file: file, line: line) {
            guard let preview = fixture.samples.preview, let reference = fixture.samples.reference,
                  preview.window === fixture.window, reference.window === fixture.window else { return false }
            let actual = preview.convert(preview.bounds, to: reference)
            return abs(preview.bounds.width - expected.width) < 0.5
                && abs(preview.bounds.height - expected.height) < 0.5
                && abs(actual.minX - expected.minX) < 0.5
                && abs(actual.minY - expected.minY) < 0.5
                && abs(actual.width - expected.width) < 0.5
                && abs(actual.height - expected.height) < 0.5
        }
    }

    private enum AwaitFailure: Error { case timedOut }

    private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                            condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message, file: file, line: line)
        throw AwaitFailure.timedOut
    }
}

@MainActor private final class ViewportAnimationModel: ObservableObject {
    @Published var rect: CGRect
    init(rect: CGRect) { self.rect = rect }
}

@MainActor private final class ViewportAnimationSamples {
    var sizes: [CGSize] = []
    var creations = 0
    weak var preview: RecordingMeasurementViewportView?
    weak var reference: UIView?
}

private struct ViewportAnimationHarness: View {
    @ObservedObject var model: ViewportAnimationModel
    let samples: ViewportAnimationSamples

    var body: some View {
        MeasurementViewportProbe(samples: samples)
            .modifier(MeasurementPhotoViewportModifier(rect: model.rect))
            .frame(width: 402, height: 874)
            // A test-owned reference makes position checks independent of the
            // device's screen size, safe-area insets and hosting-view centering.
            .background { ViewportCoordinateReference(samples: samples).allowsHitTesting(false) }
            .ignoresSafeArea()
    }
}

private struct MeasurementViewportProbe: UIViewRepresentable {
    let samples: ViewportAnimationSamples

    func makeUIView(context: Context) -> RecordingMeasurementViewportView {
        samples.creations += 1
        let view = RecordingMeasurementViewportView()
        view.samples = samples
        samples.preview = view
        return view
    }

    func updateUIView(_ uiView: RecordingMeasurementViewportView, context: Context) {}
}

private struct ViewportCoordinateReference: UIViewRepresentable {
    let samples: ViewportAnimationSamples

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        samples.reference = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class RecordingMeasurementViewportView: UIView {
    weak var samples: ViewportAnimationSamples?

    override func layoutSubviews() {
        super.layoutSubviews()
        samples?.sizes.append(bounds.size)
    }
}

private nonisolated final class ViewportAnimationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }
}

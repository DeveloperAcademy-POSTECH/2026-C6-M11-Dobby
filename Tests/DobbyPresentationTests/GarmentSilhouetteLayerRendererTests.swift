import QuartzCore
import UIKit
import XCTest
@testable import Dobby

/// Exercises the renderer in a real layer tree. These are presentation tests;
/// the fabricated silhouettes do not validate a camera, model or centimetres.
@MainActor
final class GarmentSilhouetteLayerRendererTests: XCTestCase {
    @MainActor private struct Fixture {
        let window: UIWindow
        let view: UIView
        let renderer: GarmentSilhouetteLayerRenderer

        var shapes: [CAShapeLayer] { view.layer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? [] }
        var paths: [CGPath] { shapes.compactMap(\.path) }
        var animations: [CABasicAnimation] {
            shapes.flatMap { layer in
                (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CABasicAnimation }
            }
        }

        func close() {
            renderer.tearDown()
            window.isHidden = true
        }
    }

    private enum AwaitFailure: Error { case timedOut }

    private func fixture() throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 256, height: 256))
        controller.view.addSubview(view)
        window.isHidden = false
        controller.view.layoutIfNeeded()
        return .init(window: window, view: view, renderer: .init(containerLayer: view.layer))
    }

    private func topMask(shift: Int = 0, hole: Bool = false) -> GarmentMask {
        let size = PixelSize(width: 128, height: 128)
        var values = [UInt8](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let localX = x - shift
                let body = (42..<86).contains(localX) && (32..<112).contains(y)
                let sleeves = (14..<114).contains(localX) && (32..<56).contains(y)
                let neckline = (58..<70).contains(localX) && (32..<40).contains(y)
                let opening = hole && (58..<70).contains(localX) && (76..<88).contains(y)
                values[y * size.width + x] = (body || sleeves) && !neckline && !opening ? 1 : 0
            }
        }
        return .init(size: size, values: values)
    }

    private func identity(epoch: UUID = UUID(), timestamp: TimeInterval = 1,
                          orientation: ImageOrientation = .up) -> GarmentSilhouetteRenderIdentity {
        .init(epoch: epoch, timestamp: timestamp, orientation: orientation)
    }

    private func update(_ fixture: Fixture, mask: GarmentMask, identity: GarmentSilhouetteRenderIdentity,
                        reduceMotion: Bool = false, viewport: CGRect? = nil) {
        let viewport = viewport ?? fixture.view.bounds
        fixture.renderer.update(mask: mask, identity: identity,
            transform: CGAffineTransform(scaleX: viewport.width, y: viewport.height)
                .concatenating(.init(translationX: viewport.minX, y: viewport.minY)),
            viewport: viewport, fillColor: UIColor.systemMint.withAlphaComponent(0.20).cgColor,
            strokeColor: UIColor.systemMint.cgColor, reduceMotion: reduceMotion)
    }

    private func eventually(_ message: String, condition: @MainActor () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message, file: file, line: line)
        throw AwaitFailure.timedOut
    }

    private func settle(_ fixture: Fixture) async throws {
        try await eventually("The initial contour fade must finish before another shape is tested") {
            fixture.renderer.hasVisibleSilhouette && fixture.paths.count == 1 && fixture.animations.isEmpty
        }
    }

    private func assertHidden(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.renderer.hasVisibleSilhouette, file: file, line: line)
        XCTAssertTrue(fixture.paths.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.animations.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.shapes.allSatisfy { $0.opacity == 0 }, file: file, line: line)
    }

    private func assertFiniteClosed(_ path: CGPath, file: StaticString = #filePath, line: UInt = #line) {
        var opened = 0, closed = 0, finite = true
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint: opened += 1; count = 1
            case .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: closed += 1; count = 0
            @unknown default: finite = false; count = 0
            }
            for index in 0..<count {
                let point = element.pointee.points[index]
                finite = finite && point.x.isFinite && point.y.isFinite
            }
        }
        XCTAssertTrue(finite, file: file, line: line)
        XCTAssertGreaterThan(opened, 0, file: file, line: line)
        XCTAssertEqual(opened, closed, file: file, line: line)
        XCTAssertFalse(path.boundingBoxOfPath.isEmpty, file: file, line: line)
    }

    func testAsynchronousMaskUpdateProducesFiniteClosedPathWithEvenOddFill() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        update(fixture, mask: topMask(), identity: identity())
        XCTAssertFalse(fixture.renderer.hasVisibleSilhouette, "Contour extraction must not complete synchronously on the UI actor")
        try await eventually("The geometry worker must publish a visible silhouette") { fixture.renderer.hasVisibleSilhouette }
        let path = try XCTUnwrap(fixture.paths.first)
        assertFiniteClosed(path)
        XCTAssertTrue(fixture.view.bounds.contains(path.boundingBoxOfPath))
        XCTAssertTrue(fixture.shapes.allSatisfy { $0.fillRule == .evenOdd })
    }

    func testSmallSteadyShapeChangeUsesShortNativePathAnimationAfterInitialFade() async throws {
        let fixture = try fixture(), epoch = UUID()
        defer { fixture.close() }
        update(fixture, mask: topMask(), identity: identity(epoch: epoch))
        try await settle(fixture)
        update(fixture, mask: topMask(shift: 1), identity: identity(epoch: epoch, timestamp: 2))
        try await eventually("A steady one-pixel update should animate the contour path") {
            fixture.animations.contains { $0.keyPath == "path" }
        }
        let animation = try XCTUnwrap(fixture.animations.first { $0.keyPath == "path" })
        XCTAssertEqual(animation.duration, 0.22, accuracy: 0.01)
        XCTAssertEqual(animation.repeatCount, 0)
        XCTAssertFalse(animation.autoreverses)
        XCTAssertNotNil(animation.timingFunction)
        XCTAssertFalse(fixture.animations.contains { $0.keyPath == "opacity" })
        for path in fixture.paths { assertFiniteClosed(path) }
    }

    func testHoleTopologyChangeCrossfadesCompletePathsAndPreservesOpening() async throws {
        let fixture = try fixture(), epoch = UUID()
        defer { fixture.close() }
        update(fixture, mask: topMask(), identity: identity(epoch: epoch))
        try await settle(fixture)
        update(fixture, mask: topMask(hole: true), identity: identity(epoch: epoch, timestamp: 2))
        try await eventually("A new hole must use opacity instead of arbitrary point correspondence") {
            fixture.animations.contains { $0.keyPath == "opacity" }
        }
        XCTAssertFalse(fixture.animations.contains { $0.keyPath == "path" })
        let incoming = try XCTUnwrap(fixture.shapes.first { $0.opacity == 1 && $0.path != nil })
        let path = try XCTUnwrap(incoming.path)
        assertFiniteClosed(path)
        XCTAssertTrue(path.contains(CGPoint(x: 100, y: 140), using: .evenOdd))
        XCTAssertFalse(path.contains(CGPoint(x: 128, y: 164), using: .evenOdd), "The garment's opening must remain transparent")
    }

    func testClearImmediatelyRemovesAcceptedAndQueuedGeometryWithoutLateGhost() async throws {
        let fixture = try fixture(), epoch = UUID()
        defer { fixture.close() }
        update(fixture, mask: topMask(), identity: identity(epoch: epoch))
        try await settle(fixture)
        update(fixture, mask: topMask(shift: 1), identity: identity(epoch: epoch, timestamp: 2))
        fixture.renderer.clear()
        assertHidden(fixture)
        // A cancelled worker can still complete internally. Observe the layer
        // tree across its main-actor delivery window, not just before a yield.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            await Task.yield()
            assertHidden(fixture)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testEpochAndOrientationChangesClearOldOutlineBeforePublishingNewContext() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        var current = identity()
        update(fixture, mask: topMask(), identity: current)
        try await settle(fixture)
        for orientationChange in [false, true] {
            current = identity(epoch: orientationChange ? current.epoch : UUID(),
                timestamp: current.timestamp + 1, orientation: orientationChange ? .right : .up)
            update(fixture, mask: topMask(shift: 2), identity: current)
            assertHidden(fixture)
            try await eventually("Only geometry from the new context may become visible") { fixture.renderer.hasVisibleSilhouette }
            XCTAssertFalse(fixture.animations.contains { $0.keyPath == "path" })
            let path = try XCTUnwrap(fixture.shapes.first { $0.opacity == 1 }?.path)
            XCTAssertEqual(path.boundingBoxOfPath.minX, 32, accuracy: 2)
            try await settle(fixture)
        }
    }

    func testViewportChangeSnapsCurrentContourAndCancelsAnActiveMorph() async throws {
        let fixture = try fixture(), epoch = UUID()
        defer { fixture.close() }
        update(fixture, mask: topMask(), identity: identity(epoch: epoch))
        try await settle(fixture)
        let next = identity(epoch: epoch, timestamp: 2)
        update(fixture, mask: topMask(shift: 1), identity: next)
        try await eventually("The fixture must enter a path animation before interrupting layout") {
            fixture.animations.contains { $0.keyPath == "path" }
        }
        update(fixture, mask: topMask(shift: 1), identity: next,
            viewport: CGRect(x: 20, y: 10, width: 128, height: 192))
        XCTAssertTrue(fixture.animations.isEmpty)
        XCTAssertTrue(fixture.renderer.hasVisibleSilhouette)
        XCTAssertEqual(fixture.paths.count, 1)
        let layer = try XCTUnwrap(fixture.shapes.first { $0.opacity == 1 })
        XCTAssertEqual(layer.frame, CGRect(x: 20, y: 10, width: 128, height: 192))
        let path = try XCTUnwrap(layer.path)
        XCTAssertEqual(path.boundingBoxOfPath.minX, 15, accuracy: 1)
        assertFiniteClosed(path)
    }

    func testReduceMotionInterruptsCurrentAnimationAndSnapsSameAcceptedIdentity() async throws {
        let fixture = try fixture(), epoch = UUID()
        defer { fixture.close() }
        update(fixture, mask: topMask(), identity: identity(epoch: epoch))
        try await settle(fixture)
        let next = identity(epoch: epoch, timestamp: 2)
        update(fixture, mask: topMask(shift: 1), identity: next)
        try await eventually("The fixture must enter a morph before reducing motion") {
            fixture.animations.contains { $0.keyPath == "path" }
        }
        update(fixture, mask: topMask(shift: 1), identity: next, reduceMotion: true)
        XCTAssertTrue(fixture.animations.isEmpty)
        XCTAssertTrue(fixture.renderer.hasVisibleSilhouette)
        XCTAssertEqual(fixture.paths.count, 1)
        let path = try XCTUnwrap(fixture.paths.first)
        assertFiniteClosed(path)
        XCTAssertEqual(path.boundingBoxOfPath.minX, 30, accuracy: 2)
    }

    func testTeardownRemovesLayersAndRejectsFutureOrPendingUpdates() async throws {
        let fixture = try fixture()
        defer { fixture.close() }
        update(fixture, mask: topMask(), identity: identity())
        fixture.renderer.tearDown()
        XCTAssertTrue(fixture.shapes.isEmpty)
        XCTAssertFalse(fixture.renderer.hasVisibleSilhouette)
        update(fixture, mask: topMask(shift: 1), identity: identity())
        XCTAssertTrue(fixture.shapes.isEmpty)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            await Task.yield()
            XCTAssertTrue(fixture.shapes.isEmpty)
            XCTAssertFalse(fixture.renderer.hasVisibleSilhouette)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testReduceMotionWithNewPendingIdentityImmediatelyStopsOldPathMorph() async throws {
        let fixture = try fixture(), epoch = UUID()
        defer { fixture.close() }
        update(fixture, mask: topMask(), identity: identity(epoch: epoch))
        try await settle(fixture)
        update(fixture, mask: topMask(shift: 1), identity: identity(epoch: epoch, timestamp: 2))
        try await eventually("The older accepted identity must be visibly morphing before interruption") {
            fixture.animations.contains { $0.keyPath == "path" }
        }

        // Unlike a same-identity accessibility update, the newest contour still
        // needs asynchronous preparation while the previous path is animating.
        update(fixture, mask: topMask(shift: 2), identity: identity(epoch: epoch, timestamp: 3), reduceMotion: true)
        XCTAssertFalse(fixture.animations.contains { $0.keyPath == "path" },
                       "Reducing motion must stop the old path immediately, before new geometry arrives")
        try await eventually("The new pending identity must eventually replace the old accepted shape") {
            fixture.shapes.contains { layer in
                layer.opacity == 1 && layer.path.map { abs($0.boundingBoxOfPath.minX - 32) < 0.1 } == true
            }
        }
        XCTAssertFalse(fixture.animations.contains { $0.keyPath == "path" })
        XCTAssertTrue(fixture.animations.allSatisfy { $0.keyPath == "opacity" },
                      "A reduced-motion replacement may dissolve, but must not move the contour")
        for path in fixture.paths { assertFiniteClosed(path) }
    }
}

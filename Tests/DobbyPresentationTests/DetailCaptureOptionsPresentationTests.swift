import SwiftUI
import UIKit
import XCTest
@testable import Dobby

/// UIKit hosting verifies the panel's real proposed-size layout. No physical
/// exposure, animation frame-rate, or camera sensor response is simulated here.
@MainActor
final class DetailCaptureOptionsPresentationTests: XCTestCase {
    func testMeasurementPanelsFitANarrowLandscapeOptionsRegion() async {
        let options = DetailCameraOptions(controller: FixedPanelControls())
        await options.refreshCapabilities()
        for destination in DetailCaptureOptionsDestination.allCases {
            assertFits(destination, options: options, available: CGSize(width: 180, height: 260),
                typeSize: .large, reduceMotion: false)
        }
    }

    func testLargestDynamicTypeAndReducedMotionKeepEveryPanelWithinTheAvailableWindow() async {
        let options = DetailCameraOptions(controller: FixedPanelControls())
        await options.refreshCapabilities()
        for destination in DetailCaptureOptionsDestination.allCases {
            for available in [CGSize(width: 180, height: 280), CGSize(width: 320, height: 240)] {
                assertFits(destination, options: options, available: available,
                    typeSize: .accessibility5, reduceMotion: true)
            }
        }
    }

    private func assertFits(_ destination: DetailCaptureOptionsDestination,
                            options: DetailCameraOptions, available: CGSize,
                            typeSize: DynamicTypeSize, reduceMotion: Bool,
                            file: StaticString = #filePath, line: UInt = #line) {
        let controller = UIHostingController(rootView:
            DetailCaptureOptionsView(options: options, presentation: .measurement,
                selection: .constant(destination), forceReduceMotion: reduceMotion, onClose: {})
                .environment(\.dynamicTypeSize, typeSize))
        controller.loadViewIfNeeded()
        let measured = controller.sizeThatFits(in: available)
        XCTAssertTrue(measured.width.isFinite && measured.height.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(measured.width, 44, "\(destination)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(measured.height, 44, "\(destination)", file: file, line: line)
        XCTAssertLessThanOrEqual(measured.width, available.width + 0.5, "\(destination)", file: file, line: line)
        XCTAssertLessThanOrEqual(measured.height, available.height + 0.5, "\(destination)", file: file, line: line)
    }
}

private actor FixedPanelControls: DetailCameraControlling {
    func capabilities() async throws -> DetailCameraCapabilities {
        .init(exposure: .init(minimum: -2, maximum: 2), exposureBias: 0)
    }

    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        guard case .exposure(let value) = request else { throw DetailCameraControlFailure.unsupported }
        return value
    }
}

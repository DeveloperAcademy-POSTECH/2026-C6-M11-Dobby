import AVFoundation
import SwiftUI
import XCTest
@testable import Dobby

final class MeasurementCaptureActivationTests: XCTestCase {
    func testHomePreviewStartsOnlyAnAlreadyAuthorizedCamera() {
        let cases: [(AVAuthorizationStatus, Bool)] = [
            (.authorized, true), (.denied, false), (.notDetermined, false), (.restricted, false)
        ]
        for (authorization, permitted) in cases {
            XCTAssertEqual(MeasurementCaptureActivation.previewIfAuthorized
                .permitsCameraStartup(authorization: authorization), permitted,
                "An uncommitted home pull must not enter camera startup for \(authorization)")
        }
    }

    func testCommittedFlowKeepsTheNormalPermissionAndUnavailableStatePath() {
        let statuses: [AVAuthorizationStatus] = [.authorized, .denied, .notDetermined, .restricted]
        for authorization in statuses {
            // Startup still owns the system request or unavailable message;
            // this policy permits that path without treating denial as consent.
            XCTAssertTrue(MeasurementCaptureActivation.active
                .permitsCameraStartup(authorization: authorization))
        }
    }

    @MainActor
    func testOrdinaryCaptureFlowsRemainActiveWithoutAHomePreviewOverride() {
        let defaults = EnvironmentValues()
        XCTAssertEqual(defaults.measurementCaptureActivation, .active)
        var homePreview = defaults
        homePreview.measurementCaptureActivation = .previewIfAuthorized
        XCTAssertEqual(homePreview.measurementCaptureActivation, .previewIfAuthorized)
        XCTAssertEqual(defaults.measurementCaptureActivation, .active)
    }
}

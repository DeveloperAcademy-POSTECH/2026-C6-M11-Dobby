//
//  CameraPreviewObservationTests.swift
//  DobbyTests
//
//  Created by mason on 10/1/26.
//

import Foundation
import Observation
import Testing
@testable import Dobby

@MainActor
struct CameraPreviewObservationTests {
    @Test func initialShutterReadObservesSessionStarting() async {
        let camera = CameraPreviewSession()
        let previewID = UUID()
        defer { camera.setActive(false, previewID: previewID) }
        await confirmation("최초 셔터 조회 후 세션 상태 변경을 감지한다") { changed in
            let canCapture = withObservationTracking { camera.canCapture } onChange: { changed() }
            #expect(!canCapture)
            camera.setActive(true, previewID: previewID)
            #expect(camera.state == .starting)
            #expect(!camera.canCapture)
        }
    }

    @Test func shutterReadObservesSessionStopping() async {
        let camera = CameraPreviewSession()
        let previewID = UUID()
        camera.setActive(true, previewID: previewID)
        await confirmation("세션 중지 시 셔터 상태를 다시 평가한다") { changed in
            _ = withObservationTracking { camera.canCapture } onChange: { changed() }
            camera.setActive(false, previewID: previewID)
            #expect(camera.state == .stopped)
            #expect(!camera.canCapture)
        }
    }

    @Test func disappearingPreviewStopsOnlyItsOwnRequest() {
        let camera = CameraPreviewSession()
        let outgoing = UUID()
        let incoming = UUID()
        camera.setActive(true, previewID: outgoing)
        camera.setActive(true, previewID: incoming)
        camera.setActive(false, previewID: outgoing)
        #expect(camera.state == .starting)
        camera.setActive(false, previewID: incoming)
        #expect(camera.state == .stopped)
    }
}

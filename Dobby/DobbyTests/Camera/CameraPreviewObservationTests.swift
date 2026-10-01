//
//  CameraPreviewObservationTests.swift
//  DobbyTests
//
//  Created by mason on 10/1/26.
//

import Observation
import Testing
@testable import Dobby

@MainActor
struct CameraPreviewObservationTests {
    @Test func initialShutterReadObservesSessionStarting() async {
        let camera = CameraPreviewSession()
        defer { camera.setActive(false) }
        await confirmation("최초 셔터 조회 후 세션 상태 변경을 감지한다") { changed in
            let canCapture = withObservationTracking { camera.canCapture } onChange: { changed() }
            #expect(!canCapture)
            camera.setActive(true)
            #expect(camera.state == .starting)
            #expect(!camera.canCapture)
        }
    }

    @Test func shutterReadObservesSessionStopping() async {
        let camera = CameraPreviewSession()
        camera.setActive(true)
        await confirmation("세션 중지 시 셔터 상태를 다시 평가한다") { changed in
            _ = withObservationTracking { camera.canCapture } onChange: { changed() }
            camera.setActive(false)
            #expect(camera.state == .stopped)
            #expect(!camera.canCapture)
        }
    }
}

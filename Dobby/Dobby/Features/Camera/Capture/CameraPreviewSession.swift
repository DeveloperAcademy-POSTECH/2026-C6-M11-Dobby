//
//  CameraPreviewSession.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import AVFoundation
import Observation

/// Mason 상세 화면 전용 세션. 실측 카메라와의 소유권 인계는 팀 통합 시 연결한다.
@MainActor
@Observable
final class CameraPreviewSession: CaptureProviding {
    enum State: Equatable, Sendable {
        case stopped, starting, running
        case unavailable(String)
    }

    private(set) var state: State = .stopped
    private(set) var isCapturing = false
    let options: DetailCameraOptions
    @ObservationIgnored private let driver = CameraPreviewDriver()
    @ObservationIgnored private let store = CameraPhotoStore()
    @ObservationIgnored var rotationAngle: CGFloat = 90
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var revision = 0

    init(optionController: any DetailCameraControlling = UnavailableDetailCameraControls()) {
        options = DetailCameraOptions(controller: optionController)
    }

    // View에는 프리뷰 레이어 연결만 허용한다. 구성·시작·중지는 driver가 직렬 처리한다.
    var session: AVCaptureSession { driver.session }
    // 최초 진입에도 관찰 가능한 state를 읽어 셔터가 세션 준비 완료를 감지하게 한다.
    var canCapture: Bool { state == .running && wantsRunning && !isCapturing }

    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
        try Task.checkCancellation()
        guard canCapture else { throw CameraFailure.cameraUnavailable }
        isCapturing = true
        defer { isCapturing = false }
        let request = revision
        let capturedAt = Date()
        let data = try await driver.capture(rotationAngle: rotationAngle)
        try Task.checkCancellation()
        guard wantsRunning, revision == request else { throw CancellationError() }
        let asset = try await store.save(data, sessionID: sessionID, garmentID: garmentID, capturedAt: capturedAt)
        do {
            try Task.checkCancellation()
            guard wantsRunning, revision == request else { throw CancellationError() }
            return asset
        } catch {
            try await store.discardUncommitted(asset)
            throw error
        }
    }

    func discardUncommitted(_ asset: CapturedAsset) async throws {
        try await store.discardUncommitted(asset)
    }

    func setActive(_ active: Bool) {
        guard wantsRunning != active else { return }
        wantsRunning = active
        updateSession()
    }

    func retry() {
        guard wantsRunning else { return }
        updateSession()
    }

    func reportUnavailable(_ message: String) {
        guard wantsRunning else { return }
        revision += 1
        state = .unavailable(message)
        options.invalidate()
        driver.cancelCapture()
    }

    private func updateSession() {
        options.invalidate()
        revision += 1
        let request = revision
        state = wantsRunning ? .starting : .stopped
        driver.setRunning(wantsRunning) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.revision == request else { return }
                self.state = result
                if result == .running { await self.options.refreshCapabilities() }
            }
        }
    }

    deinit {
        // 화면이 해제돼도 이미 큐에 들어간 시작 뒤에 중지가 실행된다.
        driver.setRunning(false) { _ in }
    }
}

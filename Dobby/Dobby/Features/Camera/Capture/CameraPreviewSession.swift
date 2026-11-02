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
    @ObservationIgnored private let processor = DetailPhotoProcessor()
    var isPreviewTransitioning = false
    @ObservationIgnored var previewCrop: (() -> CGRect?)?
    @ObservationIgnored var rotationAngle: CGFloat = 90
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var revision = 0

    init(optionController: (any DetailCameraControlling)? = nil) {
        options = DetailCameraOptions(controller: optionController ?? driver)
    }

    // View에는 프리뷰 레이어 연결만 허용한다. 구성·시작·중지는 driver가 직렬 처리한다.
    var session: AVCaptureSession { driver.session }
    // 최초 진입에도 관찰 가능한 state를 읽어 셔터가 세션 준비 완료를 감지하게 한다.
    var canCapture: Bool { state == .running && wantsRunning && !isCapturing && !options.isApplying && !isPreviewTransitioning }

    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
        try Task.checkCancellation()
        guard canCapture, let crop = previewCrop?() else { throw CameraFailure.cameraUnavailable }
        isCapturing = true
        defer { isCapturing = false }
        let request = revision
        let capturedAt = Date()
        let aspectRatio = options.photoAspectRatio
        let diagnosticID = driver.diagnostics.beginCapture()
        var diagnosticOutcome = "failed_or_cancelled"
        defer { if let diagnosticID {
            driver.diagnostics.record("capture_finished", captureID: diagnosticID, fields: ["outcome": diagnosticOutcome])
        } }
        let data = try await driver.capture(rotationAngle: rotationAngle, diagnosticID: diagnosticID)
        try Task.checkCancellation()
        guard wantsRunning, revision == request else { throw CancellationError() }
        if let diagnosticID {
            driver.diagnostics.record("processing_begin", captureID: diagnosticID, fields: [
                "aspectRatio": aspectRatio.rawValue,
                "crop": [crop.minX, crop.minY, crop.width, crop.height], "rotationAngle": rotationAngle])
        }
        let processed = try await processor.process(data, aspectRatio: aspectRatio, normalizedPreviewCrop: crop)
        if let diagnosticID {
            driver.diagnostics.save(processed, as: .processed, captureID: diagnosticID)
            driver.diagnostics.record("processing_finished", captureID: diagnosticID)
        }
        try Task.checkCancellation()
        guard wantsRunning, revision == request else { throw CancellationError() }
        let asset = try await store.save(processed, sessionID: sessionID, garmentID: garmentID, capturedAt: capturedAt)
        do {
            try Task.checkCancellation()
            guard wantsRunning, revision == request else { throw CancellationError() }
            diagnosticOutcome = "saved"
            if let diagnosticID {
                driver.diagnostics.record("photo_saved", captureID: diagnosticID, fields: ["assetID": asset.id.uuidString])
            }
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

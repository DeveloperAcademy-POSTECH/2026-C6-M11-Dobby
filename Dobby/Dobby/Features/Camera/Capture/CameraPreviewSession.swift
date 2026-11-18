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
    // Navigation may briefly display two UIKit hosts. Keep the capture graph
    // connected to one layer for the whole detail session.
    let previewLayer: AVCaptureVideoPreviewLayer
    var isPreviewTransitioning = false
    @ObservationIgnored private var visiblePreviews: Set<UUID> = []
    private var wantsRunning: Bool { !visiblePreviews.isEmpty }
    @ObservationIgnored private var revision = 0

    init(optionController: (any DetailCameraControlling)? = nil) {
        options = DetailCameraOptions(controller: optionController ?? driver)
        previewLayer = AVCaptureVideoPreviewLayer(session: driver.session)
        previewLayer.videoGravity = .resizeAspectFill
    }

    // View에는 프리뷰 레이어 연결만 허용한다. 구성·시작·중지는 driver가 직렬 처리한다.
    var session: AVCaptureSession { driver.session }
    // 최초 진입에도 관찰 가능한 state를 읽어 셔터가 세션 준비 완료를 감지하게 한다.
    var canCapture: Bool { state == .running && wantsRunning && !isCapturing && !options.isApplying && !isPreviewTransitioning }

    /// A tap or EV command must not disable its own continuing gesture. Only
    /// capture, a zoom change or a changing photo window blocks preview input.
    var canAdjustPreview: Bool {
        state == .running && wantsRunning && !isCapturing
            && !options.isApplyingZoom && !isPreviewTransitioning
    }

    func requestFocus(at point: ImagePoint, requestID: UUID) {
        guard canAdjustPreview else { return }
        options.requestFocus(at: point, requestID: requestID)
    }

    func requestExposure(_ bias: Double) {
        guard canAdjustPreview else { return }
        options.requestExposure(bias)
    }

    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
        try Task.checkCancellation()
        guard canCapture, previewLayer.superlayer != nil, !previewLayer.bounds.isEmpty,
              let connection = previewLayer.connection, connection.isActive else {
            throw CameraFailure.cameraUnavailable
        }
        let rotationAngle = connection.videoRotationAngle
        let sensorRect = previewLayer.metadataOutputRectConverted(fromLayerRect: previewLayer.bounds)
        guard let crop = DetailPreviewCropMapping.uprightRect(sensorRect, rotationAngle: rotationAngle) else {
            throw CameraFailure.cameraUnavailable
        }
        options.clearPreviewFocus()
        isCapturing = true
        defer { isCapturing = false }
        let request = revision
        let capturedAt = Date()
        let aspectRatio = options.photoAspectRatio
        let data = try await driver.capture(rotationAngle: rotationAngle)
        try Task.checkCancellation()
        guard wantsRunning, revision == request else { throw CancellationError() }
        let processed = try await processor.process(data, aspectRatio: aspectRatio, normalizedPreviewCrop: crop)
        try Task.checkCancellation()
        guard wantsRunning, revision == request else { throw CancellationError() }
        let asset = try await store.save(processed, sessionID: sessionID, garmentID: garmentID, capturedAt: capturedAt)
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

    func setActive(_ active: Bool, previewID: UUID) {
        let wasRunningRequested = wantsRunning
        if active { visiblePreviews.insert(previewID) }
        else { visiblePreviews.remove(previewID) }
        guard wantsRunning != wasRunningRequested else { return }
        updateSession()
    }

    func stop() {
        guard wantsRunning else { return }
        visiblePreviews.removeAll()
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

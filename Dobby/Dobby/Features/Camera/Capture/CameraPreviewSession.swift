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
final class CameraPreviewSession {
    enum State: Equatable, Sendable {
        case stopped, starting, running
        case unavailable(String)
    }

    private(set) var state: State = .stopped
    @ObservationIgnored private let driver = CameraPreviewDriver()
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var revision = 0

    // View에는 프리뷰 레이어 연결만 허용한다. 구성·시작·중지는 driver가 직렬 처리한다.
    var session: AVCaptureSession { driver.session }

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
    }

    private func updateSession() {
        revision += 1
        let request = revision
        state = wantsRunning ? .starting : .stopped
        driver.setRunning(wantsRunning) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.revision == request else { return }
                self.state = result
            }
        }
    }

    deinit {
        // 화면이 해제돼도 이미 큐에 들어간 시작 뒤에 중지가 실행된다.
        driver.setRunning(false) { _ in }
    }
}

/// Capture 폴더 담당: mason. 가변 세션 작업을 전용 직렬 큐에 가두는 경계다.
/// @unchecked Sendable은 이 큐 소유권에 한정한다. UI는 session을 레이어에 연결만 한다.
private nonisolated final class CameraPreviewDriver: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.dobby.camera.detail-preview", qos: .userInitiated)

    func setRunning(_ active: Bool, completion: @escaping @Sendable (CameraPreviewSession.State) -> Void) {
        queue.async { [self] in
            if active {
                completion(start())
            } else {
                // 중단 상태의 자동 재개 요청도 해제한다. isRunning만으로 중지를 생략하지 않는다.
                session.stopRunning()
                completion(.stopped)
            }
        }
    }

    private func start() -> CameraPreviewSession.State {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return .unavailable("카메라 권한을 확인해 주세요.")
        }
        if session.inputs.isEmpty {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                return .unavailable("후면 카메라를 사용할 수 없어요. 실기기에서 확인해 주세요.")
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                guard session.canAddInput(input) else {
                    return .unavailable("카메라를 연결할 수 없어요. 다시 시도해 주세요.")
                }
                if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                session.addInput(input)
            } catch {
                return .unavailable("카메라를 준비하지 못했어요. 다시 시도해 주세요.")
            }
        }
        guard !session.isInterrupted else {
            return .unavailable("카메라 사용이 잠시 중단됐어요. 다른 카메라 사용이 끝나면 다시 시도해 주세요.")
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning ? .running : .unavailable("카메라를 시작하지 못했어요. 다시 시도해 주세요.")
    }
}

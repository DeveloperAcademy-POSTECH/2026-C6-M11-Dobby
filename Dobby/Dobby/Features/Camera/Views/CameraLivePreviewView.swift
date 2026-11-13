//
//  CameraLivePreviewView.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import AVFoundation
import Combine
import SwiftUI

/// 권한이 허용된 상세 촬영 화면에서만 삽입한다. 셔터와 동일한 세션을 전달받는다.
struct CameraLivePreviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    let camera: CameraPreviewSession
    var aspectRatio: DetailPhotoAspectRatio = .fourThree
    var portraitPhotoTop: CGFloat? = nil
    var interactionEnabled = true
    @State private var isVisible = false

    var body: some View {
        DetailAspectRatioPreview(aspectRatio: aspectRatio, prefersBottomAlignedPortrait: true,
                               portraitPhotoTop: portraitPhotoTop) { photoRect in
            CameraPreviewSurface(session: camera.session, photoRect: photoRect,
                onRotationChange: { camera.rotationAngle = $0 },
                onFramingReady: { camera.previewCrop = $0 },
                interactionEnabled: interactionEnabled && scenePhase == .active && camera.canAdjustPreview,
                controlCapabilities: camera.options.previewControlCapabilities,
                controlState: camera.options.previewControlState,
                onFocus: { camera.requestFocus(at: $0, requestID: $1) },
                onExposure: { camera.requestExposure($0) })
        }
            .accessibilityLabel("후면 카메라 실시간 미리보기")
            .overlay {
                switch camera.state {
                case .running: EmptyView()
                case .starting: ProgressView("카메라 준비 중")
                case .stopped: Text("카메라 미리보기가 일시 정지됐어요.")
                case .unavailable(let message):
                    VStack(spacing: 16) {
                        Text(message).multilineTextAlignment(.center)
                        Button("다시 시도", action: camera.retry).buttonStyle(.borderedProminent)
                    }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                }
            }
            .clipped()
            .task(id: aspectRatio) {
                camera.isPreviewTransitioning = true
                camera.options.clearPreviewFocus(cancelPendingRequests: true)
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                camera.isPreviewTransitioning = false
            }
            .onAppear {
                isVisible = true
                camera.setActive(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in camera.setActive(isVisible && phase == .active) }
            .onDisappear {
                isVisible = false
                camera.previewCrop = nil
                camera.setActive(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: camera.session).receive(on: DispatchQueue.main)) { _ in
                camera.reportUnavailable("카메라 오류가 발생했어요. 다시 시도해 주세요.")
            }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification, object: camera.session).receive(on: DispatchQueue.main)) { _ in
                camera.reportUnavailable("카메라 사용이 잠시 중단됐어요. 잠시 후 다시 시도해 주세요.")
            }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification, object: camera.session).receive(on: DispatchQueue.main)) { _ in
                camera.retry()
            }
    }
}

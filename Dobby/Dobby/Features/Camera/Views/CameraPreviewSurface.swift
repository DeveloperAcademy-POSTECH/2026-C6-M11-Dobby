//
//  CameraPreviewSurface.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import AVFoundation
import SwiftUI
import UIKit

/// 영상 표시만 담당한다. 카메라 구성·시작·중지는 CameraPreviewSession의 책임이다.
struct CameraPreviewSurface: UIViewRepresentable {
    let session: AVCaptureSession
    var onRotationChange: (CGFloat) -> Void = { _ in }

    var onFramingReady: (@escaping () -> CGRect?) -> Void = { _ in }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        view.onRotationChange = onRotationChange
        onFramingReady { [weak view] in view?.normalizedPhotoCrop() }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.onRotationChange = onRotationChange
        view.updateRotation()
        onFramingReady { [weak view] in view?.normalizedPhotoCrop() }
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.previewLayer.session = nil
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onRotationChange: (CGFloat) -> Void = { _ in }

        /// 프리뷰 자체가 사진 영역 크기이므로 화면 좌표가 아닌 로컬 bounds를 변환한다.
        /// 촬영 직전의 실제 레이어 크기·렌즈·줌을 저장 크롭에도 동일하게 적용한다.
        func normalizedPhotoCrop() -> CGRect? {
            layoutIfNeeded()
            guard let connection = previewLayer.connection, connection.isActive,
                  !bounds.isEmpty else { return nil }
            let sensorRect = previewLayer.metadataOutputRectConverted(fromLayerRect: bounds)
            return DetailPreviewCropMapping.uprightRect(sensorRect, rotationAngle: connection.videoRotationAngle)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateRotation()
        }

        func updateRotation() {
            guard let connection = previewLayer.connection,
                  let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation else { return }
            let angle: CGFloat
            switch orientation {
            case .portrait: angle = 90
            case .portraitUpsideDown: angle = 270
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            default: return
            }
            // 비율 전환 중 매 프레임 재배치되어도 실제 방향이 바뀔 때만 연결을 갱신한다.
            if connection.videoRotationAngle != angle, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            onRotationChange(angle)
        }
    }
}

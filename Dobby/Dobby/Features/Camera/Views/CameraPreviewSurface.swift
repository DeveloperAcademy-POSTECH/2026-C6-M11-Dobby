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
    var viewport: CGRect = .zero
    var onRotationChange: (CGFloat) -> Void = { _ in }

    var onFramingReady: (@escaping () -> CGRect?) -> Void = { _ in }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        view.onRotationChange = onRotationChange
        view.viewport = viewport
        onFramingReady { [weak view] in view?.normalizedPhotoCrop() }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.onRotationChange = onRotationChange
        view.viewport = viewport
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
        var viewport: CGRect = .zero

        /// 변환은 촬영 직전에 수행해 화면 크기·렌즈·줌의 최신 구도를 사용한다.
        func normalizedPhotoCrop() -> CGRect? {
            guard let connection = previewLayer.connection, connection.isActive,
                  !viewport.isEmpty, bounds.contains(viewport) else { return nil }
            let sensorRect = previewLayer.metadataOutputRectConverted(fromLayerRect: viewport)
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

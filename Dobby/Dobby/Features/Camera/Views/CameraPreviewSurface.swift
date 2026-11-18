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
    let previewLayer: AVCaptureVideoPreviewLayer
    /// Surface-local photograph bounds, excluding decorative camera surroundings.
    /// Nil preserves the full-surface contract for callers without camera chrome.
    var photoRect: CGRect?
    var interactionEnabled = false
    var controlCapabilities = CameraControlCapabilities.unavailable
    var controlState: CameraControlState?
    var onFocus: (ImagePoint, UUID) -> Void = { _, _ in }
    var onExposure: (Double) -> Void = { _ in }
    var onExposureAdjustmentActive: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero, previewLayer: previewLayer)
        configure(view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        configure(view)
        view.updateRotation()
    }

    private func configure(_ view: PreviewView) {
        view.photoRect = photoRect
        view.interactionEnabled = interactionEnabled
        view.controlCapabilities = controlCapabilities
        view.controlState = controlState
        view.onFocus = onFocus
        view.onExposure = onExposure
        view.onExposureAdjustmentActive = onExposureAdjustmentActive
        view.updateFocus()
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.tearDownInteraction()
    }

    final class PreviewView: UIView {
        private let previewLayer: AVCaptureVideoPreviewLayer
        private var hostsPreview: Bool { previewLayer.superlayer === layer }
        var photoRect: CGRect? {
            didSet { if photoRect != oldValue { invalidateFocusFeedback() } }
        }
        var photoViewport: CGRect {
            guard let photoRect else { return bounds }
            guard [photoRect.minX, photoRect.minY, photoRect.width, photoRect.height].allSatisfy(\.isFinite),
                  photoRect.width > 0, photoRect.height > 0 else { return .zero }
            let clipped = photoRect.intersection(bounds)
            return clipped.isNull ? .zero : clipped
        }
        var interactionEnabled = false
        var controlCapabilities = CameraControlCapabilities.unavailable
        var controlState: CameraControlState? {
            didSet {
                if oldValue?.sessionID != controlState?.sessionID
                    || oldValue?.selectedZoom != controlState?.selectedZoom
                    || oldValue?.settingsRevision != controlState?.settingsRevision {
                    invalidateFocusFeedback()
                }
            }
        }
        var onFocus: (ImagePoint, UUID) -> Void = { _, _ in }
        var onExposure: (Double) -> Void = { _ in }
        var onExposureAdjustmentActive: (Bool) -> Void = { _ in }
        private lazy var focusRenderer = CameraFocusIndicatorRenderer(containerView: self)
        private lazy var interaction = CameraPreviewInteraction(view: self)
        private var lastBounds = CGRect.zero
        private var lastOrientation: UIInterfaceOrientation?
        private var reduceMotionObserver: NSObjectProtocol?

        init(frame: CGRect, previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            super.init(frame: frame)
            clipsToBounds = true
            reduceMotionObserver = NotificationCenter.default.addObserver(
                forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateFocus() }
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// The preview layer already knows its aspect-fill crop, orientation,
        /// mirroring and zoom. Device controls need its uncropped sensor point.
        private func sensorPoint(at location: CGPoint) -> ImagePoint? {
            guard hostsPreview, interactionEnabled, window != nil, previewLayer.connection?.isActive == true,
                  !photoViewport.isEmpty, photoViewport.contains(location) else { return nil }
            let converted = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
            let point = ImagePoint(x: Double(converted.x), y: Double(converted.y))
            return point.isValid ? point : nil
        }

        func updateFocus() {
            let enabled = hostsPreview && interactionEnabled && controlCapabilities.focusSupported
                && window != nil && !photoViewport.isEmpty && previewLayer.connection?.isActive == true
            interaction.capabilities = controlCapabilities
            interaction.visibleViewport = photoViewport
            interaction.sensorPoint = { [weak self] in self?.sensorPoint(at: $0) }
            interaction.onFocus = onFocus
            interaction.onExposure = onExposure
            interaction.onExposureAdjustmentActive = onExposureAdjustmentActive
            interaction.renderer = focusRenderer
            interaction.pointLabel = "초점 요청 위치"
            interaction.reduceMotion = UIAccessibility.isReduceMotionEnabled
            if interaction.enabled != enabled { interaction.enabled = enabled }
            interaction.synchronize(state: controlState, viewportHeight: Double(photoViewport.height))
            guard enabled, let feedback = interaction.focusFeedback() else {
                interaction.cancelAdjustment()
                focusRenderer.clear()
                return
            }
            let displayed = previewLayer.layerPointConverted(fromCaptureDevicePoint:
                CGPoint(x: feedback.point.x, y: feedback.point.y))
            focusRenderer.update(point: displayed, requestID: feedback.requestID,
                visibleViewport: photoViewport, exposureBias: interaction.presentationExposureBias,
                exposureRange: controlCapabilities.exposureRange,
                onExposure: { [weak self] in self?.interaction.requestAccessibleExposure($0) },
                reduceMotion: UIAccessibility.isReduceMotionEnabled)
        }

        func invalidateFocusFeedback() { interaction.invalidateFocusFeedback() }

        func tearDownInteraction() {
            interaction.tearDown()
            focusRenderer.tearDown()
            onFocus = { _, _ in }
            onExposure = { _ in }
            onExposureAdjustmentActive = { _ in }
            if hostsPreview { previewLayer.removeFromSuperlayer() }
            if let reduceMotionObserver {
                NotificationCenter.default.removeObserver(reduceMotionObserver)
                self.reduceMotionObserver = nil
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if hostsPreview {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                previewLayer.frame = bounds
                CATransaction.commit()
            }
            if lastBounds != bounds {
                invalidateFocusFeedback()
                lastBounds = bounds
            }
            updateRotation()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                layer.insertSublayer(previewLayer, at: 0)
                setNeedsLayout()
                updateRotation()
            } else {
                if hostsPreview { previewLayer.removeFromSuperlayer() }
                invalidateFocusFeedback()
            }
        }

        func updateRotation() {
            guard hostsPreview, let connection = previewLayer.connection,
                  let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation else {
                updateFocus()
                return
            }
            if lastOrientation != orientation {
                invalidateFocusFeedback()
                lastOrientation = orientation
            }
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
            updateFocus()
        }
    }
}

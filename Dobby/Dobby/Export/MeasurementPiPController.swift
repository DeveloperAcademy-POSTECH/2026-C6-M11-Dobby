@preconcurrency import AVKit
import CoreImage
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

@MainActor
final class MeasurementPiPController: NSObject {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let imageContext = CIContext()
    private var pictureInPictureController: AVPictureInPictureController?
    private var startError: Error?

    func attach(to view: UIView) {
        if displayLayer.superlayer !== view.layer {
            displayLayer.removeFromSuperlayer()
            view.layer.addSublayer(displayLayer)
        }
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect

        guard pictureInPictureController == nil else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.requiresLinearPlayback = true
        pictureInPictureController = controller
    }

    /// 현재 상품의 실측표를 렌더링하고 PiP가 화면에 뜰 때까지 기다립니다.
    func start(measurements: [ExportMeasurement]) async throws {
        guard [4, 5].contains(measurements.count) else {
            throw MeasurementPiPError.unsupportedMeasurementCount
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw MeasurementPiPError.unsupportedDevice
        }
        guard let controller = pictureInPictureController else {
            throw MeasurementPiPError.sourceNotReady
        }
        if controller.isPictureInPictureActive { return }

        try configureAudioSession()
        let sampleBuffer = try makeSampleBuffer(measurements: measurements)
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
        }
        renderer.enqueue(sampleBuffer)

        guard await waitUntilPossible(controller) else {
            throw MeasurementPiPError.sourceNotReady
        }

        startError = nil
        controller.startPictureInPicture()
        for _ in 0..<20 {
            if controller.isPictureInPictureActive { return }
            if let startError { throw startError }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MeasurementPiPError.startTimedOut
    }

    func stop() {
        pictureInPictureController?.stopPictureInPicture()
    }

    private func waitUntilPossible(_ controller: AVPictureInPictureController) async -> Bool {
        for _ in 0..<20 {
            if controller.isPictureInPicturePossible { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setActive(true)
    }

    private func makeSampleBuffer(measurements: [ExportMeasurement]) throws -> CMSampleBuffer {
        let renderer = ImageRenderer(
            content: MeasurementPiPView(measurements: measurements)
                .frame(width: MeasurementPiPView.size.width, height: MeasurementPiPView.size.height)
        )
        renderer.scale = 2
        guard let image = renderer.uiImage,
              let cgImage = image.cgImage else {
            throw MeasurementPiPError.renderFailed
        }

        let pixelBuffer = try makePixelBuffer(from: cgImage)
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw MeasurementPiPError.sampleBufferFailed(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw MeasurementPiPError.sampleBufferFailed(sampleStatus)
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    private func makePixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw MeasurementPiPError.pixelBufferFailed(status)
        }
        imageContext.render(
            CIImage(cgImage: image),
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return pixelBuffer
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension MeasurementPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        startError = error
        deactivateAudioSession()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
        deactivateAudioSession()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

extension MeasurementPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) { }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) { }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        true
    }
}

private enum MeasurementPiPError: LocalizedError {
    case pixelBufferFailed(CVReturn)
    case renderFailed
    case sampleBufferFailed(OSStatus)
    case sourceNotReady
    case startTimedOut
    case unsupportedDevice
    case unsupportedMeasurementCount

    var errorDescription: String? {
        switch self {
        case .pixelBufferFailed, .renderFailed, .sampleBufferFailed:
            "실측표 화면을 만들지 못했어요. 다시 시도해 주세요."
        case .sourceNotReady, .startTimedOut:
            "PiP를 시작하지 못했어요. 잠시 후 다시 시도해 주세요."
        case .unsupportedDevice:
            "이 기기에서는 PiP를 사용할 수 없어요."
        case .unsupportedMeasurementCount:
            "표시할 실측 정보를 확인해 주세요."
        }
    }
}

struct MeasurementPiPSourceView: UIViewRepresentable {
    let controller: MeasurementPiPController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.attach(to: uiView)
    }
}

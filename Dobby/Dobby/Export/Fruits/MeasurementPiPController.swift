@preconcurrency import AVKit
import CoreImage
import CoreMedia
import CoreVideo
import OSLog
import SwiftUI
import UIKit

@MainActor
final class MeasurementPiPController: NSObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Dobby",
        category: "MeasurementPiP"
    )

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let imageContext = CIContext()
    private var isPlaybackPaused = false
    private var pictureInPictureController: AVPictureInPictureController?
    private var shouldStopWhenStarted = false
    private var startError: Error?
    private weak var sourceView: UIView?

    func attach(to view: UIView) {
        sourceView = view
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

        sourceView?.layoutIfNeeded()
        if let sourceView {
            displayLayer.frame = sourceView.bounds
        }
        guard displayLayer.bounds.width > 0, displayLayer.bounds.height > 0 else {
            Self.logger.error("PiP source has empty bounds.")
            throw MeasurementPiPError.sourceNotReady
        }

        shouldStopWhenStarted = false
        do {
            try configureAudioSession()
            let sampleBuffer = try makeSampleBuffer(measurements: measurements)
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            }
            renderer.enqueue(sampleBuffer)

            guard try await waitUntilPossible(controller) else {
                Self.logger.error(
                    "PiP remained unavailable. width=\(self.displayLayer.bounds.width) height=\(self.displayLayer.bounds.height) rendererStatus=\(self.displayLayer.sampleBufferRenderer.status.rawValue)"
                )
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
        } catch {
            shouldStopWhenStarted = true
            controller.stopPictureInPicture()
            resetPlaybackResources()
            throw error
        }
    }

    func stop() {
        shouldStopWhenStarted = true
        pictureInPictureController?.stopPictureInPicture()
        if pictureInPictureController?.isPictureInPictureActive != true {
            resetPlaybackResources()
        }
    }

    private func waitUntilPossible(_ controller: AVPictureInPictureController) async throws -> Bool {
        for _ in 0..<20 {
            if controller.isPictureInPicturePossible { return true }
            try await Task.sleep(for: .milliseconds(50))
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
                .frame(
                    width: MeasurementPiPView.renderSize.width,
                    height: MeasurementPiPView.renderSize.height
                )
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

    private func resetPlaybackResources() {
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
        isPlaybackPaused = false
        deactivateAudioSession()
    }
}

extension MeasurementPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        if shouldStopWhenStarted {
            pictureInPictureController.stopPictureInPicture()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        startError = error
        Self.logger.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
        resetPlaybackResources()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        shouldStopWhenStarted = false
        resetPlaybackResources()
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
    ) {
        isPlaybackPaused = !playing
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        isPlaybackPaused
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
        false
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
        MeasurementPiPContainerView(controller: controller)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.attach(to: uiView)
    }
}

private final class MeasurementPiPContainerView: UIView {
    private let controller: MeasurementPiPController

    init(controller: MeasurementPiPController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        controller.attach(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller.attach(to: self)
    }
}

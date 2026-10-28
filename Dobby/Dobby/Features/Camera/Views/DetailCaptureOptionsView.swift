// Created by mason on 10/20/26.
import SwiftUI

/// 상세·실측 카메라 Model을 공용 옵션 UI의 값/콜백으로 연결한다.
struct DetailCaptureOptionsView: View {
    let options: DetailCameraOptions?
    let presentation: DetailCaptureOptionsPresentation
    private let selection: Binding<DetailCaptureOptionsDestination>?
    private let forceReduceMotion: Bool
    let onClose: () -> Void

    init(options: DetailCameraOptions? = nil,
         presentation: DetailCaptureOptionsPresentation = .standard,
         selection: Binding<DetailCaptureOptionsDestination>? = nil,
         forceReduceMotion: Bool = false,
         onClose: @escaping () -> Void) {
        self.options = options
        self.presentation = presentation
        self.selection = selection
        self.forceReduceMotion = forceReduceMotion
        self.onClose = onClose
    }

    var body: some View {
        CameraCaptureOptionsView(state: state,
            onExposureChange: { options?.requestExposure($0) },
            onAspectRatioChange: { value in
                guard let ratio = DetailPhotoAspectRatio(rawValue: value) else { return }
                options?.photoAspectRatio = ratio
            }, presentation: presentation, selection: selection,
            forceReduceMotion: forceReduceMotion, onClose: onClose)
    }

    private var state: CameraOptionsState {
        guard let options else { return CameraOptionsState() }
        return CameraOptionsState(
            exposureRange: options.capabilities.exposure.map { $0.minimum...$0.maximum },
            appliedExposure: options.appliedExposure,
            isApplying: options.isApplying,
            hasExposureFailure: options.failure != nil,
            selectedAspectRatio: options.photoAspectRatio.rawValue,
            aspectRatios: DetailPhotoAspectRatio.allCases.map(\.rawValue))
    }
}

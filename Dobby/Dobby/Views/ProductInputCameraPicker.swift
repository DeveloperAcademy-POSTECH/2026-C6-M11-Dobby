import SwiftUI

/// Reuses the detail camera without entering measurement or creating another
/// product. This session owns only new captures; the input/edit draft stays put.
struct ProductInputCameraPicker: View {
    @State private var model: AdditionalProductPhotoModel
    @State private var camera: CameraPreviewSession?
    @State private var permission: CameraPermission
    private let previewSource: CapturedAsset.Source?
    private let onCancel: () -> Void
    private let onComplete: ([CapturedAsset]) async throws -> Void
    @State private var hasFinished = false

    init(garmentID: UUID, fixtureSource: CapturedAsset.Source? = nil,
         onCancel: @escaping () -> Void,
         onComplete: @escaping ([CapturedAsset]) async throws -> Void) {
        self.onCancel = onCancel
        self.onComplete = onComplete
#if DEBUG
        if ProductAppStorage.fixtureDirectory != nil, let fixtureSource {
            _model = State(initialValue: AdditionalProductPhotoModel(garmentID: garmentID,
                captureProvider: ProductPhotoFixtureCaptureProvider(seed: fixtureSource,
                    directory: ProductAppStorage.fixtureDirectory?.appending(path: "input-captures"))))
            _permission = State(initialValue: CameraPermission(authorizer: MockCameraAuthorization()))
            _camera = State(initialValue: nil)
            previewSource = fixtureSource
            return
        }
#endif
        let session = CameraPreviewSession()
        _model = State(initialValue: AdditionalProductPhotoModel(garmentID: garmentID, captureProvider: session))
        _camera = State(initialValue: session)
        _permission = State(initialValue: CameraPermission(authorizer: SystemCameraAuthorization()))
        previewSource = nil
    }

    var body: some View {
        NavigationStack {
            CameraFlowView(model: model, permission: permission, camera: camera,
                previewSource: previewSource, showsCreationProgress: false,
                onExit: cancel) { output in
                    guard !hasFinished else { return }
                    // CameraFlowView keeps its input lock and saving overlay
                    // until every product copy has been appended successfully.
                    try await onComplete(output.detailPhotos)
                    finish()
                }
        }
        .interactiveDismissDisabled()
    }

    private func cancel() {
        guard !hasFinished else { return }
        finish()
        onCancel()
    }

    private func finish() {
        hasFinished = true
        camera?.setActive(false)
        // Do not attach cleanup to onDisappear: presenting the shared capture
        // gallery also hides this screen, but must retain its temporary files.
        Task { await model.discardTemporaryPhotos() }
    }
}

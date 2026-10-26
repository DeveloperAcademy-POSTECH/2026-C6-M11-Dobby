import Combine
import OSLog

/// One owner per displayed flow. SwiftUI may recreate its View value without
/// constructing discarded AR sessions, image contexts or model adapters.
@MainActor
final class GarmentCaptureSession: ObservableObject {
    let camera = ARKitCaptureProvider()
    @Published private(set) var service: RecordedMeasurementService?
    @Published private(set) var loadingError: String?

    private static let recognizers = AsyncResourceCache<AutoGarmentLandmarkProvider> {
        // Schema I/O and image-context construction belong off the UI actor.
        // Models remain lazy; this does not launch competing warm-up predictions.
        try AutoGarmentLandmarkProvider.bundled()
    }
    private static let signposter = OSSignposter(subsystem: "com.dobby.performance", category: "CaptureSetup")
    private var cameraChanges: AnyCancellable?
    private var preparationID: UUID?

    init() {
        cameraChanges = camera.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func prepare() async {
        guard service == nil, camera.isSupported else { return }
        let token = UUID()
        preparationID = token
        loadingError = nil
        let interval = Self.signposter.beginInterval("CaptureServicePreparation",
            id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("CaptureServicePreparation", interval) }
        do {
            let recognizer = try await Self.recognizers.value()
            try Task.checkCancellation()
            guard preparationID == token else { return }
            service = RecordedMeasurementService(workflow: AutomaticMeasurementWorkflow(camera: camera,
                landmarks: recognizer, definitions: [], expectedLandmarkOrigin: .model),
                journal: LiDARAppServices.attemptJournal)
        } catch is CancellationError {
            // Closing a screen cannot publish late setup or evict a shared model.
        } catch {
            guard preparationID == token, !Task.isCancelled else { return }
            loadingError = error.localizedDescription
        }
    }
}

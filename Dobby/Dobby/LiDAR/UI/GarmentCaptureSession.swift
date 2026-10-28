import Combine
import OSLog

/// One owner per displayed flow. SwiftUI may recreate its View value without
/// constructing discarded AR sessions, image contexts or model adapters.
@MainActor
final class GarmentCaptureSession: ObservableObject {
    let camera: ARKitCaptureProvider
    let cameraOptions: DetailCameraOptions
    @Published private(set) var service: RecordedMeasurementService?
    @Published private(set) var loadingError: String?

    private static let recognizers = AsyncResourceCache<AutoGarmentLandmarkProvider> {
        // Schema I/O and image-context construction belong off the UI actor.
        // Models remain lazy; this does not launch competing warm-up predictions.
        try AutoGarmentLandmarkProvider.bundled()
    }
    private static let signposter = OSSignposter(subsystem: "com.dobby.performance", category: "CaptureSetup")
    private var cameraChanges: AnyCancellable?
    private var cameraOptionsSync: Task<Void, Never>?
    private var previousCameraOptionsSnapshot: LiDARDetailCameraSnapshot?
    private var preparationID: UUID?

    init() {
        let camera = ARKitCaptureProvider()
        self.camera = camera
        cameraOptions = DetailCameraOptions(controller: LiDARDetailCameraControls(camera: camera))
        camera.onExternalControlIntent = { [weak options = cameraOptions] in
            // Do not wait for Combine's deferred snapshot synchronization: an
            // older menu continuation could otherwise drain its next EV first.
            options?.invalidatePendingRequestsForExternalIntent()
        }
        cameraChanges = camera.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            self?.scheduleCameraOptionsSync()
        }
        synchronizeCameraOptions()
    }

    /// Call before opening the shared panels as well as after camera updates.
    /// The snapshot also reads buffered EV, so a just-finished gesture need not
    /// wait for its deferred SwiftUI publication before the menu opens.
    func synchronizeCameraOptions() {
        let snapshot = camera.detailCameraSnapshot
        let previous = previousCameraOptionsSnapshot
        let invalidates = previous?.sessionID != snapshot.sessionID
            || previous?.externalRevision != snapshot.externalRevision
            || previous?.capabilities.exposure != snapshot.capabilities.exposure
        cameraOptions.synchronizeExternalState(capabilities: snapshot.capabilities,
            invalidatePendingRequests: invalidates)
        previousCameraOptionsSnapshot = snapshot
    }

    private func scheduleCameraOptionsSync() {
        guard cameraOptionsSync == nil else { return }
        // Combine emits before @Published assigns. Coalesce related fields,
        // then read their coherent values on the next MainActor turn.
        cameraOptionsSync = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            cameraOptionsSync = nil
            synchronizeCameraOptions()
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

import Foundation
import Observation

/// A separate, temporary capture session for an already-open information draft.
/// Existing product photos never enter this session, so cancel cannot change
/// them and completion saves/returns only the newly captured detail originals.
@MainActor
@Observable
final class AdditionalProductPhotoModel: DetailPhotoCaptureModeling {
    let sessionID: UUID
    let garmentID: UUID
    private(set) var detailPhotos: [CapturedAsset] = []
    private(set) var isCapturing = false
    private(set) var isDeleting = false
    private(set) var hasAcknowledgedCaptureGuide = true
    @ObservationIgnored private let captureProvider: any CaptureProviding
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var revision = 0

    init(garmentID: UUID, sessionID: UUID = UUID(), captureProvider: any CaptureProviding) {
        self.garmentID = garmentID
        self.sessionID = sessionID
        self.captureProvider = captureProvider
    }

    var photos: [CapturedAsset] { detailPhotos }
    var selectablePhotos: [CapturedAsset] { detailPhotos }
    var measurementRecord: SavedMeasurement? { nil }
    var allPhotosOutput: ProductPhotoOutput? {
        guard !isClosed, !isCapturing, !isDeleting, let first = detailPhotos.first else { return nil }
        return ProductPhotoOutput(sessionID: sessionID, garmentID: garmentID,
            detailPhotos: detailPhotos, selectedPhotos: detailPhotos, representativePhotoID: first.id)
    }

    func acknowledgeCaptureGuide() { hasAcknowledgedCaptureGuide = true }

    func captureDetail() async throws {
        try Task.checkCancellation()
        guard !isClosed, !isCapturing, !isDeleting else { throw CameraFailure.operationInProgress }
        isCapturing = true
        defer { isCapturing = false }
        let request = revision
        let photo = try await captureProvider.capture(sessionID: sessionID, garmentID: garmentID)
        do {
            try Task.checkCancellation()
            guard !isClosed, request == revision else { throw CancellationError() }
            guard photo.sessionID == sessionID, photo.garmentID == garmentID,
                  photo.purpose == .detail, !detailPhotos.contains(where: { $0.id == photo.id }) else {
                throw CameraFailure.mismatchedCapture
            }
            detailPhotos.append(photo)
        } catch {
            if !detailPhotos.contains(where: { $0.id == photo.id }) {
                try? await captureProvider.discardUncommitted(photo)
            }
            throw error
        }
    }

    func deletePhoto(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard !isClosed, !isCapturing, !isDeleting else { throw CameraFailure.operationInProgress }
        guard let photo = detailPhotos.first(where: { $0.id == id }) else { throw CameraFailure.missingCapture }
        isDeleting = true
        defer { isDeleting = false }
        // Finish file deletion and the list update together, even if its view
        // disappears after the irreversible file operation has begun.
        try await Task { @MainActor in
            try await captureProvider.discardUncommitted(photo)
            detailPhotos.removeAll { $0.id == id }
        }.value
    }

    /// Only this session's temporary camera originals are owned here. Imported
    /// product copies and Photos-library assets are owned by their own stores.
    func discardTemporaryPhotos() async {
        isClosed = true
        revision += 1
        let pending = detailPhotos
        detailPhotos = []
        for photo in pending { try? await captureProvider.discardUncommitted(photo) }
    }
}

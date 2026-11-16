import Foundation
import Observation

/// A separate, temporary capture session for an already-open information draft.
/// Existing product photos are borrowed for browsing, not owned by this session.
/// Cancel discards only new originals; Done returns new captures and staged exclusions.
@MainActor
@Observable
final class AdditionalProductPhotoModel: DetailPhotoCaptureModeling {
    let sessionID: UUID
    let garmentID: UUID
    private(set) var newlyCapturedPhotos: [CapturedAsset] = []
    private(set) var removedExistingPhotoIDs: Set<UUID> = []
    @ObservationIgnored private let existingPhotos: [CapturedAsset]
    private(set) var isCapturing = false
    private(set) var isDeleting = false
    private(set) var hasAcknowledgedCaptureGuide = true
    @ObservationIgnored private let captureProvider: any CaptureProviding
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var revision = 0

    init(garmentID: UUID, sessionID: UUID = UUID(), existingPhotos: [CapturedAsset] = [],
         captureProvider: any CaptureProviding) {
        self.garmentID = garmentID
        self.sessionID = sessionID
        self.captureProvider = captureProvider
        self.existingPhotos = existingPhotos
    }

    var photos: [CapturedAsset] {
        guard !isClosed else { return [] }
        return existingPhotos.filter { !removedExistingPhotoIDs.contains($0.id) } + newlyCapturedPhotos
    }
    var selectablePhotos: [CapturedAsset] { photos }
    var detailPhotos: [CapturedAsset] { photos.filter { $0.purpose == .detail } }
    var photosRequiringLibrarySave: [CapturedAsset] { newlyCapturedPhotos }
    var measurementRecord: SavedMeasurement? { nil }
    var allPhotosOutput: ProductPhotoOutput? {
        guard !isClosed, !isCapturing, !isDeleting, let first = photos.first else { return nil }
        return ProductPhotoOutput(sessionID: sessionID, garmentID: garmentID,
            detailPhotos: detailPhotos, selectedPhotos: photos, representativePhotoID: first.id,
            deletedPhotoIDs: removedExistingPhotoIDs)
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
                  photo.purpose == .detail, !existingPhotos.contains(where: { $0.id == photo.id }),
                  !borrowsSource(of: photo), !newlyCapturedPhotos.contains(where: { $0.id == photo.id }) else {
                throw CameraFailure.mismatchedCapture
            }
            newlyCapturedPhotos.append(photo)
        } catch {
            if !existingPhotos.contains(where: { $0.id == photo.id }), !borrowsSource(of: photo),
               !newlyCapturedPhotos.contains(where: { $0.id == photo.id }) {
                try? await captureProvider.discardUncommitted(photo)
            }
            throw error
        }
    }

    func deletePhoto(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard !isClosed, !isCapturing, !isDeleting else { throw CameraFailure.operationInProgress }
        guard let photo = photos.first(where: { $0.id == id }) else { throw CameraFailure.missingCapture }
        if existingPhotos.contains(where: { $0.id == id }) {
            // A borrowed product file remains owned by the input/edit draft.
            // Apply only its exclusion after Done; cancel leaves that draft alone.
            removedExistingPhotoIDs.insert(id)
            return
        }
        isDeleting = true
        defer { isDeleting = false }
        // Finish file deletion and the list update together, even if its view
        // disappears after the irreversible file operation has begun.
        try await Task { @MainActor in
            try await captureProvider.discardUncommitted(photo)
            newlyCapturedPhotos.removeAll { $0.id == id }
        }.value
    }

    private func borrowsSource(of photo: CapturedAsset) -> Bool {
        guard case let .localFile(url, _) = photo.source else { return false }
        return existingPhotos.contains {
            guard case let .localFile(existingURL, _) = $0.source else { return false }
            return existingURL.standardizedFileURL == url.standardizedFileURL
        }
    }

    /// Only this session's temporary camera originals are owned here. Imported
    /// product copies and Photos-library assets are owned by their own stores.
    func discardTemporaryPhotos() async {
        isClosed = true
        revision += 1
        let pending = newlyCapturedPhotos
        newlyCapturedPhotos = []
        removedExistingPhotoIDs = []
        for photo in pending { try? await captureProvider.discardUncommitted(photo) }
    }
}

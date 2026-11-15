import Foundation

/// The detail camera and its gallery need only a capture session, not a LiDAR
/// result or the complete product-creation draft. Both entry points share this UI.
@MainActor
protocol DetailPhotoCaptureModeling: AnyObject {
    var photos: [CapturedAsset] { get }
    var selectablePhotos: [CapturedAsset] { get }
    var detailPhotos: [CapturedAsset] { get }
    var measurementRecord: SavedMeasurement? { get }
    var allPhotosOutput: ProductPhotoOutput? { get }
    var isCapturing: Bool { get }
    var isDeleting: Bool { get }
    var hasAcknowledgedCaptureGuide: Bool { get }
    func acknowledgeCaptureGuide()
    func captureDetail() async throws
    func deletePhoto(_ id: UUID) async throws
}

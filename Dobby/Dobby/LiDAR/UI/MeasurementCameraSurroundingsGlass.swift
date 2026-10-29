import SwiftUI

/// Compatibility wrapper for existing measurement previews and fixtures.
/// Both camera screens use the same opaque black surroundings implementation.
struct MeasurementCameraSurroundingsGlass: View {
    var photoRect: CGRect
    var body: some View { CameraBlackSurroundings(photoRect: photoRect) }
}

nonisolated enum MeasurementCameraSurroundingsSurface {
    static let opacity: Double = 1
}
typealias MeasurementCameraSurroundingsMask = CameraSurroundingsMask

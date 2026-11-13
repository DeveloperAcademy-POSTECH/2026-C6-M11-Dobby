import SwiftUI

/// Visible measurement-point styling shared by editing and saved photos.
enum MeasurementPointMarkerStyle {
    static let normalDiameter: CGFloat = 10
    static let backingDiameter: CGFloat = 12.5
    static let backingOpacity = 0.35
    static let pendingDiameter: CGFloat = 12
    static let pendingFillOpacity = 0.25
    static let pendingLineWidth: CGFloat = 2
    static let shadowOpacity = 0.4
    static let shadowRadius: CGFloat = 2
    static let shadowYOffset: CGFloat = 1
    static let touchTargetDiameter: CGFloat = 56
}

/// The marker's visible shape; editing handles supply their own touch region.
struct MeasurementPointMarker: View {
    var isPending = false

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(MeasurementPointMarkerStyle.backingOpacity))
                .frame(width: MeasurementPointMarkerStyle.backingDiameter,
                    height: MeasurementPointMarkerStyle.backingDiameter)
            if isPending {
                Circle().fill(GarmentCaptureStyle.accent.opacity(MeasurementPointMarkerStyle.pendingFillOpacity))
                    .frame(width: MeasurementPointMarkerStyle.pendingDiameter,
                        height: MeasurementPointMarkerStyle.pendingDiameter)
                Circle().stroke(GarmentCaptureStyle.accent, lineWidth: MeasurementPointMarkerStyle.pendingLineWidth)
                    .frame(width: MeasurementPointMarkerStyle.pendingDiameter,
                        height: MeasurementPointMarkerStyle.pendingDiameter)
            } else {
                Circle().fill(.white)
                    .frame(width: MeasurementPointMarkerStyle.normalDiameter,
                        height: MeasurementPointMarkerStyle.normalDiameter)
            }
        }
        .shadow(color: .black.opacity(MeasurementPointMarkerStyle.shadowOpacity),
            radius: MeasurementPointMarkerStyle.shadowRadius, y: MeasurementPointMarkerStyle.shadowYOffset)
    }
}

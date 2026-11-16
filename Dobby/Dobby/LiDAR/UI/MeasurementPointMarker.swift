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

/// Spoken coordinates use the oriented photograph, never raw sensor axes.
/// Keep these descriptions independent of the visible point/label styling.
enum MeasurementPointAccessibilityText {
    static let movementHint = "위아래로 쓸어 좌우로 조절하고, 동작 메뉴에서 위아래 이동을 선택할 수 있어요"

    static func position(_ displayPoint: ImagePoint, crop: PhotoDisplayCrop = .full) -> String {
        guard displayPoint.x.isFinite, displayPoint.y.isFinite else { return "위치 확인 필요" }
        let window = crop.isValid ? crop : .full
        let x = min(1, max(0, (displayPoint.x - window.x) / window.width)) * 100
        let y = min(1, max(0, (displayPoint.y - window.y) / window.height)) * 100
        return String(format: "사진 가로 %.2f퍼센트, 세로 %.2f퍼센트", x, y)
    }

    static func direction(dx: CGFloat, dy: CGFloat) -> String {
        if dx < 0 { return "왼쪽으로 이동" }
        if dx > 0 { return "오른쪽으로 이동" }
        return dy < 0 ? "위로 이동" : "아래로 이동"
    }
}

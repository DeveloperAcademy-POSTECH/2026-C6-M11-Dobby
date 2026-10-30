// Created by mason on 10/24/26.
import SwiftUI

/// Fit the camera itself to the photo window so fullscreen aspect-fill cannot add a hidden zoom.
struct DetailAspectRatioPreview<Content: View>: View {
    let aspectRatio: DetailPhotoAspectRatio
    @ViewBuilder var content: (CGRect) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let layout = DetailAspectRatioPreviewLayout(containerSize: geometry.size,
                aspectRatio: aspectRatio)
            ZStack(alignment: .topLeading) {
                content(layout.frame)
                    .frame(width: layout.frame.width, height: layout.frame.height)
                    .clipped()
                    .position(x: layout.frame.midX, y: layout.frame.midY)
                CameraBlackSurroundings(photoRect: layout.frame)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3, extraBounce: 0), value: aspectRatio)
                    .animation(nil, value: geometry.size)
                    .animation(nil, value: reduceMotion)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
    }
}

/// Legacy mask kept for existing geometry fixtures; production uses the shared surround.
struct DetailPreviewGlassMask: Shape {
    var viewport: CGRect
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(viewport.minX, viewport.minY), .init(viewport.width, viewport.height)) }
        set { viewport = CGRect(x: newValue.first.first, y: newValue.first.second,
                                width: newValue.second.first, height: newValue.second.second) }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(viewport)
        return path
    }
}

/// 촬영 영역은 전체 화면에서 계산한다. 조작부의 높이로 가로 폭을 줄이지 않는다.
nonisolated struct DetailAspectRatioPreviewLayout {
    let frame: CGRect

    init(containerSize: CGSize, aspectRatio: DetailPhotoAspectRatio) {
        let ratio = aspectRatio.previewRatio(isLandscape: containerSize.width > containerSize.height)
        if let viewport = MeasurementCameraChromeLayout.photoViewport(
            containerWidth: Double(containerSize.width), containerHeight: Double(containerSize.height),
            photoAspectRatio: ratio) {
            frame = CGRect(x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height)
        } else { frame = .zero }
    }
}

// Created by mason on 10/24/26.
import SwiftUI

/// One video surface with opaque surroundings shared with measurement capture.
/// Passes the actual photograph rectangle in surface-local coordinates.
struct DetailAspectRatioPreview<Content: View>: View {
    let aspectRatio: DetailPhotoAspectRatio
    var prefersBottomAlignedPortrait = false
    var portraitPhotoTop: CGFloat? = nil
    @ViewBuilder var content: (CGRect) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let layout = DetailCameraPreviewLayout(containerSize: geometry.size,
                aspectRatio: aspectRatio, prefersBottomAlignedPortrait: prefersBottomAlignedPortrait,
                portraitPhotoTop: portraitPhotoTop)
            DetailPreviewViewport(rect: layout.photoFrame, content: content)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3, extraBounce: 0), value: aspectRatio)
                .animation(nil, value: geometry.size)
                .animation(nil, value: reduceMotion)
        }
        .clipped()
    }
}

/// 영상 레이어와 마스크가 같은 중간 영역을 사용한다. UIKit도 매 프레임
/// 실제 bounds를 갱신하므로 마지막 크기의 영상만 늘여 보이는 전환을 피한다.
private struct DetailPreviewViewport<Content: View>: View, Animatable {
    var rect: CGRect
    let content: (CGRect) -> Content

    var animatableData: CameraSurroundingsMask.AnimatableData {
        get { CameraSurroundingsMask(photoRect: rect).animatableData }
        set {
            var mask = CameraSurroundingsMask(photoRect: rect)
            mask.animatableData = newValue
            rect = mask.photoRect
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content(CGRect(origin: .zero, size: rect.size))
                .frame(width: rect.width, height: rect.height)
                .clipped()
                .position(x: rect.midX, y: rect.midY)
            CameraBlackSurroundings(photoRect: rect)
        }
        // 이 영역은 이미 보간된 값이다. 하위 뷰에서 다시 애니메이션하지 않는다.
        .transaction { $0.animation = nil }
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
        frame = DetailCameraPreviewLayout(containerSize: containerSize, aspectRatio: aspectRatio).photoFrame
    }
}

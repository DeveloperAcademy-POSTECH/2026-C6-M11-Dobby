// Created by mason on 10/24/26.
import SwiftUI

/// 하나의 전체 화면 영상 위에서 저장 영역 밖만 글라스로 구분한다.
struct DetailAspectRatioPreview<Content: View>: View {
    let aspectRatio: DetailPhotoAspectRatio
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    @ViewBuilder var content: (CGRect) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let layout = DetailAspectRatioPreviewLayout(containerSize: geometry.size,
                aspectRatio: aspectRatio, topInset: topInset, bottomInset: bottomInset)
            content(layout.frame)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay {
                    DetailCaptureGlassBackground()
                        .mask {
                            DetailPreviewGlassMask(viewport: layout.frame)
                                .fill(style: FillStyle(eoFill: true))
                        }
                        .animation(reduceMotion ? nil : .smooth(duration: 0.3, extraBounce: 0), value: aspectRatio)
                        .animation(nil, value: geometry.size)
                        .animation(nil, value: reduceMotion)
                }
        }
        .clipped()
    }
}

/// 영상의 크기와 화각은 고정하고, 글라스 안쪽 경계만 보간한다.
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

/// 컨트롤을 가리지 않는 최대 크기의 저장 영역. 가로 화면에서는 좌우에도 글라스가 남을 수 있다.
nonisolated struct DetailAspectRatioPreviewLayout {
    let frame: CGRect

    init(containerSize: CGSize, aspectRatio: DetailPhotoAspectRatio,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0) {
        let top = min(max(0, topInset), containerSize.height)
        let availableHeight = max(0, containerSize.height - top - max(0, bottomInset))
        let ratio = aspectRatio.previewRatio(isLandscape: containerSize.width > containerSize.height)
        let width = min(containerSize.width, availableHeight * ratio)
        let height = width / ratio
        frame = CGRect(x: (containerSize.width - width) / 2,
                       y: top + (availableHeight - height) / 2, width: width, height: height)
    }
}

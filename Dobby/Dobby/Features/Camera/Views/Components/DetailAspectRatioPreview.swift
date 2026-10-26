// Created by mason on 10/24/26.
import SwiftUI

/// 비율별 표시 영역과 중앙 배치를 담당한다. 실제 영상·샘플 표시는 호출자가 제공한다.
struct DetailAspectRatioPreview<Content: View>: View {
    let aspectRatio: DetailPhotoAspectRatio
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let layout = DetailAspectRatioPreviewLayout(
                containerSize: geometry.size, aspectRatio: aspectRatio
            )
            content()
                .modifier(DetailPreviewViewport(size: layout.frame.size))
                .position(x: layout.frame.midX, y: layout.frame.midY)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3, extraBounce: 0), value: aspectRatio)
                // 회전·창 크기 변경은 비율 선택 애니메이션과 섞지 않는다.
                .animation(nil, value: geometry.size)
                .animation(nil, value: reduceMotion)
        }
        .background(Color(.systemBackground))
    }
}

/// UIKit 프리뷰도 보간된 크기로 배치해 영상의 aspect-fill과 클리핑을 함께 갱신한다.
private struct DetailPreviewViewport: AnimatableModifier {
    var size: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set { size = CGSize(width: newValue.first, height: newValue.second) }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: size.width, height: size.height)
            .clipped()
            // 이 크기는 이미 보간 중이므로 내부 뷰에서 다시 애니메이션하지 않는다.
            .transaction { $0.animation = nil }
    }
}

/// 저장 크롭과 공유하는 비율을 사용해 컨테이너 안에 들어가는 표시 영역을 계산한다.
nonisolated struct DetailAspectRatioPreviewLayout {
    let frame: CGRect

    init(containerSize: CGSize, aspectRatio: DetailPhotoAspectRatio) {
        let ratio = aspectRatio.previewRatio(
            isLandscape: containerSize.width > containerSize.height
        )
        let width = min(containerSize.width, containerSize.height * ratio)
        let height = width / ratio
        frame = CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }
}

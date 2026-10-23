// Created by mason on 10/24/26.
import SwiftUI

/// 비율별 표시 영역과 중앙 배치를 담당한다. 실제 영상·샘플 표시는 호출자가 제공한다.
struct DetailAspectRatioPreview<Content: View>: View {
    let aspectRatio: DetailPhotoAspectRatio
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let layout = DetailAspectRatioPreviewLayout(
                containerSize: geometry.size, aspectRatio: aspectRatio
            )
            content()
                .frame(width: layout.frame.width, height: layout.frame.height)
                .clipped()
                .position(x: layout.frame.midX, y: layout.frame.midY)
        }
        .background(Color(.systemBackground))
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

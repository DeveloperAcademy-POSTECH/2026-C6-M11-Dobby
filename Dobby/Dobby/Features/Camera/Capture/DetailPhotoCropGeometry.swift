// Created by mason on 10/21/26.
import CoreGraphics

/// 계산만 제공한다. 실제 이미지 회전·반전·크롭·저장이나 프리뷰 변경은 수행하지 않는다.
nonisolated struct DetailPhotoCropGeometry: Equatable, Sendable {
    let uprightPixelSize: CGSize
    /// EXIF 회전과 반전을 먼저 적용한 이미지의 좌상단 원점 픽셀 좌표.
    /// 방향 정보가 남아 있는 원시 CGImage에 그대로 적용하면 안 된다.
    let cropRect: CGRect
    var outputPixelSize: CGSize { cropRect.size }
    /// 정방향 전체 이미지 기준 0...1 영역. 카메라 센서/프리뷰 레이어 좌표는 아니다.
    var normalizedCropRect: CGRect {
        CGRect(x: cropRect.minX / uprightPixelSize.width,
               y: cropRect.minY / uprightPixelSize.height,
               width: cropRect.width / uprightPixelSize.width,
               height: cropRect.height / uprightPixelSize.height)
    }

    init?(pixelWidth: Int, pixelHeight: Int, orientation: CapturedAsset.Orientation,
          aspectRatio: DetailPhotoAspectRatio?) {
        // CGFloat 좌표 변환에서도 픽셀 정수가 정확하게 보존돼야 한다.
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 9_007_199_254_740_991, pixelHeight <= 9_007_199_254_740_991 else { return nil }
        let swapsAxes: Bool
        switch orientation {
        case .leftMirrored, .right, .rightMirrored, .left: swapsAxes = true
        case .up, .upMirrored, .down, .downMirrored: swapsAxes = false
        }
        let width = swapsAxes ? pixelHeight : pixelWidth
        let height = swapsAxes ? pixelWidth : pixelHeight
        uprightPixelSize = CGSize(width: width, height: height)
        guard let aspectRatio else {
            cropRect = CGRect(origin: .zero, size: uprightPixelSize)
            return
        }
        let longSide: Int, shortSide: Int
        switch aspectRatio {
        case .fourThree: (longSide, shortSide) = (4, 3)
        case .sixteenNine: (longSide, shortSide) = (16, 9)
        case .square: (longSide, shortSide) = (1, 1)
        }
        // 정사각형 원본은 세로 기준. 화면 방향이 아닌 정방향 사진의 종횡을 따른다.
        let horizontal = width > height ? longSide : shortSide
        let vertical = width > height ? shortSide : longSide
        let unit = min(width / horizontal, height / vertical)
        guard unit > 0 else { return nil }
        let cropWidth = unit * horizontal, cropHeight = unit * vertical
        // 정수 픽셀로 정확한 비율을 유지. 홀수 잔여 픽셀은 오른쪽/아래쪽에서 더 제거한다.
        cropRect = CGRect(x: (width - cropWidth) / 2, y: (height - cropHeight) / 2,
                          width: cropWidth, height: cropHeight)
    }
}

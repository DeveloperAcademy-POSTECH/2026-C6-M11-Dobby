// Created by mason on 10/27/26.
import CoreGraphics

/// AVFoundation의 센서 기준 정규화 영역을 회전된 사진의 좌상단 기준으로 변환한다.
/// 상세 카메라는 후면 전용이며 프리뷰/사진 연결에 같은 회전값을 적용한다.
nonisolated enum DetailPreviewCropMapping {
    static func uprightRect(_ rect: CGRect, rotationAngle: CGFloat) -> CGRect? {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { return nil }
        let result: CGRect
        switch rotationAngle {
        case 0: result = rect
        case 90: result = CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 180: result = CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 270: result = CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        default: return nil
        }
        let clipped = result.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
}

// Created by mason on 10/21/26.
import CoreImage
import CoreGraphics
import Foundation
import ImageIO

/// 상세 사진 전용. 비율 미지정은 원본 바이트를 보존하고, 지정된 경우만 SDR JPEG로 처리한다.
actor DetailPhotoProcessor {
    private lazy var context = CIContext(options: [.cacheIntermediates: false])

    func process(_ data: Data, aspectRatio: DetailPhotoAspectRatio?) throws -> Data {
        try Task.checkCancellation()
        guard let aspectRatio else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = CapturedAsset.Orientation(rawValue: properties[kCGImagePropertyOrientation] as? Int ?? 1),
              let geometry = DetailPhotoCropGeometry(pixelWidth: image.width, pixelHeight: image.height,
                  orientation: orientation, aspectRatio: aspectRatio) else { throw CameraFailure.saveFailed }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation.rawValue))
        let upright = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX,
                                                                 y: -oriented.extent.minY))
        // Geometry는 좌상단, Core Image는 좌하단 원점이다. 홀수 잔여분도 같은 쪽에서 제거한다.
        let rect = geometry.cropRect
        let ciRect = CGRect(x: rect.minX, y: geometry.uprightPixelSize.height - rect.maxY,
                            width: rect.width, height: rect.height)
        try Task.checkCancellation()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cropped = context.createCGImage(upright.cropped(to: ciRect), from: ciRect,
                  format: .RGBA8, colorSpace: colorSpace) else { throw CameraFailure.saveFailed }
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw CameraFailure.saveFailed
        }
        // 원본 방향·크기·썸네일을 복사하지 않고 처리 후 픽셀에서 메타데이터를 새로 만든다.
        CGImageDestinationAddImage(destination, cropped, [kCGImagePropertyOrientation: 1,
            kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraFailure.saveFailed }
        try Task.checkCancellation()
        return output as Data
    }
}

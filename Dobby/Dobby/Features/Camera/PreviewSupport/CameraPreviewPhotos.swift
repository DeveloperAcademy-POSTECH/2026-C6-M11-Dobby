//
//  CameraPreviewPhotos.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import Foundation
import ImageIO

/// Figma의 예시 사진을 번들에서 읽는다. 실제 촬영이나 측정 결과가 아니다.
/// 출처: C6 Figma 1114:4741의 4743, 4749~4751 이미지. Fixtures 폴더 담당: mason.
enum CameraPreviewPhotos {
    static let names = ["front", "label", "back", "detail"]

    static func source(at index: Int) throws -> CapturedAsset.Source {
        let name = "camera-sample-\(names[min(max(index, 0), names.count - 1)])"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw CameraFailure.captureFailed
        }
        return .localFile(url, metadata: .init(
            pixelWidth: width, pixelHeight: height, contentType: "public.png",
            orientation: .init(rawValue: properties[kCGImagePropertyOrientation] as? Int ?? 1) ?? .up
        ))
    }

    @MainActor
    static func makeModel() throws -> ProductPhotoModel {
        let measurement = CapturedAsset(
            id: UUID(), sessionID: UUID(), garmentID: UUID(), purpose: .measurement,
            capturedAt: Date(), source: try source(at: 0)
        )
        return try ProductPhotoModel(input: ProductPhotoInput(
            sessionID: measurement.sessionID, garmentID: measurement.garmentID,
            measurement: measurement
        ), captureProvider: MockPhotoCaptureService())
    }
}

/// 표시 중인 샘플 순서로 반환한다. 마지막 사진은 반복하되 촬영 ID는 매번 새로 만든다.
@MainActor
private final class MockPhotoCaptureService: CaptureProviding {
    private var nextIndex = 1

    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
        try Task.checkCancellation()
        let source = try CameraPreviewPhotos.source(at: nextIndex)
        nextIndex = min(nextIndex + 1, CameraPreviewPhotos.names.count - 1)
        return CapturedAsset(
            id: UUID(), sessionID: sessionID, garmentID: garmentID, purpose: .detail,
            capturedAt: Date(), source: source
        )
    }
}

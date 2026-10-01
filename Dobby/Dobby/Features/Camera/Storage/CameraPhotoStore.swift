//
//  CameraPhotoStore.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import Foundation
import ImageIO

/// Storage 폴더 담당: mason. 사진 앱이 아닌 앱 내부 원본 저장소다.
/// 전달된 파일은 화면 이탈 시 지우지 않는다. 초안 복원·보존 기간은 후속 통합 범위다.
actor CameraPhotoStore {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "CameraPhotos", directoryHint: .isDirectory)
    }

    func save(_ data: Data, sessionID: UUID, garmentID: UUID, capturedAt: Date) throws -> CapturedAsset {
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(image) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else {
            throw CameraFailure.saveFailed
        }
        let id = UUID()
        let folder = directory.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        let url = folder.appending(path: "\(id.uuidString).jpg")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { throw CameraFailure.saveFailed }
        let asset = CapturedAsset(id: id, sessionID: sessionID, garmentID: garmentID,
            purpose: .detail, capturedAt: capturedAt, source: .localFile(url, metadata: .init(
                pixelWidth: width, pixelHeight: height, contentType: "public.jpeg",
                orientation: .init(rawValue: properties[kCGImagePropertyOrientation] as? Int ?? 1) ?? .up)))
        do { try Task.checkCancellation() }
        catch { try discardUncommitted(asset); throw error }
        return asset
    }

    /// 이 저장소에서 만든 미반영 사진 1장만 삭제한다. 기존 사진·입력 사진은 대상이 아니다.
    func discardUncommitted(_ asset: CapturedAsset) throws {
        let expected = directory.appending(path: asset.sessionID.uuidString).appending(path: "\(asset.id.uuidString).jpg")
        guard asset.purpose == .detail, case let .localFile(url, _) = asset.source,
              url.standardizedFileURL == expected.standardizedFileURL else { throw CameraFailure.saveFailed }
        if FileManager.default.fileExists(atPath: expected.path) {
            do { try FileManager.default.removeItem(at: expected) }
            catch { throw CameraFailure.saveFailed }
        }
    }
}

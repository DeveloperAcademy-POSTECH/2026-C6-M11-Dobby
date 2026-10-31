import Photos

struct FruitsPhotoLibraryWriter {
    func save(photos: [Data]) async throws {
        guard !photos.isEmpty else {
            throw FruitsPhotoLibraryError.emptyPhotos
        }

        let authorizationStatus = await requestAuthorization()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw FruitsPhotoLibraryError.accessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            for photo in photos {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: photo, options: nil)
            }
        }
    }

    private func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private enum FruitsPhotoLibraryError: LocalizedError {
    case accessDenied
    case emptyPhotos

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "사진을 저장하려면 설정에서 Dobby의 사진 추가 권한을 허용해 주세요."
        case .emptyPhotos:
            "저장할 사진이 없어요."
        }
    }
}

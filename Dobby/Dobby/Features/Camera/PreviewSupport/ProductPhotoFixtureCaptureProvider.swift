#if DEBUG
import Foundation

/// 통합 UI 테스트에서 명시적으로 주입한다. 사진 보관함과 실제 카메라를 사용하지 않는다.
@MainActor
final class ProductPhotoFixtureCaptureProvider: CaptureProviding {
    private let source: CapturedAsset.Source
    private let store: CameraPhotoStore

    init(seed source: CapturedAsset.Source, directory: URL? = nil) {
        self.source = source
        store = CameraPhotoStore(directory: directory)
    }

    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
        try Task.checkCancellation()
        guard case let .localFile(url, metadata) = source, metadata.contentType == "public.jpeg" else {
            throw CameraFailure.captureFailed
        }
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
        try Task.checkCancellation()
        return try await store.save(data, sessionID: sessionID, garmentID: garmentID, capturedAt: .now)
    }

    func discardUncommitted(_ asset: CapturedAsset) async throws {
        try await store.discardUncommitted(asset)
    }
}
#endif

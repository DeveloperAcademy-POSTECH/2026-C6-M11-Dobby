import Foundation
import Observation
import Photos

/// Saves the measurement original, measurement-overlay image and all detail
/// originals after detail capture, independently of the ten-photo selection.
/// Progress counts successful Photos transactions, including receipts from a
/// previous visit. Neither the original files nor the photo library are read back.
@MainActor
@Observable
final class DetailPhotoLibrarySaver {
    private(set) var isSaving = false
    private(set) var savedCount = 0
    private(set) var totalCount = 0
    @ObservationIgnored private let archive: DetailPhotoLibraryArchive

    init() { archive = .shared }

    func save(_ photos: [CapturedAsset]) async throws {
        guard !isSaving else { throw DetailPhotoLibrarySaveError.operationInProgress }
        isSaving = true
        savedCount = 0
        totalCount = photos.count
        defer { isSaving = false }

        try await archive.save(photos) { [weak self] count in
            self?.savedCount = count
        }
    }
}

nonisolated enum DetailPhotoLibrarySaveError: Error, LocalizedError, Equatable, Sendable {
    case accessDenied
    case accessRestricted
    case invalidPhotos
    case missingFile(photoID: UUID)
    case insufficientStorage
    case photoLibraryFailed(domain: String, code: Int)
    case receiptStorageFailed
    case operationInProgress

    var canOpenSettings: Bool { self == .accessDenied }

    var errorDescription: String? { "사진을 저장하지 못했어요" }

    var failureReason: String? {
        switch self {
        case .accessDenied:
            "Dobby의 사진 추가 권한이 꺼져 있어요."
        case .accessRestricted:
            "스크린 타임이나 기기 관리 설정으로 사진 추가가 제한되어 있어요."
        case .invalidPhotos:
            "저장할 사진 목록을 확인할 수 없어요."
        case .missingFile:
            "저장할 사진의 원본 파일을 찾거나 읽을 수 없어요."
        case .insufficientStorage:
            "기기의 저장 공간이 부족해 사진을 저장할 수 없어요."
        case .photoLibraryFailed:
            "iPhone 사진 앱에서 사진 저장을 완료하지 못했어요."
        case .receiptStorageFailed:
            "사진 저장 기록을 보관하거나 확인하지 못했어요."
        case .operationInProgress:
            "다른 사진 저장 작업이 진행 중이에요."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .accessDenied:
            "설정에서 Dobby의 사진 추가를 허용한 뒤 다시 시도해 주세요. 촬영한 사진은 앱에 남아 있어요."
        case .accessRestricted:
            "기기의 사진 접근 제한을 확인한 뒤 다시 시도해 주세요. 촬영한 사진은 앱에 남아 있어요."
        case .missingFile:
            "실측 사진과 상세 사진을 확인하고 필요한 사진을 다시 촬영해 주세요."
        case .insufficientStorage, .receiptStorageFailed:
            "기기의 저장 공간을 확인한 뒤 다시 시도해 주세요. 이미 저장을 완료한 사진은 다시 저장하지 않아요."
        case .invalidPhotos, .photoLibraryFailed:
            "촬영한 사진은 앱에 남아 있어요. 잠시 후 다시 시도해 주세요."
        case .operationInProgress:
            "진행 중인 사진 저장이 끝난 뒤 다시 시도해 주세요."
        }
    }

    fileprivate static func fromPhotoLibrary(_ error: any Error) -> Self {
        let errors = errorChain(error)
        if errors.contains(where: isStorageFull) { return .insufficientStorage }
        if errors.contains(where: {
            $0.domain == PHPhotosErrorDomain && $0.code == PHPhotosError.Code.accessRestricted.rawValue
        }) { return .accessRestricted }
        if errors.contains(where: {
            $0.domain == PHPhotosErrorDomain && $0.code == PHPhotosError.Code.accessUserDenied.rawValue
        }) { return .accessDenied }
        let error = error as NSError
        return .photoLibraryFailed(domain: error.domain, code: error.code)
    }

    fileprivate static func fromReceiptStorage(_ error: any Error) -> Self {
        errorChain(error).contains(where: isStorageFull) ? .insufficientStorage : .receiptStorageFailed
    }

    private static func isStorageFull(_ error: NSError) -> Bool {
        (error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.Code.notEnoughSpace.rawValue)
            || (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || (error.domain == NSPOSIXErrorDomain
                && (error.code == POSIXErrorCode.ENOSPC.rawValue || error.code == POSIXErrorCode.EDQUOT.rawValue))
    }

    private static func errorChain(_ error: any Error) -> [NSError] {
        var result = [error as NSError]
        // Bound the walk even if an external NSError has a malformed cycle.
        for _ in 0..<4 {
            guard let next = result.last?.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            result.append(next)
        }
        return result
    }
}

/// One process-wide serial owner prevents separate screen instances from saving
/// the same capture concurrently. Receipts are one small atomic file per capture,
/// so history does not accumulate as full image buffers or an in-memory registry.
private actor DetailPhotoLibraryArchive {
    static let shared = DetailPhotoLibraryArchive()

    private let directory = URL.applicationSupportDirectory
        .appending(path: "DetailPhotoLibraryReceipts", directoryHint: .isDirectory)
    private var isSaving = false
    /// Retain one successful transaction when a receipt write fails, so retrying
    /// in this process cannot create a second Photos asset for that transaction.
    private var unrecordedReceipt: Receipt?

    private struct Receipt: Codable, Sendable {
        let schemaVersion: Int
        let captureID: UUID
        let captureSessionID: UUID?
        // A successful transaction still counts if PhotoKit omits a placeholder.
        // No read permission is requested merely to recover that identifier.
        let photoLibraryIdentifier: String?
        let savedAt: Date
    }

    func save(_ photos: [CapturedAsset],
              onProgress: @MainActor @Sendable (Int) -> Void) async throws {
        guard !isSaving else { throw DetailPhotoLibrarySaveError.operationInProgress }
        isSaving = true
        defer { isSaving = false }
        try Task.checkCancellation()
        guard !photos.isEmpty else { return }
        guard Set(photos.map(\.id)).count == photos.count,
              Set(photos.map(\.garmentID)).count == 1 else {
            throw DetailPhotoLibrarySaveError.invalidPhotos
        }

        var completed = 0
        var pending: [CapturedAsset] = []
        var firstReceiptError: (any Error)?
        for photo in photos {
            try Task.checkCancellation()
            // A prior receipt-write failure does not undo the Photos commit.
            if unrecordedReceipt?.captureID == photo.id,
               unrecordedReceipt?.captureSessionID == photo.sessionID {
                completed += 1
                continue
            }
            do {
                if try hasReceipt(for: photo) {
                    completed += 1
                } else {
                    pending.append(photo)
                }
            } catch {
                // Continue reading the small receipts so the error screen keeps
                // the confirmed saved count even if one receipt is unreadable.
                if firstReceiptError == nil { firstReceiptError = error }
            }
        }
        await onProgress(completed)
        try Task.checkCancellation()
        if let firstReceiptError { throw firstReceiptError }
        try prepareReceiptStorage()
        // A Photos commit cannot be atomically joined to an app-local write.
        // Flush any known successful commit before permitting further creation.
        try flushUnrecordedReceipt()
        guard !pending.isEmpty else { return }
        for photo in pending {
            try Task.checkCancellation()
            try validateOriginal(photo)
        }
        try await requestAuthorization()

        for photo in pending {
            try Task.checkCancellation()
            // Check again immediately before PhotoKit consumes the file.
            try validateOriginal(photo)
            let localIdentifier = try await createPhoto(photo)
            // Do not check cancellation between Photos success and this write:
            // PhotoKit transactions cannot be cancelled after submission.
            unrecordedReceipt = Receipt(schemaVersion: 1, captureID: photo.id, captureSessionID: photo.sessionID,
                photoLibraryIdentifier: localIdentifier, savedAt: .now)
            completed += 1
            do {
                try flushUnrecordedReceipt()
            } catch {
                await onProgress(completed)
                throw error
            }
            await onProgress(completed)
        }
        try Task.checkCancellation()
    }

    private func requestAuthorization() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        try Task.checkCancellation()
        switch status {
        case .authorized, .limited: return
        case .restricted: throw DetailPhotoLibrarySaveError.accessRestricted
        case .denied, .notDetermined: throw DetailPhotoLibrarySaveError.accessDenied
        @unknown default: throw DetailPhotoLibrarySaveError.accessRestricted
        }
    }

    private func validateOriginal(_ photo: CapturedAsset) throws {
        guard case let .localFile(url, metadata) = photo.source, url.isFileURL,
              metadata.pixelWidth > 0, metadata.pixelHeight > 0 else {
            throw DetailPhotoLibrarySaveError.missingFile(photoID: photo.id)
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isReadable == true,
                  let size = values.fileSize, size > 0 else {
                throw DetailPhotoLibrarySaveError.missingFile(photoID: photo.id)
            }
        } catch {
            throw DetailPhotoLibrarySaveError.missingFile(photoID: photo.id)
        }
    }

    private func createPhoto(_ photo: CapturedAsset) async throws -> String? {
        guard case let .localFile(url, _) = photo.source else {
            throw DetailPhotoLibrarySaveError.missingFile(photoID: photo.id)
        }
        let identifier = DetailPhotoLibraryIdentifier()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                PHPhotoLibrary.shared().performChanges {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = photo.capturedAt
                    request.addResource(with: .photo, fileURL: url, options: options)
                    identifier.store(request.placeholderForCreatedAsset?.localIdentifier)
                } completionHandler: { success, error in
                    if success {
                        continuation.resume(returning: identifier.value)
                    } else {
                        continuation.resume(throwing: error ?? NSError(domain: PHPhotosErrorDomain,
                            code: PHPhotosError.Code.internalError.rawValue))
                    }
                }
            }
        } catch {
            throw DetailPhotoLibrarySaveError.fromPhotoLibrary(error)
        }
    }

    private func prepareReceiptStorage() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DetailPhotoLibrarySaveError.fromReceiptStorage(error)
        }
    }

    private func receiptURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    private func hasReceipt(for photo: CapturedAsset) throws -> Bool {
        let id = photo.id
        let url = receiptURL(for: id)
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 4_096 else {
                throw DetailPhotoLibrarySaveError.receiptStorageFailed
            }
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
            guard receipt.schemaVersion == 1, receipt.captureID == id else {
                throw DetailPhotoLibrarySaveError.receiptStorageFailed
            }
            // Retaking measurement reuses the product photo ID but replaces
            // its capture session. Save that new original instead of skipping it.
            // Legacy receipts were detail-only; their IDs are immutable.
            return receipt.captureSessionID == photo.sessionID
                || (receipt.captureSessionID == nil && photo.purpose == .detail)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        } catch {
            // An unreadable or malformed receipt must not trigger a duplicate.
            throw DetailPhotoLibrarySaveError.fromReceiptStorage(error)
        }
    }

    private func flushUnrecordedReceipt() throws {
        guard let receipt = unrecordedReceipt else { return }
        do {
            try JSONEncoder().encode(receipt).write(to: receiptURL(for: receipt.captureID), options: .atomic)
            unrecordedReceipt = nil
        } catch {
            throw DetailPhotoLibrarySaveError.fromReceiptStorage(error)
        }
    }
}

/// PhotoKit invokes its change and completion blocks on different queues.
/// This box owns their only shared mutable value; no UI state crosses queues.
private nonisolated final class DetailPhotoLibraryIdentifier: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: String?

    func store(_ value: String?) { lock.withLock { identifier = value } }
    var value: String? { lock.withLock { identifier } }
}

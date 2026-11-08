import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

nonisolated struct ProductAutofillTestPhoto: Identifiable, Sendable {
    let id: UUID
    let asset: CapturedAsset
    let thumbnailData: Data
}

/// A disposable AI request, independent of product registration and SwiftData.
@MainActor @Observable
final class ProductAutofillTestSession {
    private(set) var photos: [ProductAutofillTestPhoto] = []
    private(set) var isImporting = false
    private(set) var isGenerating = false
    private(set) var result: ProductAutofillGenerationResult?
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var errorMessage: String?

    let directory: URL
    @ObservationIgnored private let generator: any ProductAutofillGenerating
    @ObservationIgnored private let sessionID = UUID()
    @ObservationIgnored private let garmentID = UUID()
    @ObservationIgnored private var importID: UUID?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var importTask: Task<[ProductAutofillTestPhoto], any Error>?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var isClosed = false

    init(generator: (any ProductAutofillGenerating)? = nil, directory: URL? = nil) {
        self.generator = generator ?? ProductAutofillClient.makeDefault()
        // Even an injected base directory is never itself owned or deleted.
        self.directory = (directory ?? URL.temporaryDirectory.appending(path: "DobbyAITest", directoryHint: .isDirectory))
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// A malformed selection never replaces the last valid photos or their result.
    func replacePhotos(_ data: [Data]) async {
        guard !isClosed else { return }
        importTask?.cancel()
        let identifier = UUID()
        let batch = directory.appending(path: identifier.uuidString, directoryHint: .isDirectory)
        importID = identifier
        isImporting = true
        errorMessage = nil
        let sessionID = sessionID
        let garmentID = garmentID
        let task = Task.detached(priority: .userInitiated) {
            try ProductAutofillTestPhotoImport.load(data, into: batch, sessionID: sessionID, garmentID: garmentID)
        }
        importTask = task
        defer {
            if importID == identifier {
                importID = nil
                importTask = nil
                isImporting = false
            }
        }
        do {
            let imported = try await task.value
            guard !Task.isCancelled, !isClosed, importID == identifier else {
                discardBatch(batch)
                if isClosed { removeOwnedDirectory() }
                return
            }
            cancel()
            let previous = photos
            photos = imported
            previous.forEach(removeOwnedPhoto)
            result = nil
            elapsedSeconds = 0
            errorMessage = nil
        } catch {
            discardBatch(batch)
            if isClosed { removeOwnedDirectory() }
            guard !isClosed, importID == identifier else { return }
            if !(error is CancellationError) && !Task.isCancelled {
                errorMessage = ProductAutofillTestPhotoImport.message(for: error)
            }
        }
    }

    func removePhoto(_ id: UUID) {
        guard !isClosed, let photo = photos.first(where: { $0.id == id }) else { return }
        cancelImport()
        cancel()
        photos.removeAll { $0.id == id }
        removeOwnedPhoto(photo)
        result = nil
        elapsedSeconds = 0
        errorMessage = nil
    }

    func clear() {
        cancelImport()
        cancel()
        photos = []
        result = nil
        elapsedSeconds = 0
        errorMessage = nil
        removeOwnedDirectory()
    }

    /// Repeated taps cannot send another request while one is active.
    func start() {
        guard !isClosed, !isGenerating, !isImporting else { return }
        guard !photos.isEmpty else {
            errorMessage = "테스트할 옷 사진을 먼저 선택해 주세요."
            return
        }
        let identifier = UUID()
        requestID = identifier
        result = nil
        errorMessage = nil
        elapsedSeconds = 0
        isGenerating = true
        startedAt = .now
        startTimer(for: identifier)
        let generator = generator
        let assets = photos.map(\.asset)
        generationTask = Task { [weak self] in
            do {
                let generated = try await generator.generateWithDiagnostics(photos: assets)
                try Task.checkCancellation()
                guard let self, !self.isClosed, self.requestID == identifier else { return }
                guard generated.draft.isValid else { throw ProductAutofillError.invalidResponse }
                self.result = generated
                self.finishGeneration(identifier)
            } catch {
                guard let self, !self.isClosed, self.requestID == identifier else { return }
                if !(error is CancellationError) && !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
                self.finishGeneration(identifier)
            }
        }
    }

    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        requestID = nil
        isGenerating = false
        stopTimer()
    }

    /// Only this instance's UUID directory is eligible for deletion.
    func close() {
        isClosed = true
        clear()
    }

    private func finishGeneration(_ identifier: UUID) {
        guard requestID == identifier else { return }
        requestID = nil
        generationTask = nil
        isGenerating = false
        stopTimer()
    }

    private func cancelImport() {
        importID = nil
        importTask?.cancel()
        importTask = nil
        isImporting = false
    }

    private func startTimer(for identifier: UUID) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self, self.requestID == identifier else { return }
                self.updateElapsed()
            }
        }
    }

    private func stopTimer() {
        updateElapsed()
        startedAt = nil
        timerTask?.cancel()
        timerTask = nil
    }

    private func updateElapsed() {
        guard let startedAt else { return }
        let duration = startedAt.duration(to: .now).components
        elapsedSeconds = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }

    private func removeOwnedPhoto(_ photo: ProductAutofillTestPhoto) {
        guard case let .localFile(url, _) = photo.asset.source,
              url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func discardBatch(_ batch: URL) {
        guard batch.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: batch)
    }

    private func removeOwnedDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// ImageIO reads actual file metadata and decodes only a small thumbnail for UI.
nonisolated private enum ProductAutofillTestPhotoImport {
    static func message(for error: any Error) -> String {
        (error as? ImportError)?.localizedDescription ?? "사진을 임시로 저장하지 못했어요. 다시 선택해 주세요."
    }

    static func load(_ data: [Data], into directory: URL, sessionID: UUID,
                     garmentID: UUID) throws -> [ProductAutofillTestPhoto] {
        guard (1...5).contains(data.count) else { throw ImportError.count }
        guard data.allSatisfy({ !$0.isEmpty && $0.count <= 20 * 1024 * 1024 }) else { throw ImportError.size }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return try data.map { bytes in
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithData(bytes as CFData,
                        [kCGImageSourceShouldCache: false] as CFDictionary),
                      let identifier = CGImageSourceGetType(source) as String?,
                      let type = UTType(identifier), type.conforms(to: .image),
                      CGImageSourceGetCount(source) > 0,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...16384).contains(width), (1...16384).contains(height),
                      let orientation = CapturedAsset.Orientation(rawValue: properties[kCGImagePropertyOrientation] as? Int ?? 1),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 360,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw ImportError.unreadable }
                let thumbnailData = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(thumbnailData,
                        UTType.png.identifier as CFString, 1, nil) else { throw ImportError.unreadable }
                CGImageDestinationAddImage(destination, thumbnail, nil)
                guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadable }
                try Task.checkCancellation()
                let id = UUID()
                let url = directory.appending(path: id.uuidString).appendingPathExtension(type.preferredFilenameExtension ?? "image")
                try bytes.write(to: url, options: .atomic)
                let asset = CapturedAsset(id: id, sessionID: sessionID, garmentID: garmentID,
                    purpose: .detail, capturedAt: .now,
                    source: .localFile(url, metadata: .init(pixelWidth: width, pixelHeight: height,
                        contentType: identifier, orientation: orientation)))
                return ProductAutofillTestPhoto(id: id, asset: asset, thumbnailData: thumbnailData as Data)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private enum ImportError: LocalizedError {
        case count, size, unreadable
        var errorDescription: String? {
            switch self {
            case .count: "옷 사진은 1장부터 최대 5장까지 선택해 주세요."
            case .size: "사진 한 장의 용량은 20MB 이하로 선택해 주세요."
            case .unreadable: "사진을 읽지 못했어요. 다른 사진으로 다시 선택해 주세요."
            }
        }
    }
}

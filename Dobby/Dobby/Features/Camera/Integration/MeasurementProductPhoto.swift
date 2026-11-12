// Created by mason on 10/30/26.
import CryptoKit
import ImageIO
import SwiftData
import SwiftUI

/// 확정된 결과의 표시만 이미지로 저장한다. 측정 계산과 원본 픽셀은 변경하지 않는다.
@MainActor
enum MeasurementProductPhoto {
    nonisolated static let renderingVersion = 2
    private nonisolated static let renderingDescriptionPrefix = "dobby-measurement-render:"

    static func prepare(record: SavedMeasurement, garment: Garment, in context: ModelContext,
                        directory: URL? = nil,
                        persist: (ModelContext) throws -> Void = { try $0.save() }) async throws -> CapturedAsset {
        let directory = directory ?? GarmentStore.photosDirectory
        guard garment.modelContext === context,
              let original = garment.measurementPhoto,
              original.measurementFrameID == record.snapshot.frame.frameID,
              original.measurementSessionID == record.snapshot.frame.sessionID else {
            throw ProductPhotoHandoff.HandoffError.invalidInput
        }
        // Preserve logical photo IDs so saved draft selections remain readable.
        // Version the derived filename to invalidate thumbnail/rotation caches.
        let id = identifier(garmentID: garment.id, recordID: record.id)
        let baseName = "\(garment.id.uuidString)-\(id.uuidString)"
        let name = fileName(garmentID: garment.id, recordID: record.id)
        let url = directory.appending(path: name)
        let existing = garment.photos.first(where: { $0.id == id })
        if let existing {
            let knownNames = ["\(baseName).png"] + (1...renderingVersion).map { "\(baseName)-r\($0).png" }
            guard knownNames.contains(existing.fileName), !existing.isMeasurementSource else {
                throw ProductPhotoHandoff.HandoffError.invalidInput
            }
        }
        let rotation = ((existing?.productRotationQuarterTurns ?? 0) % 4 + 4) % 4
        let rotatedURL = rotation == 0 ? nil : url.deletingPathExtension()
            .appendingPathExtension("product-rotation-\(rotation).jpg")
        let hasCurrentRaster = renderingVersion(of: url) == renderingVersion
        if existing?.fileName == name, hasCurrentRaster,
           rotatedURL.map({ FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            return try asset(id: id, record: record, garmentID: garment.id, url: url)
        }
        let previousName = existing?.fileName
        let previousWidth = existing?.imageWidth
        let previousHeight = existing?.imageHeight
        var createdFiles: [URL] = []
        var previousRaster: Data?
        var previousRotations: [(URL, Data)] = []
        var inserted: GarmentPhoto?
        do {
            if !hasCurrentRaster {
                guard let image = await SnapshotPresentation.thumbnail(for: record.snapshot, maximumDimension: 2048) else {
                    throw ProductPhotoHandoff.HandoffError.unreadablePhoto
                }
                try Task.checkCancellation()
                let data = try render(record: record, image: image)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    previousRaster = try Data(contentsOf: url)
                } else {
                    createdFiles.append(url)
                }
                try data.write(to: url, options: .atomic)
                // Rotation variants are derived from this raster. Rebuilding
                // it must invalidate every variant, including inactive ones.
                previousRotations = try (1...3).compactMap { turns in
                    let variant = url.deletingPathExtension()
                        .appendingPathExtension("product-rotation-\(turns).jpg")
                    guard FileManager.default.fileExists(atPath: variant.path) else { return nil }
                    return (variant, try Data(contentsOf: variant))
                }
                for (variant, _) in previousRotations { try FileManager.default.removeItem(at: variant) }
            }
            if let rotatedURL, !FileManager.default.fileExists(atPath: rotatedURL.path) {
                createdFiles.append(rotatedURL)
                try await Task.detached(priority: .userInitiated) {
                    try GarmentStore.writeProductRotation(original: url, destination: rotatedURL, quarterTurns: rotation)
                }.value
            }
            try Task.checkCancellation()
            let result = try asset(id: id, record: record, garmentID: garment.id, url: url)
            let photo = existing ?? GarmentPhoto(fileName: name, role: .detail, order: garment.photos.count)
            photo.fileName = name
            if case let .localFile(_, metadata) = result.source {
                photo.imageWidth = metadata.pixelWidth
                photo.imageHeight = metadata.pixelHeight
            }
            if existing == nil {
                photo.id = id
                photo.capturedAt = record.savedAt
                photo.isSelectedForProduct = false
                context.insert(photo)
                garment.photos.append(photo)
                inserted = photo
            }
            try persist(context)
            return result
        } catch {
            if let existing, let previousName {
                existing.fileName = previousName
                existing.imageWidth = previousWidth
                existing.imageHeight = previousHeight
            }
            if let inserted {
                garment.photos.removeAll { $0.id == id }
                if inserted.modelContext != nil { context.delete(inserted) }
            }
            for file in createdFiles { try? FileManager.default.removeItem(at: file) }
            if let previousRaster { try? previousRaster.write(to: url, options: .atomic) }
            for (variant, bytes) in previousRotations { try? bytes.write(to: variant, options: .atomic) }
            throw error
        }
    }

    nonisolated static func renderingVersion(of url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
              let description = png[kCGImagePropertyPNGDescription] as? String,
              description.hasPrefix(renderingDescriptionPrefix) else { return nil }
        return Int(description.dropFirst(renderingDescriptionPrefix.count))
    }

    static func identifier(garmentID: UUID, recordID: UUID) -> UUID {
        let key = "measurement-product-v1:\(garmentID):\(recordID)"
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func fileName(garmentID: UUID, recordID: UUID) -> String {
        "\(garmentID.uuidString)-\(identifier(garmentID: garmentID, recordID: recordID).uuidString)-r\(renderingVersion).png"
    }

    private static func asset(id: UUID, record: SavedMeasurement, garmentID: UUID, url: URL) throws -> CapturedAsset {
        CapturedAsset(id: id, sessionID: record.snapshot.frame.sessionID, garmentID: garmentID,
            purpose: .measurementVisualization, capturedAt: record.savedAt,
            source: .localFile(url, metadata: try ProductPhotoHandoff.metadata(for: url)))
    }

    static func render(record: SavedMeasurement, image: UIImage) throws -> Data {
        let measurement = AutomaticMeasurement(record: record)
        var landmarks = record.landmarks
        landmarks.points = []
        let ratio = SnapshotPresentation.resultAspectRatio(for: record.snapshot)
        guard ratio.isFinite, ratio > 0 else { throw ProductPhotoHandoff.HandoffError.unreadablePhoto }
        let content = GarmentMeasurementPhotoEditor(image: image, snapshot: record.snapshot,
            editableLandmarks: landmarks, definitions: measurement.visibleDefinitions,
            values: measurement.visibleValues, showLabels: true, isEnabled: false,
            isRecalculating: false, showsEnlargeControl: false, usesResultPointStyleForEndpoints: true,
            onEnlarge: {}, onMove: { _, _ in }, onEditingChanged: { _ in })
            .frame(width: 402, height: 402 / ratio)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 4
        guard let image = renderer.uiImage?.cgImage else { throw ProductPhotoHandoff.HandoffError.unreadablePhoto }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ProductPhotoHandoff.HandoffError.unreadablePhoto
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGDescription: renderingDescriptionPrefix + String(renderingVersion)
        ]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProductPhotoHandoff.HandoffError.unreadablePhoto }
        return data as Data
    }
}

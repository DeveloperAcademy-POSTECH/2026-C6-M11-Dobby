// Created by mason on 10/30/26.
import CryptoKit
import SwiftData
import SwiftUI

/// 확정된 결과의 표시만 이미지로 저장한다. 측정 계산과 원본 픽셀은 변경하지 않는다.
@MainActor
enum MeasurementProductPhoto {
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
        // Archive records are immutable; a point correction gets a new record ID.
        let id = identifier(garmentID: garment.id, recordID: record.id)
        let name = "\(garment.id.uuidString)-\(id.uuidString).png"
        let url = directory.appending(path: name)
        if let existing = garment.photos.first(where: { $0.id == id }) {
            guard existing.fileName == name, !existing.isMeasurementSource else {
                throw ProductPhotoHandoff.HandoffError.invalidInput
            }
            return try asset(id: id, record: record, garmentID: garment.id, url: url)
        }
        guard let image = await SnapshotPresentation.thumbnail(for: record.snapshot, maximumDimension: 2048) else {
            throw ProductPhotoHandoff.HandoffError.unreadablePhoto
        }
        try Task.checkCancellation()
        let data = try render(record: record, image: image)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A file left by an interrupted insert has the same immutable identity; reuse it.
        let wroteFile = !FileManager.default.fileExists(atPath: url.path)
        if wroteFile { try data.write(to: url, options: .atomic) }
        let photo = GarmentPhoto(fileName: name, role: .detail, order: garment.photos.count)
        photo.id = id
        photo.capturedAt = record.savedAt
        photo.isSelectedForProduct = false
        do {
            let result = try asset(id: id, record: record, garmentID: garment.id, url: url)
            if case let .localFile(_, metadata) = result.source {
                photo.imageWidth = metadata.pixelWidth
                photo.imageHeight = metadata.pixelHeight
            }
            context.insert(photo)
            garment.photos.append(photo)
            try persist(context)
            return result
        } catch {
            garment.photos.removeAll { $0.id == id }
            if photo.modelContext != nil { context.delete(photo) }
            if wroteFile { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    static func identifier(garmentID: UUID, recordID: UUID) -> UUID {
        let key = "measurement-product-v1:\(garmentID):\(recordID)"
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
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
            isRecalculating: false, showsEnlargeControl: false,
            onEnlarge: {}, onMove: { _, _ in }, onEditingChanged: { _ in })
            .frame(width: 402, height: 402 / ratio)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 4
        guard let data = renderer.uiImage?.pngData() else { throw ProductPhotoHandoff.HandoffError.unreadablePhoto }
        return data
    }
}

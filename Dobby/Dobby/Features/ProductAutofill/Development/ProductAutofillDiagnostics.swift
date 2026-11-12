#if DEBUG
import Foundation
import CryptoKit
import ImageIO

/// Local Debug-only evidence of the actual encoded input and validated AI output.
/// Authorization headers, credentials and raw upstream errors are never recorded.
nonisolated enum ProductAutofillDiagnostics {
    struct Photo: Codable, Sendable, Identifiable {
        var id: String
        var purpose: String
        var originalWidth: Int
        var originalHeight: Int
        var uploadWidth: Int
        var uploadHeight: Int
        var bytes: Int
        var sha256: String
        var filename: String
    }
    struct SearchActivity: Codable, Sendable, Equatable {
        var attempts: Int?
        var completedCalls: Int?
        var status: String?
        var serverTimings: [String: Double]? = nil
        var brandStatus: String? = nil
        var brandReason: String? = nil
        static func read(_ response: HTTPURLResponse) -> Self? {
            func count(_ name: String) -> Int? {
                guard let value = response.value(forHTTPHeaderField: name), let count = Int(value), (0...5).contains(count) else { return nil }
                return count
            }
            let raw = response.value(forHTTPHeaderField: "X-Dobby-AI-Research-Status")
            let status = raw.flatMap { ["skipped", "matched", "no_match", "incomplete"].contains($0) ? $0 : nil }
            let attempts = count("X-Dobby-AI-Search-Attempts"), completed = count("X-Dobby-AI-Search-Calls")
            var timings: [String: Double] = [:]
            for stage in ["Identification", "Label-Read", "Search", "Web-Detection", "Synthesis", "Server"] {
                if let raw = response.value(forHTTPHeaderField: "X-Dobby-AI-\(stage)-Ms"),
                   let value = Double(raw), value.isFinite, (0...300_000).contains(value) { timings[stage] = value }
            }
            let rawBrandStatus = response.value(forHTTPHeaderField: "X-Dobby-AI-Brand-Status")
            let brandStatus = rawBrandStatus.flatMap { ["verified", "unverified"].contains($0) ? $0 : nil }
            let reasons = ["web_detection_photo_comparison", "verified", "invalid_candidate", "no_candidate", "low_confidence", "unreadable", "ocr_mismatch", "label_text_mismatch", "label_read_failed", "no_ocr_crop"]
            let brandReason = response.value(forHTTPHeaderField: "X-Dobby-AI-Brand-Reason").flatMap { reasons.contains($0) ? $0 : nil }
            guard attempts != nil || completed != nil || status != nil || !timings.isEmpty || brandStatus != nil else { return nil }
            return .init(attempts: attempts, completedCalls: completed, status: status,
                serverTimings: timings.isEmpty ? nil : timings, brandStatus: brandStatus, brandReason: brandReason)
        }
    }
    struct LabelCrop: Codable, Sendable {
        var id: String
        var sourcePhotoId: String
        var ocrText: String
        var filename: String
    }
    struct Record: Codable, Sendable, Identifiable {
        var id: UUID
        var createdAt: Date
        var origin: String
        var endpointHost: String
        var endpointPath: String
        var photos: [Photo]
        var outcome: String
        var statusCode: Int?
        var draft: ProductAutofillDraft?
        var search: SearchActivity? = nil
        var labelCrops: [LabelCrop]? = nil
        var timings: [String: Double]? = nil
    }
    struct Entry: Sendable, Identifiable {
        var record: Record
        var directory: URL
        var id: UUID { record.id }
    }
    static var root: URL { URL.documentsDirectory.appending(path: "AIGenerationDiagnostics", directoryHint: .isDirectory) }

    static func begin(origin: String, endpoint: URL, encoded: [ProductAutofillPhotoEncoder.Photo], assets: [CapturedAsset], labelCrops: [ProductAutofillLabelReader.Crop]? = nil) -> Entry? {
        let source = origin == "imageTest" ? "imageTest" : "productFlow"
        let parent = root.appending(path: source, directoryHint: .isDirectory)
        let id = UUID(), folder = parent.appending(path: id.uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var photos: [Photo] = []
            for (index, photo) in encoded.enumerated() {
                guard let comma = photo.imageDataUrl.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(photo.imageDataUrl[photo.imageDataUrl.index(after: comma)...])),
                      let image = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      let asset = assets.first(where: { $0.id.uuidString == photo.id }),
                      case let .localFile(_, metadata) = asset.source else { throw ProductAutofillError.unreadablePhoto }
                let filename = "upload-\(index + 1).jpg"
                try data.write(to: folder.appending(path: filename), options: .atomic)
                photos.append(.init(id: photo.id, purpose: asset.purpose.rawValue,
                    originalWidth: metadata.pixelWidth, originalHeight: metadata.pixelHeight,
                    uploadWidth: width, uploadHeight: height, bytes: data.count,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), filename: filename))
            }
            var labels: [LabelCrop]? = labelCrops == nil ? nil : []
            for (index, crop) in (labelCrops ?? []).enumerated() {
                guard let comma = crop.imageDataUrl.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(crop.imageDataUrl[crop.imageDataUrl.index(after: comma)...])) else { continue }
                let filename = "label-crop-\(index + 1).jpg"
                try data.write(to: folder.appending(path: filename), options: .atomic)
                labels?.append(.init(id: crop.id, sourcePhotoId: crop.sourcePhotoId, ocrText: crop.ocrText, filename: filename))
            }
            let entry = Entry(record: .init(id: id, createdAt: .now, origin: source,
                endpointHost: endpoint.host() ?? "", endpointPath: endpoint.path(), photos: photos,
                outcome: "requesting", statusCode: nil, draft: nil, labelCrops: labels), directory: folder)
            try write(entry)
            // Retain only the two most recent requests for each entry point.
            let older = try entries(in: parent).dropFirst(2)
            for entry in older { try? FileManager.default.removeItem(at: entry.directory) }
            return entry
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    static func finish(_ entry: Entry?, outcome: String, statusCode: Int? = nil, draft: ProductAutofillDraft? = nil, search: SearchActivity? = nil, timings: [String: Double]? = nil) {
        guard var entry else { return }
        entry.record.outcome = outcome; entry.record.statusCode = statusCode; entry.record.draft = draft; entry.record.search = search; entry.record.timings = timings
        try? write(entry)
    }

    static func latest() -> [Entry] {
        ["productFlow", "imageTest"].compactMap { origin in
            try? entries(in: root.appending(path: origin, directoryHint: .isDirectory)).first
        }
    }

    private static func entries(in parent: URL) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.id.uuidString == folder.lastPathComponent else { return nil }
            return Entry(record: record, directory: folder)
        }.sorted { $0.record.createdAt > $1.record.createdAt }
    }

    private static func write(_ entry: Entry) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry.record).write(to: entry.directory.appending(path: "manifest.json"), options: .atomic)
    }
}
#endif

import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Coordinates refer to the orientation-normalized JPEG sent for label detection.
nonisolated enum ProductAutofillLabelReader {
    struct Regions: Decodable, Sendable { let regions: [Region] }
    struct Region: Decodable, Sendable {
        let photoId: String
        let kind: String
        let box: Box
    }
    struct Box: Decodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var isValid: Bool {
            [x, y, width, height].allSatisfy(\.isFinite)
                && x >= 0 && y >= 0 && width > 0 && height > 0
                && x + width <= 1.000001 && y + height <= 1.000001
        }
    }
    struct Crop: Encodable, Sendable {
        let id: String
        let sourcePhotoId: String
        let imageDataUrl: String
        let ocrText: String
    }

    static func prepare(photos: [ProductAutofillPhotoEncoder.Photo], regions: [Region]) async throws -> [Crop] {
        let work = Task.detached(priority: .userInitiated) { try make(photos: photos, regions: regions) }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    static func pixelRect(_ box: Box, width: Int, height: Int) -> CGRect? {
        guard box.isValid, width > 0, height > 0 else { return nil }
        let iw = Double(width), ih = Double(height)
        let px = max(8, box.width * iw * 0.08), py = max(8, box.height * ih * 0.08)
        let x = max(0, floor(box.x * iw - px)), y = max(0, floor(box.y * ih - py))
        let right = min(iw, ceil((box.x + box.width) * iw + px))
        let bottom = min(ih, ceil((box.y + box.height) * ih + py))
        guard right - x >= 16, bottom - y >= 16 else { return nil }
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }

    private static func make(photos: [ProductAutofillPhotoEncoder.Photo], regions: [Region]) throws -> [Crop] {
        try Task.checkCancellation()
        guard regions.count <= 3 else { return [] }
        var candidates: [(Region, CGImage, CGRect)] = []
        for region in regions {
            guard ["neck_print", "woven_label", "care_label"].contains(region.kind),
                  let photo = photos.first(where: { $0.id == region.photoId }),
                  let comma = photo.imageDataUrl.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(photo.imageDataUrl[photo.imageDataUrl.index(after: comma)...])),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let rect = pixelRect(region.box, width: image.width, height: image.height) else { continue }
            candidates.append((region, image, rect))
        }
        candidates.sort {
            if ($0.0.kind == "care_label") != ($1.0.kind == "care_label") { return $0.0.kind != "care_label" }
            return $0.2.width * $0.2.height > $1.2.width * $1.2.height
        }
        guard let (region, image, rect) = candidates.first,
              let crop = image.cropping(to: rect) else { return [] }
        var observations: [String] = []
        let start = ContinuousClock.now
        for degrees in stride(from: 0, to: 360, by: 45) {
            try Task.checkCancellation()
            if start.duration(to: .now) > .seconds(25) { break }
            try autoreleasepool {
                guard let input = rotated(crop, degrees: degrees) else { return }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.015
                try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.8 else { continue }
                    let text = candidate.string.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                    observations.append("\(degrees)°: \(text.prefix(300))")
                }
            }
        }
        try Task.checkCancellation()
        guard !observations.isEmpty, let data = jpeg(crop) else { return [] }
        return [Crop(id: "brand-label-1", sourcePhotoId: region.photoId,
            imageDataUrl: "data:image/jpeg;base64," + data.base64EncodedString(),
            ocrText: String(observations.joined(separator: "\n").prefix(1200)))]
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        for quality in [0.85, 0.65, 0.45] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1,
                kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= 1024 * 1024 { return data as Data }
        }
        return nil
    }

    private static func rotated(_ image: CGImage, degrees: Int) -> CGImage? {
        if degrees == 0 { return image }
        let radians = CGFloat(degrees) * .pi / 180
        let width = ceil(abs(CGFloat(image.width) * cos(radians)) + abs(CGFloat(image.height) * sin(radians)))
        let height = ceil(abs(CGFloat(image.width) * sin(radians)) + abs(CGFloat(image.height) * cos(radians)))
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: width / 2, y: height / 2)
        context.rotate(by: radians)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
            width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }
}

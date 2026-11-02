import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Photo-only experiments are isolated from the capture/measurement pipeline.
/// A/B/C share one normalized source, classification, mask and physical contract.
actor OuterwearLandmarkComparisonRunner {
    private let client: OuterwearLandmarkClient
    init(client: OuterwearLandmarkClient = .makeDefault()) { self.client = client }

    func run(data: Data,
             onProgress: @Sendable (OuterwearComparisonReport) async -> Void) async throws -> OuterwearComparisonReport {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let photo = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw OuterwearLandmarkClientError.invalidImage }
        let provider = try AutoGarmentLandmarkProvider.bundled()
        let classification = try await provider.classifyOuterwearComparison(photo)
        let quarterTurn = classification.orientation == .left || classification.orientation == .right
        guard let upright = OuterwearLandmarkImageEncoder.uprightImage(photo, orientation: classification.orientation,
            width: quarterTurn ? photo.height : photo.width, height: quarterTurn ? photo.width : photo.height) else {
            throw OuterwearLandmarkClientError.invalidImage
        }
        let size = PixelSize(width: upright.width, height: upright.height)
        let masks = try GarmentForegroundMaskAnalyzer().masks(for: upright)
        guard masks.count == 1, let mask = masks.first else { throw GarmentMaskAssociationError.multipleForegrounds }
        let bounds = try OuterwearComparisonGeometry.garmentBounds(mask: mask)
        let crop = OuterwearComparisonCrop(region: .garment, rect: try OuterwearComparisonGeometry.aligned(
            OuterwearComparisonGeometry.padded(bounds), size: size))
        let full = try Self.input(upright, crop: .init(region: .garment, rect: OuterwearComparisonGeometry.full))
        var report = OuterwearComparisonReport(id: UUID(), createdAt: Date(),
            sourceSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sourceSize: size, sourceJPEG: full.record.jpeg, category: classification.category,
            orientationPrediction: classification.prediction, mask: mask, results: [],
            classifierScores: classification.scores, classifierRoute: classification.route,
            orientationResolution: classification.orientationResolution)
        for variant in OuterwearComparisonVariant.allCases {
            try Task.checkCancellation()
            let clock = ContinuousClock(), start = clock.now
            let requestID = UUID()
            var result = OuterwearComparisonResult(variant: variant, requestID: requestID,
                durationSeconds: 0, incrementalSeconds: 0, inputs: [])
            let prerequisite = report.results.first { $0.variant == .garmentCrop }
            do {
                let encoded: OuterwearLandmarkImageEncoder.Image
                let regions: [OuterwearLandmarkImageEncoder.Region]?
                let transforms: [OuterwearComparisonCrop]
                switch variant {
                case .original:
                    encoded = full.encoded; regions = nil; transforms = [full.record.crop]
                    result.inputs = [full.record]
                case .garmentCrop:
                    let prepared = try Self.input(upright, crop: crop)
                    encoded = prepared.encoded; regions = nil; transforms = [crop]
                    result.inputs = [prepared.record]
                case .localRefinement:
                    guard let prior = prerequisite?.response else {
                        throw ComparisonError.missingCropResult
                    }
                    let context = try Self.input(upright, crop: crop)
                    encoded = context.encoded
                    transforms = try OuterwearComparisonGeometry.refinementCrops(response: prior, bounds: bounds, size: size)
                    let prepared = try transforms.map { try Self.input(upright, crop: $0) }
                    regions = zip(transforms, prepared).map { .init(id: $0.0.region.rawValue, image: $0.1.encoded) }
                    result.inputs = [context.record] + prepared.map(\.record)
                    guard result.inputs.reduce(0, { $0 + $1.jpeg.count }) <= 8 * 1024 * 1024 else {
                        throw OuterwearLandmarkClientError.imageTooLarge
                    }
                }
                let local = try await client.recognizeEncoded(image: encoded, regions: regions,
                    category: classification.category, requestID: requestID)
                result.localResponse = local
                let restored = try OuterwearComparisonGeometry.restoring(local, crops: transforms)
                result.response = restored
                do {
                    result.diagnostics = try OuterwearLandmarkPolicy.evaluate(response: restored,
                        expectedRequestID: requestID.uuidString, imageSize: size, masks: [mask], orientation: .up).diagnostics
                } catch { result.validationError = error.localizedDescription }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                result.requestError = error.localizedDescription
            }
            let elapsed = start.duration(to: clock.now).components
            result.incrementalSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            result.durationSeconds = result.incrementalSeconds
                + (variant == .localRefinement ? prerequisite?.durationSeconds ?? 0 : 0)
            report.results.append(result)
            try Task.checkCancellation()
            try Self.save(report)
            await onProgress(report)
        }
        return report
    }

    nonisolated static func input(_ image: CGImage, crop: OuterwearComparisonCrop) throws
        -> (encoded: OuterwearLandmarkImageEncoder.Image, record: OuterwearComparisonInput) {
        let raster = try OuterwearLandmarkImageEncoder.croppedImage(image, rect: crop.rect)
        let encoded = try OuterwearLandmarkImageEncoder.encode(raster, orientation: .up)
        guard let comma = encoded.imageDataUrl.firstIndex(of: ","),
              let jpeg = Data(base64Encoded: String(encoded.imageDataUrl[encoded.imageDataUrl.index(after: comma)...])) else {
            throw OuterwearLandmarkClientError.invalidImage
        }
        return (encoded, .init(crop: crop, width: encoded.width, height: encoded.height, jpeg: jpeg))
    }

    nonisolated static func fileURL(_ id: UUID) throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OuterwearComparisons", isDirectory: true).appendingPathComponent(id.uuidString + ".json")
    }

    private static func save(_ report: OuterwearComparisonReport) throws {
        let url = try fileURL(report.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private enum ComparisonError: LocalizedError {
        case missingCropResult
        var errorDescription: String? { "B 크롭 응답이 없어 C 확대 비교를 실행하지 못했어요." }
    }
}

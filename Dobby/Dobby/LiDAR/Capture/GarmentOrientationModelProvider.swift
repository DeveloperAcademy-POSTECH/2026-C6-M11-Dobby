import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import os

/// Owned by one serial inference actor. Cached independently of live preview;
/// the preview silhouette never waits for this four-way classifier.
nonisolated final class GarmentOrientationModelProvider {
    private static let modelLoadSignposter = OSSignposter(subsystem: "com.dobby.lidar", category: .pointsOfInterest)
    static let resourceName = "GarmentOrientationClassifier"
    static let modelVersion = AutomaticGarmentKind.orientationModelVersion
    private let modelURL: URL
    private var model: MLModel?
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(modelURL: URL) { self.modelURL = modelURL }

    static func resourceURL(in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: resourceName, withExtension: "mlmodelc")
                ?? bundle.url(forResource: resourceName, withExtension: "mlpackage") else {
            throw GarmentOrientationError.modelMissing
        }
        return url
    }

    /// Support explicit developer-tool model directories as well as Bundle.main.
    /// A missing sibling is not silently treated as an upright prediction.
    static func siblingURL(of modelURL: URL) -> URL {
        let directory = modelURL.deletingLastPathComponent()
        let compiled = directory.appendingPathComponent(resourceName + ".mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        return directory.appendingPathComponent(resourceName + ".mlpackage")
    }

    func classify(_ source: CGImage, deviceOrientation: ImageOrientation) throws -> GarmentOrientationPrediction {
        try Task.checkCancellation()
        let image = try Self.orientedImage(source, orientation: deviceOrientation, context: context)
        let input = try Self.pixelBuffer(image)
        let model = try loadedModel()
        // Core ML loading may finish after the photo's task has timed out.
        // Retain the prepared model but skip an already cancelled prediction.
        try Task.checkCancellation()
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        let output = try model.prediction(from: features)
        try Task.checkCancellation()
        guard let feature = output.featureValue(for: "correctionClockwise_probs"), feature.type == .dictionary else {
            throw GarmentOrientationError.invalidProbabilities
        }
        var probabilities: [Int: Double] = [:]
        for (key, value) in feature.dictionaryValue {
            guard let label = key.base as? String, let angle = Int(label),
                  GarmentOrientationCorrection(rawValue: angle) != nil, probabilities[angle] == nil else {
                throw GarmentOrientationError.invalidProbabilities
            }
            probabilities[angle] = value.doubleValue
        }
        return try .init(probabilities: probabilities)
    }

    private func loadedModel() throws -> MLModel {
        if let model { return model }
        let interval = Self.modelLoadSignposter.beginInterval("GarmentOrientationModelLoad",
            id: Self.modelLoadSignposter.makeSignpostID())
        defer { Self.modelLoadSignposter.endInterval("GarmentOrientationModelLoad", interval) }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw GarmentOrientationError.modelMissing }
        let url = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        let description = loaded.modelDescription
        guard description.inputDescriptionsByName.count == 1,
              let input = description.inputDescriptionsByName["image"], input.type == .image,
              let constraint = input.imageConstraint,
              constraint.pixelsWide == GarmentOrientationLetterbox.side,
              constraint.pixelsHigh == GarmentOrientationLetterbox.side,
              constraint.pixelFormatType == kCVPixelFormatType_32BGRA,
              description.predictedFeatureName == "correctionClockwise",
              description.predictedProbabilitiesName == "correctionClockwise_probs",
              description.outputDescriptionsByName["correctionClockwise"]?.type == .string,
              description.outputDescriptionsByName["correctionClockwise_probs"]?.type == .dictionary else {
            throw GarmentOrientationError.invalidModelInput
        }
        model = loaded
        return loaded
    }

    static func orientedImage(_ image: CGImage, orientation: ImageOrientation, context: CIContext) throws -> CGImage {
        guard orientation != .up else { return image }
        let exif: Int32
        switch orientation {
        case .up: exif = 1
        case .right: exif = 6
        case .down: exif = 3
        case .left: exif = 8
        }
        let rotated = CIImage(cgImage: image).oriented(forExifOrientation: exif)
        guard let output = context.createCGImage(rotated, from: rotated.extent,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw GarmentOrientationError.invalidImage
        }
        return output
    }

    /// Raw sRGB bytes. CGContext .low is bilinear; model ImageType supplies the
    /// only 1/255 normalization. Odd extra padding belongs on bottom/right.
    static func pixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        let layout = try GarmentOrientationLetterbox(size: .init(width: image.width, height: image.height))
        let side = GarmentOrientationLetterbox.side
        var candidate: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &candidate) == kCVReturnSuccess, let buffer = candidate,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw GarmentOrientationError.inputBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw GarmentOrientationError.inputBuffer
        }
        let gray = CGFloat(GarmentOrientationLetterbox.padding) / 255
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [gray, gray, gray, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: layout.offsetX, y: side - layout.offsetY - layout.resizedHeight,
            width: layout.resizedWidth, height: layout.resizedHeight))
        return buffer
    }
}

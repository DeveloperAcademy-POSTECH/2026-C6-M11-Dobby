#!/usr/bin/env swift
// Local Core ML smoke check. No network, Python/pickle loading, or app installation.
// xcrun swift Tools/validate-bottom-model.swift <model.mlpackage> <image> [image ...]
// Optional: --repeats 3 --output /tmp/report.json --preview-directory /tmp/previews
// This checks inference plumbing, not landmark accuracy or physical cm accuracy.
import CoreML
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SmokeError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case let .invalid(message): return message } }
}

func featureDescription(_ description: MLFeatureDescription) -> [String: Any] {
    var value: [String: Any] = ["type": String(describing: description.type), "optional": description.isOptional]
    if let image = description.imageConstraint {
        value["width"] = image.pixelsWide
        value["height"] = image.pixelsHigh
        value["pixelFormat"] = image.pixelFormatType
    }
    if let array = description.multiArrayConstraint {
        value["shape"] = array.shape.map(\.intValue)
        value["dataType"] = array.dataType.rawValue
    }
    return value
}

func orientedImage(at url: URL, context: CIContext) throws -> CGImage {
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
          let result = context.createCGImage(image, from: image.extent) else {
        throw SmokeError.invalid("Cannot decode image: \(url.path)")
    }
    return result
}

func letterbox(_ image: CGImage, width: Int, height: Int) throws -> (CVPixelBuffer, [String: Any]) {
    var result: CVPixelBuffer?
    let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                      kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                              attributes, &result) == kCVReturnSuccess, let buffer = result else {
        throw SmokeError.invalid("Could not allocate image buffer")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) else {
        throw SmokeError.invalid("Could not create image drawing context")
    }
    let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
    // Match Ultralytics' integer-resized image and split odd padding consistently.
    let resizedWidth = Int((Double(image.width) * scale).rounded(.toNearestOrEven))
    let resizedHeight = Int((Double(image.height) * scale).rounded(.toNearestOrEven))
    let left = (width - resizedWidth) / 2
    let top = (height - resizedHeight) / 2
    let bottom = height - resizedHeight - top
    context.setFillColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: left, y: bottom, width: resizedWidth, height: resizedHeight))
    return (buffer, ["scale": scale, "padLeft": left, "padTop": top,
                     "resizedWidth": resizedWidth, "resizedHeight": resizedHeight,
                     "grayPadding": 114, "orientedImageWidth": image.width, "orientedImageHeight": image.height])
}

func writePreview(_ buffer: CVPixelBuffer, to url: URL, context: CIContext) throws {
    let image = CIImage(cvPixelBuffer: buffer)
    guard let cgImage = context.createCGImage(image, from: image.extent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw SmokeError.invalid("Cannot create preview: \(url.path)")
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { throw SmokeError.invalid("Cannot write preview") }
}

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var repeats = 3
    var outputURL: URL?
    var previewDirectory: URL?
    func consume(_ flag: String) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard index + 1 < arguments.count else { throw SmokeError.invalid("Missing value for \(flag)") }
        let value = arguments[index + 1]
        arguments.removeSubrange(index ... index + 1)
        return value
    }
    if let value = try consume("--repeats") {
        guard let count = Int(value), (1 ... 100).contains(count) else { throw SmokeError.invalid("--repeats must be 1...100") }
        repeats = count
    }
    if let value = try consume("--output") { outputURL = URL(fileURLWithPath: value) }
    if let value = try consume("--preview-directory") {
        previewDirectory = URL(fileURLWithPath: value, isDirectory: true)
        try FileManager.default.createDirectory(at: previewDirectory!, withIntermediateDirectories: true)
    }
    guard arguments.count >= 2 else {
        throw SmokeError.invalid("Usage: validate-bottom-model.swift <model.mlpackage|mlmodelc> <image> [image ...] [--repeats 3] [--output report.json] [--preview-directory previews]")
    }
    let sourceURL = URL(fileURLWithPath: arguments.removeFirst())
    let compiledURL = sourceURL.pathExtension == "mlmodelc" ? sourceURL : try MLModel.compileModel(at: sourceURL)
    defer { if compiledURL != sourceURL { try? FileManager.default.removeItem(at: compiledURL) } }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let loadStart = CFAbsoluteTimeGetCurrent()
    let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
    let loadMilliseconds = (CFAbsoluteTimeGetCurrent() - loadStart) * 1_000
    let description = model.modelDescription
    guard description.inputDescriptionsByName.count == 1,
          let input = description.inputDescriptionsByName.first,
          let imageConstraint = input.value.imageConstraint else {
        throw SmokeError.invalid("Expected one image input; got \(description.inputDescriptionsByName)")
    }
    let context = CIContext(options: [.cacheIntermediates: false])
    var imageReports: [[String: Any]] = []
    for path in arguments {
        let imageURL = URL(fileURLWithPath: path)
        let image = try orientedImage(at: imageURL, context: context)
        let (buffer, preprocessing) = try letterbox(image, width: imageConstraint.pixelsWide, height: imageConstraint.pixelsHigh)
        if let directory = previewDirectory {
            try writePreview(buffer, to: directory.appendingPathComponent(imageURL.deletingPathExtension().lastPathComponent + "-letterbox.png"), context: context)
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [input.key: MLFeatureValue(pixelBuffer: buffer)])
        var milliseconds: [Double] = []
        var prediction: MLFeatureProvider?
        for _ in 0 ..< repeats {
            let start = CFAbsoluteTimeGetCurrent()
            prediction = try model.prediction(from: features)
            milliseconds.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        guard let prediction else { throw SmokeError.invalid("No prediction") }
        var outputs: [String: Any] = [:]
        for name in prediction.featureNames.sorted() {
            guard let array = prediction.featureValue(for: name)?.multiArrayValue else { continue }
            var minimum = Double.infinity
            var maximum = -Double.infinity
            var nonFinite = 0
            for index in 0 ..< array.count {
                let value = array[index].doubleValue
                if value.isFinite { minimum = min(minimum, value); maximum = max(maximum, value) }
                else { nonFinite += 1 }
            }
            let shape = array.shape.map(\.intValue)
            var output: [String: Any] = ["shape": shape, "strides": array.strides.map(\.intValue), "count": array.count,
                                         "nonFiniteCount": nonFinite, "minimum": minimum.isFinite ? minimum : NSNull(),
                                         "maximum": maximum.isFinite ? maximum : NSNull()]
            if shape == [1, 26, 8_400] || shape == [1, 29, 8_400] {
                func value(_ channel: Int, _ anchor: Int) -> Double { array[[0, NSNumber(value: channel), NSNumber(value: anchor)]].doubleValue }
                let best = (0 ..< shape[2]).max { value(4, $0) < value(4, $1) }!
                output["bestAnchor"] = best
                output["objectConfidence"] = value(4, best)
                output["passesProvidedObjectThreshold025"] = value(4, best) >= 0.25
                output["boxCXCYWH"] = (0 ..< 4).map { value($0, best) }
                let pointCount = (shape[1] - 5) / 3
                output["keypointsXYConfidence"] = (0 ..< pointCount).map { index in (0 ..< 3).map { value(5 + index * 3 + $0, best) } }
            }
            outputs[name] = output
        }
        imageReports.append(["path": imageURL.path, "preprocessing": preprocessing,
                             "predictionMilliseconds": milliseconds, "outputs": outputs])
    }
    let report: [String: Any] = ["modelPath": sourceURL.path, "computeUnits": "all", "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                                "modelLoadMilliseconds": loadMilliseconds,
                                "inputs": description.inputDescriptionsByName.mapValues(featureDescription),
                                "outputs": description.outputDescriptionsByName.mapValues(featureDescription),
                                "metadata": Dictionary(uniqueKeysWithValues: description.metadata.map { ($0.key.rawValue, String(describing: $0.value)) }),
                                "images": imageReports, "limitation": "Local inference smoke test only. No labeled ground truth; scores do not measure point or physical cm accuracy. Timing is this Mac, not an iPhone."]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if let outputURL { try data.write(to: outputURL, options: .atomic) }
    print(String(decoding: data, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("Bottom model smoke test failed: \(error)\n".utf8))
    exit(1)
}

// Reproducible check of the app's actual Core ML adapter, preprocessing, and decoder.
// Run from the repository root on macOS with Xcode installed:
// xcrun swiftc -parse-as-library Dobby/Dobby/LiDAR/Core/*.swift \
//   Dobby/Dobby/LiDAR/Capture/CoreMLBottomLandmarkProvider.swift \
//   Dobby/Dobby/LiDAR/Capture/GarmentForegroundMaskAnalyzer.swift \
//   Dobby/Dobby/LiDAR/Capture/GarmentOrientationModelProvider.swift \
//   Tools/validate-bottom-provider.swift -o /tmp/validate-bottom-provider
// /tmp/validate-bottom-provider <BottomLandmarks.mlpackage|mlmodelc> \
//   <schema_bottom8.json> <photo> [photo ...] [--output /tmp/provider-report.json]
// Photos are local files. No network, PyTorch/pickle loading, or device installation.
// The frame-adapter check uses empty synthetic depth and NEVER computes centimetres.

import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

private enum ProviderCheckError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case let .invalid(message): return message } }
}

private struct ImageReport: Codable {
    var imagePath: String
    var status: String
    var rawEXIFOrientation: Int?
    var outputOrientation: String?
    var imageSize: PixelSize?
    var points: [GarmentLandmark]?
    var detectionConfidence: Double?
    var modelVersion: String?
    var elapsedSeconds: Double?
    var error: String?
}

private struct AdapterCheck: Codable {
    var imagePath: String
    var imageSize: PixelSize
    var frameOrientation: ImageOrientation
    var sessionID: UUID
    var frameID: UUID
    var sessionPreserved: Bool
    var framePreserved: Bool
    var origin: LandmarkOrigin
    var modelVersion: String?
    var pointCount: Int
    var inputDepthIsEmpty: Bool
    var didComputeCentimetres: Bool
}

private struct OrientationCheck: Codable {
    var frameOrientation: ImageOrientation
    var inverseRawPixelRotationEXIF: Int32
    var rawImageSize: PixelSize?
    var pointCount: Int?
    var maximumNormalizedCoordinateDelta: Double?
    var maximumConfidenceDelta: Double?
    var frameIdentityPreserved: Bool
    var passed: Bool
    var error: String?
}

private struct OrientationReport: Codable {
    var imagePath: String
    var baselineOrientation: ImageOrientation
    var uprightSize: PixelSize
    var baselinePointCount: Int
    var coordinateTolerance: Double
    var confidenceTolerance: Double
    var checks: [OrientationCheck]
    var explanation: String
}

private struct ProviderReport: Codable {
    var modelPath: String
    var schemaPath: String
    var platform: String
    var recordedAt: Date
    var images: [ImageReport]
    var adapterCheck: AdapterCheck?
    var adapterError: String?
    var orientationReport: OrientationReport?
    var orientationError: String?
    var limitations: [String]
}

@main
private struct BottomProviderValidation {
    static func validatePoints(_ points: [GarmentLandmark]) throws {
        guard !points.isEmpty, Set(points.map(\.id)).count == points.count,
              points.allSatisfy({ point in
                  point.point.isValid && point.confidence.map { $0.isFinite && $0 >= 0 && $0 <= 1 } == true
              }) else {
            throw ProviderCheckError.invalid("Adapter returned missing, duplicate, non-finite, or out-of-bounds landmarks")
        }
    }

    static func checkFrameAdapter(provider: CoreMLBottomLandmarkProvider, data: Data, imageURL: URL) async throws -> AdapterCheck {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProviderCheckError.invalid("Could not decode raw RGB image")
        }
        let size = PixelSize(width: raw.width, height: raw.height)
        let sessionID = UUID(), frameID = UUID()
        // Deliberately incomplete calibration/depth: only the RGB -> landmark
        // adapter contract is under test; this fixture must not measure length.
        let frame = MeasurementFrame(sessionID: sessionID, frameID: frameID,
            timestamp: 0, capturedAt: Date(), imageSize: size,
            intrinsics: .init(fx: 1, fy: 1, cx: 0, cy: 0, referenceSize: size),
            depth: .init(size: .init(width: 0, height: 0), values: [], confidence: nil),
            source: .synthetic, orientation: .up)
        let landmarks = try await provider.landmarks(for: CaptureSnapshot(frame: frame, imageJPEG: data))
        try validatePoints(landmarks.points)
        guard landmarks.sessionID == sessionID, landmarks.frameID == frameID,
              landmarks.origin == .model, landmarks.modelVersion == provider.modelVersion else {
            throw ProviderCheckError.invalid("Adapter did not preserve frame/session IDs or expected model provenance")
        }
        return .init(imagePath: imageURL.path, imageSize: size, frameOrientation: .up,
            sessionID: sessionID, frameID: frameID, sessionPreserved: true, framePreserved: true,
            origin: landmarks.origin, modelVersion: landmarks.modelVersion, pointCount: landmarks.points.count,
            inputDepthIsEmpty: true, didComputeCentimetres: false)
    }

    static func losslessPNG(_ image: CGImage) throws -> Data {
        guard let data = CFDataCreateMutable(kCFAllocatorDefault, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ProviderCheckError.invalid("Could not create lossless PNG fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ProviderCheckError.invalid("Could not encode PNG fixture") }
        return data as Data
    }

    static func orientationSnapshot(_ image: CGImage, orientation: ImageOrientation) throws -> CaptureSnapshot {
        let size = PixelSize(width: image.width, height: image.height)
        return .init(frame: .init(sessionID: UUID(), frameID: UUID(), timestamp: 0, capturedAt: Date(),
            imageSize: size, intrinsics: .init(fx: 1, fy: 1, cx: 0, cy: 0, referenceSize: size),
            depth: .init(size: .init(width: 0, height: 0), values: [], confidence: nil),
            source: .synthetic, orientation: orientation), imageJPEG: try losslessPNG(image))
    }

    static func checkOrientations(provider: CoreMLBottomLandmarkProvider, data: Data, imageURL: URL) async throws -> OrientationReport {
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let photo = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let upright = context.createCGImage(photo, from: photo.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw ProviderCheckError.invalid("Could not create upright orientation fixture")
        }
        let baselineSnapshot = try orientationSnapshot(upright, orientation: .up)
        let baseline = try await provider.landmarks(for: baselineSnapshot)
        try validatePoints(baseline.points)
        guard baseline.sessionID == baselineSnapshot.frame.sessionID,
              baseline.frameID == baselineSnapshot.frame.frameID, baseline.origin == .model else {
            throw ProviderCheckError.invalid("Baseline orientation frame identity was not preserved")
        }
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.points.map { ($0.id, $0) })
        let tolerance = 2.0 / 640
        var checks: [OrientationCheck] = []
        for orientation in [ImageOrientation.right, .down, .left] {
            // Physically rotate the stored pixels in the opposite direction.
            // Applying frame orientation inside the real provider must restore
            // the SAME upright image before the same network sees it.
            let inverse: Int32
            switch orientation {
            case .up: inverse = 1
            case .right: inverse = 8
            case .down: inverse = 3
            case .left: inverse = 6
            }
            var check = OrientationCheck(frameOrientation: orientation, inverseRawPixelRotationEXIF: inverse,
                frameIdentityPreserved: false, passed: false)
            do {
                let raw = CIImage(cgImage: upright).oriented(forExifOrientation: inverse)
                guard let rawImage = context.createCGImage(raw, from: raw.extent, format: .RGBA8, colorSpace: colorSpace) else {
                    throw ProviderCheckError.invalid("Could not rotate raw image pixels")
                }
                let snapshot = try orientationSnapshot(rawImage, orientation: orientation)
                check.rawImageSize = snapshot.frame.imageSize
                let result = try await provider.landmarks(for: snapshot)
                try validatePoints(result.points)
                check.pointCount = result.points.count
                check.frameIdentityPreserved = result.sessionID == snapshot.frame.sessionID
                    && result.frameID == snapshot.frame.frameID && result.origin == .model
                    && result.modelVersion == baseline.modelVersion
                guard check.frameIdentityPreserved,
                      Set(result.points.map(\.id)) == Set(baselineByID.keys) else {
                    throw ProviderCheckError.invalid("Rotated inference changed frame identity or landmark IDs")
                }
                var maximumCoordinateDelta = 0.0, maximumConfidenceDelta = 0.0
                for point in result.points {
                    let expected = baselineByID[point.id]!
                    let displayed = ImageCoordinateTransform.originalToDisplay(point.point, orientation: orientation)
                    maximumCoordinateDelta = max(maximumCoordinateDelta,
                        abs(displayed.x - expected.point.x), abs(displayed.y - expected.point.y))
                    maximumConfidenceDelta = max(maximumConfidenceDelta, abs(point.confidence! - expected.confidence!))
                }
                check.maximumNormalizedCoordinateDelta = maximumCoordinateDelta
                check.maximumConfidenceDelta = maximumConfidenceDelta
                check.passed = maximumCoordinateDelta <= tolerance && maximumConfidenceDelta <= tolerance
                if !check.passed { check.error = "Rotated raw pixels/frame orientation did not reproduce upright inference within tolerance" }
            } catch { check.error = String(describing: error) }
            checks.append(check)
        }
        return .init(imagePath: imageURL.path, baselineOrientation: .up,
            uprightSize: .init(width: upright.width, height: upright.height), baselinePointCount: baseline.points.count,
            coordinateTolerance: tolerance, confidenceTolerance: tolerance, checks: checks,
            explanation: "Lossless PNG fixtures physically rotate one real photo's raw pixels opposite to each frame orientation. The actual provider runs preprocessing, Core ML, and decoding; output coordinates transform back to the same upright reference. This is an adapter consistency regression, not ground-truth accuracy or a centimetre test.")
    }

    static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            var reportURL: URL?
            if let index = arguments.firstIndex(of: "--output") {
                guard index + 1 < arguments.count else { throw ProviderCheckError.invalid("Missing --output path") }
                reportURL = URL(fileURLWithPath: arguments[index + 1])
                arguments.removeSubrange(index ... index + 1)
            }
            guard arguments.count >= 3 else {
                throw ProviderCheckError.invalid("Usage: validate-bottom-provider <model.mlpackage|mlmodelc> <schema.json> <photo> [photo ...] [--output report.json]")
            }
            let modelURL = URL(fileURLWithPath: arguments.removeFirst())
            let schemaURL = URL(fileURLWithPath: arguments.removeFirst())
            let schema = try BottomLandmarkSchema(jsonData: Data(contentsOf: schemaURL))
            let provider = CoreMLBottomLandmarkProvider(modelURL: modelURL, schema: schema)
            var reports: [ImageReport] = []
            var adapter: AdapterCheck?
            var adapterError: String?
            var orientationPhoto: (data: Data, url: URL)?
            for (index, path) in arguments.enumerated() {
                let imageURL = URL(fileURLWithPath: path)
                var report = ImageReport(imagePath: imageURL.path, status: "failed")
                do {
                    let data = try Data(contentsOf: imageURL)
                    if let source = CGImageSourceCreateWithData(data as CFData, nil),
                       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                        report.rawEXIFOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                    }
                    let result = try await provider.recognizePhoto(data)
                    try validatePoints(result.points)
                    guard result.imageSize.isValid, result.detectionConfidence.isFinite,
                          (0 ... 1).contains(result.detectionConfidence), !result.imageJPEG.isEmpty else {
                        throw ProviderCheckError.invalid("Invalid photo recognition result")
                    }
                    report.status = "passed"
                    report.outputOrientation = "EXIF-normalized up"
                    report.imageSize = result.imageSize
                    report.points = result.points
                    report.detectionConfidence = result.detectionConfidence
                    report.modelVersion = result.modelVersion
                    report.elapsedSeconds = result.durationSeconds
                    orientationPhoto = (data, imageURL)
                    if index == 0 {
                        do { adapter = try await checkFrameAdapter(provider: provider, data: data, imageURL: imageURL) }
                        catch { adapterError = String(describing: error) }
                    }
                } catch { report.error = String(describing: error) }
                reports.append(report)
            }
            var orientationReport: OrientationReport?
            var orientationError: String?
            if let photo = orientationPhoto {
                do { orientationReport = try await checkOrientations(provider: provider, data: photo.data, imageURL: photo.url) }
                catch { orientationError = String(describing: error) }
            } else { orientationError = "No successfully recognized photo was available for orientation checks" }
            let report = ProviderReport(modelPath: modelURL.path, schemaPath: schemaURL.path,
                platform: ProcessInfo.processInfo.operatingSystemVersionString, recordedAt: Date(),
                images: reports, adapterCheck: adapter, adapterError: adapterError,
                orientationReport: orientationReport, orientationError: orientationError,
                limitations: ["Real-photo inference integration check, without ground-truth landmark labels.",
                              "Confidence is model output, not measured landmark or centimetre accuracy.",
                              "Frame/session/origin check uses empty synthetic depth; no distance engine runs.",
                              "Timing is this Mac, not an iPhone; the first photo includes model compilation/loading."])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if let reportURL { try data.write(to: reportURL, options: .atomic) }
            print(String(decoding: data, as: UTF8.self))
            if reports.contains(where: { $0.status != "passed" }) || adapter == nil || adapterError != nil
                || orientationReport == nil || orientationError != nil
                || orientationReport?.checks.contains(where: { !$0.passed }) == true { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("Bottom provider check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

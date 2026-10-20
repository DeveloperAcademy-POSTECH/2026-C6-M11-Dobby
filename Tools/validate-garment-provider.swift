// Validate the actual selected-model adapter on macOS. From the repository root:
// xcrun swiftc -parse-as-library Dobby/Dobby/LiDAR/Core/*.swift \
//   Dobby/Dobby/LiDAR/Capture/CoreMLBottomLandmarkProvider.swift \
//   Dobby/Dobby/LiDAR/Capture/CoreMLGarmentLandmarkProvider.swift \
//   Dobby/Dobby/LiDAR/Capture/GarmentForegroundMaskAnalyzer.swift \
//   Dobby/Dobby/LiDAR/Capture/GarmentOrientationModelProvider.swift \
//   Tools/validate-garment-provider.swift -o /tmp/validate-garment-provider
// /tmp/validate-garment-provider --kind top --model <TopLandmarks.mlpackage> \
//   --schema <schema_top.json> --report <report.json> \
//   [--wrong-kind-photo <photo>] <photo> [photo ...]
// This tool does not load training checkpoints or compute centimetres. Snapshot
// fixtures deliberately have empty depth; foreground-mask checks are reported
// separately because Vision availability is platform-dependent.

import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

private enum ValidationError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): message } }
}

private struct Options {
    var kind: AutomaticGarmentKind
    var model: URL
    var schema: URL
    var report: URL?
    var photos: [URL]
    var wrongKindPhotos: [URL]

    static func parse(_ arguments: [String]) throws -> Self {
        var kind: AutomaticGarmentKind?
        var model: URL?, schema: URL?, report: URL?
        var photos: [URL] = [], wrongKind: [URL] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if !argument.hasPrefix("--") {
                photos.append(URL(fileURLWithPath: argument))
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw ValidationError.invalid("Missing value after \(argument)")
            }
            let value = arguments[index + 1]
            switch argument {
            case "--kind":
                guard let parsed = AutomaticGarmentKind(rawValue: value) else {
                    throw ValidationError.invalid("--kind must be top or bottoms")
                }
                kind = parsed
            case "--model": model = URL(fileURLWithPath: value)
            case "--schema": schema = URL(fileURLWithPath: value)
            case "--report": report = URL(fileURLWithPath: value)
            case "--wrong-kind-photo": wrongKind.append(URL(fileURLWithPath: value))
            default: throw ValidationError.invalid("Unknown option \(argument)")
            }
            index += 2
        }
        guard let kind, let model, let schema, !photos.isEmpty else {
            throw ValidationError.invalid("Usage: --kind top|bottoms --model <model> --schema <schema> [--report <json>] [--wrong-kind-photo <photo>] <photo> [photo ...]")
        }
        return .init(kind: kind, model: model, schema: schema, report: report,
                     photos: photos, wrongKindPhotos: wrongKind)
    }
}

private struct PhotoCheck: Codable {
    var path: String
    var passed = false
    var rawEXIFOrientation: Int?
    var outputOrientation: String?
    var imageSize: PixelSize?
    var directPointCount: Int?
    var derivedPointCount: Int?
    var points: [GarmentLandmark]?
    var detectionConfidence: Double?
    var modelVersion: String?
    var elapsedSeconds: Double?
    var error: String?
}

private struct RepeatCheck: Codable {
    var path: String
    var passed = false
    var maximumCoordinateDelta: Double?
    var maximumConfidenceDelta: Double?
    var repeatedElapsedSeconds: Double?
    var error: String?
}

private struct SnapshotCheck: Codable {
    var orientation: ImageOrientation
    var sessionID: UUID
    var frameID: UUID
    var rawImageSize: PixelSize
    var inputDepthIsEmpty = true
    var didComputeCentimetres = false
    var passed = false
    var frameIdentityPreserved: Bool?
    var modelVersion: String?
    var pointCount: Int?
    var unavailablePointIDs: [String]?
    var maskSize: PixelSize?
    var maskForegroundPixelCount: Int?
    var uprightMaskSize: PixelSize?
    var maskIntersectionOverUnionVsUpright: Double?
    var maskComparisonPassed: Bool?
    var maskComparisonError: String?
    var error: String?
}

private struct PhotoForegroundCheck: Codable {
    var path: String
    var snapshot: SnapshotCheck?
    var liveAndCaptureCoordinateDelta: Double?
    var liveAndCaptureConfidenceDelta: Double?
    var liveAndCaptureMaskIntersectionOverUnion: Double?
    var visibilityPreserved: Bool?
    var passed = false
    var error: String?
}

private struct RotationCheck: Codable {
    var orientation: ImageOrientation
    var inverseRawPixelRotationEXIF: Int32
    var rawImageSize: PixelSize?
    var passed = false
    var maximumCoordinateDelta: Double?
    var maximumConfidenceDelta: Double?
    var snapshot: SnapshotCheck?
    var error: String?
}

private struct OrientationChecks: Codable {
    var path: String
    var fixtureDescription: String
    var uprightImageSize: PixelSize
    var coordinateTolerance: Double
    var confidenceTolerance: Double
    var minimumMaskIntersectionOverUnion: Double
    var baselinePointCount: Int
    var checks: [RotationCheck]
}

private struct NegativeCheck: Codable {
    var source: String
    var purpose: String
    var accepted: Bool?
    var expectedEmptyRejectionPassed: Bool?
    var detectionConfidence: Double?
    var pointCount: Int?
    var modelVersion: String?
    var error: String?
    var captureAdapterAccepted: Bool?
    var captureAdapterError: String?
    var captureFrameIdentityPreserved: Bool?
    var captureInputDepthIsEmpty: Bool?
    var didComputeCentimetres: Bool?
}

private struct ValidationReport: Codable {
    var kind: String
    var modelPath: String
    var schemaPath: String
    var modelVersion: String
    var schemaDirectPointCount: Int
    var schemaDerivedPointIDs: [String]
    var measurementDefinitions: [MeasurementDefinition]
    var platform: String
    var recordedAt: Date
    var requiredChecksPassed: Bool
    var foregroundChecksPassed: Bool
    var photos: [PhotoCheck]
    var photoForegroundChecks: [PhotoForegroundCheck]
    var repeatCheck: RepeatCheck?
    var orientationChecks: OrientationChecks?
    var orientationError: String?
    var emptyImages: [NegativeCheck]
    var wrongKindImages: [NegativeCheck]
    var limitations: [String]
}

@main
private struct GarmentProviderValidation {
    private static let tolerance = 2.0 / 640

    private static func validatePoints(_ points: [GarmentLandmark], provider: CoreMLGarmentLandmarkProvider) throws {
        let identifiers = Set(points.map(\.id))
        let known = Set(provider.keypoints + provider.schema.derivedOrder)
        guard !points.isEmpty, identifiers.count == points.count,
              identifiers.isSubset(of: known), Set(provider.keypoints).isSubset(of: identifiers),
              points.allSatisfy({ $0.point.isValid && $0.confidence.map { $0.isFinite && (0 ... 1).contains($0) } == true }) else {
            throw ValidationError.invalid("Missing schema points, duplicate IDs, invalid confidence, or out-of-bounds coordinates")
        }
    }

    private static func compare(_ points: [GarmentLandmark], to baseline: [GarmentLandmark],
                                orientation: ImageOrientation = .up) throws -> (coordinate: Double, confidence: Double) {
        let expected = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        guard Set(points.map(\.id)) == Set(expected.keys) else {
            throw ValidationError.invalid("Landmark identities changed")
        }
        var coordinate = 0.0, confidence = 0.0
        for point in points {
            let reference = expected[point.id]!
            let displayed = ImageCoordinateTransform.originalToDisplay(point.point, orientation: orientation)
            coordinate = max(coordinate, abs(displayed.x - reference.point.x), abs(displayed.y - reference.point.y))
            confidence = max(confidence, abs(point.confidence! - reference.confidence!))
        }
        return (coordinate, confidence)
    }

    private static func photoCheck(_ data: Data, path: String, provider: CoreMLGarmentLandmarkProvider) async -> PhotoCheck {
        var check = PhotoCheck(path: path)
        do {
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                check.rawEXIFOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            }
            let result = try await provider.recognizePhoto(data)
            try validatePoints(result.points, provider: provider)
            guard result.imageSize.isValid, (0 ... 1).contains(result.detectionConfidence),
                  result.modelVersion == provider.modelVersion, !result.imageJPEG.isEmpty else {
                throw ValidationError.invalid("Invalid photo image, score, or provenance")
            }
            check.passed = true
            check.outputOrientation = "EXIF-normalized up"
            check.imageSize = result.imageSize
            check.directPointCount = result.points.filter { provider.keypoints.contains($0.id) }.count
            check.derivedPointCount = result.points.filter { provider.schema.derived[$0.id] != nil }.count
            check.points = result.points
            check.detectionConfidence = result.detectionConfidence
            check.modelVersion = result.modelVersion
            check.elapsedSeconds = result.durationSeconds
        } catch { check.error = String(describing: error) }
        return check
    }

    private static func losslessPNG(_ image: CGImage) throws -> Data {
        guard let data = CFDataCreateMutable(kCFAllocatorDefault, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ValidationError.invalid("Could not create lossless RGB fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ValidationError.invalid("Could not encode RGB fixture") }
        return data as Data
    }

    private static func snapshotCheck(_ image: CGImage, orientation: ImageOrientation,
                                      provider: CoreMLGarmentLandmarkProvider) async -> (check: SnapshotCheck, mask: GarmentMask?, points: [GarmentLandmark]?) {
        let size = PixelSize(width: image.width, height: image.height)
        let session = UUID(), frameID = UUID()
        var check = SnapshotCheck(orientation: orientation, sessionID: session, frameID: frameID, rawImageSize: size)
        var mask: GarmentMask?
        var points: [GarmentLandmark]?
        do {
            let frame = MeasurementFrame(sessionID: session, frameID: frameID, timestamp: 0, capturedAt: Date(),
                imageSize: size, intrinsics: .init(fx: 1, fy: 1, cx: 0, cy: 0, referenceSize: size),
                depth: .init(size: .init(width: 0, height: 0), values: [], confidence: nil),
                source: .synthetic, orientation: orientation)
            let result = try await provider.landmarks(for: .init(frame: frame, imageJPEG: losslessPNG(image)))
            try validatePoints(result.points, provider: provider)
            mask = result.mask
            points = result.points
            check.frameIdentityPreserved = result.sessionID == session && result.frameID == frameID && result.origin == .model
            check.modelVersion = result.modelVersion
            check.pointCount = result.points.count
            check.unavailablePointIDs = result.points.filter { !$0.isVisible }.map(\.id).sorted()
            check.maskSize = result.mask?.size
            check.maskForegroundPixelCount = result.mask?.values.filter { $0 != 0 }.count
            check.passed = check.frameIdentityPreserved == true && result.modelVersion == provider.modelVersion
                && (check.maskForegroundPixelCount ?? 0) > 0
            if !check.passed { throw ValidationError.invalid("Snapshot identity, provenance, or associated foreground mask was not preserved") }
        } catch { check.error = String(describing: error) }
        return (check, mask, points)
    }

    /// Compare the live and frozen adapters on the exact same lossless RGB.
    /// This catches divergence in rotation recovery, point visibility or masks
    /// without pretending that a photo provides real sensor depth.
    private static func photoForegroundCheck(_ data: Data, path: String,
                                             provider: CoreMLGarmentLandmarkProvider) async -> PhotoForegroundCheck {
        var check = PhotoForegroundCheck(path: path)
        do {
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let photo = CIImage(data: data, options: [.applyOrientationProperty: true]),
                  let image = context.createCGImage(photo, from: photo.extent) else {
                throw ValidationError.invalid("Could not decode exact upright photo")
            }
            let live = try await provider.recognizeForeground(image, orientation: .up)
            let captured = await snapshotCheck(image, orientation: .up, provider: provider)
            check.snapshot = captured.check
            guard captured.check.passed, let points = captured.points, let mask = captured.mask else {
                throw ValidationError.invalid(captured.check.error ?? "Frozen adapter rejected the photo")
            }
            let delta = try compare(live.recognition.points, to: points)
            check.liveAndCaptureCoordinateDelta = delta.coordinate
            check.liveAndCaptureConfidenceDelta = delta.confidence
            check.liveAndCaptureMaskIntersectionOverUnion = try maskIntersectionOverUnion(live.selection.mask, mask)
            let expectedVisibility = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0.isVisible) })
            check.visibilityPreserved = live.recognition.points.allSatisfy { expectedVisibility[$0.id] == $0.isVisible }
            check.passed = delta.coordinate <= tolerance && delta.confidence <= tolerance
                && check.liveAndCaptureMaskIntersectionOverUnion! >= 0.99 && check.visibilityPreserved == true
            if !check.passed { check.error = "Live/frozen adapters disagree on the same RGB" }
        } catch { check.error = String(describing: error) }
        return check
    }

    /// An independent integer-raster reference; do not reuse the production mask
    /// transform here or a bug in it would also change this test's expectation.
    private static func uprightMask(_ mask: GarmentMask, orientation: ImageOrientation) throws -> GarmentMask {
        let width = mask.size.width, height = mask.size.height
        guard mask.size.isValid, mask.values.count == width * height else {
            throw ValidationError.invalid("Invalid raw foreground mask raster")
        }
        let size: PixelSize
        switch orientation {
        case .up, .down: size = mask.size
        case .right, .left: size = .init(width: height, height: width)
        }
        var values = [UInt8](repeating: 0, count: size.width * size.height)
        for y in 0..<height {
            for x in 0..<width {
                let dx: Int, dy: Int
                switch orientation {
                case .up: dx = x; dy = y
                case .right: dx = height - 1 - y; dy = x
                case .down: dx = width - 1 - x; dy = height - 1 - y
                case .left: dx = y; dy = width - 1 - x
                }
                values[dy * size.width + dx] = mask.values[y * width + x]
            }
        }
        return .init(size: size, values: values)
    }

    private static func maskIntersectionOverUnion(_ first: GarmentMask, _ second: GarmentMask) throws -> Double {
        guard first.size == second.size, first.values.count == second.values.count else {
            throw ValidationError.invalid("Raw mask did not rotate back to the baseline upright raster size")
        }
        var intersection = 0, union = 0
        for index in first.values.indices {
            let a = first.values[index] != 0, b = second.values[index] != 0
            if a && b { intersection += 1 }
            if a || b { union += 1 }
        }
        guard union > 0 else { throw ValidationError.invalid("Foreground-mask comparison has no foreground") }
        return Double(intersection) / Double(union)
    }

    private static func orientationChecks(_ data: Data, path: String,
                                          provider: CoreMLGarmentLandmarkProvider) async throws -> OrientationChecks {
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let photo = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw ValidationError.invalid("Could not create upright RGB reference")
        }
        let zeroOrigin = photo.transformed(by: .init(translationX: -photo.extent.minX, y: -photo.extent.minY))
        let fixture: CIImage
        let fixtureDescription: String
        if zeroOrigin.extent.width == zeroOrigin.extent.height {
            // These supplied example photos are square thumbnails. Neutral
            // padding keeps their garment pixels unchanged while exercising
            // width/height swaps, aspect-fit padding and raw coordinate mapping.
            let extent = CGRect(x: 0, y: 0, width: zeroOrigin.extent.width + 64, height: zeroOrigin.extent.height + 160)
            let background = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255)).cropped(to: extent)
            fixture = zeroOrigin.transformed(by: .init(translationX: 32, y: 80)).composited(over: background).cropped(to: extent)
            fixtureDescription = "Real upright photo without rescaling, with 32px horizontal and 80px vertical neutral borders to make a non-square rotation fixture."
        } else {
            fixture = zeroOrigin
            fixtureDescription = "Original non-square upright photo, with no crop or rescaling."
        }
        guard let upright = context.createCGImage(fixture, from: fixture.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw ValidationError.invalid("Could not render upright RGB reference")
        }
        let baseline = try await provider.recognizeImage(upright, orientation: .up)
        try validatePoints(baseline.points, provider: provider)
        var checks: [RotationCheck] = []
        var baselineMask: GarmentMask?
        let maskThreshold = 0.99
        for orientation in [ImageOrientation.up, .right, .down, .left] {
            let inverse: Int32
            switch orientation { case .up: inverse = 1; case .right: inverse = 8; case .down: inverse = 3; case .left: inverse = 6 }
            var check = RotationCheck(orientation: orientation, inverseRawPixelRotationEXIF: inverse)
            do {
                let rotated = CIImage(cgImage: upright).oriented(forExifOrientation: inverse)
                guard let raw = context.createCGImage(rotated, from: rotated.extent, format: .RGBA8, colorSpace: colorSpace) else {
                    throw ValidationError.invalid("Could not rotate raw RGB pixels")
                }
                check.rawImageSize = .init(width: raw.width, height: raw.height)
                let result = try await provider.recognizeImage(raw, orientation: orientation)
                try validatePoints(result.points, provider: provider)
                let delta = try compare(result.points, to: baseline.points, orientation: orientation)
                check.maximumCoordinateDelta = delta.coordinate
                check.maximumConfidenceDelta = delta.confidence
                check.passed = delta.coordinate <= tolerance && delta.confidence <= tolerance && result.modelVersion == baseline.modelVersion
                if !check.passed { check.error = "Inverse raw rotation plus frame orientation did not reproduce the same upright landmarks" }
                var snapshot = await snapshotCheck(raw, orientation: orientation, provider: provider)
                do {
                    guard let mask = snapshot.mask else { throw ValidationError.invalid("Snapshot did not return an associated mask") }
                    let upright = try uprightMask(mask, orientation: orientation)
                    if orientation == .up { baselineMask = upright }
                    guard let baselineMask else { throw ValidationError.invalid("Upright baseline mask unavailable") }
                    let iou = try maskIntersectionOverUnion(upright, baselineMask)
                    snapshot.check.uprightMaskSize = upright.size
                    snapshot.check.maskIntersectionOverUnionVsUpright = iou
                    snapshot.check.maskComparisonPassed = iou >= maskThreshold
                    if iou < maskThreshold { snapshot.check.maskComparisonError = "The same upright garment pixels produced different foreground masks after raw rotation" }
                } catch {
                    snapshot.check.maskComparisonPassed = false
                    snapshot.check.maskComparisonError = String(describing: error)
                }
                check.snapshot = snapshot.check
            } catch { check.error = String(describing: error) }
            checks.append(check)
        }
        return .init(path: path, fixtureDescription: fixtureDescription,
                     uprightImageSize: .init(width: upright.width, height: upright.height),
                     coordinateTolerance: tolerance, confidenceTolerance: tolerance,
                     minimumMaskIntersectionOverUnion: maskThreshold,
                     baselinePointCount: baseline.points.count, checks: checks)
    }

    private static func negativeCheck(_ data: Data, source: String, empty: Bool,
                                      provider: CoreMLGarmentLandmarkProvider) async -> NegativeCheck {
        var check = NegativeCheck(source: source, purpose: empty ? "Empty image must not yield a garment" : "Observe wrong selected model; pose scores are not category probabilities")
        do {
            let result = try await provider.recognizePhoto(data)
            check.accepted = true
            check.detectionConfidence = result.detectionConfidence
            check.pointCount = result.points.count
            check.modelVersion = result.modelVersion
            if empty { check.expectedEmptyRejectionPassed = false }
        } catch {
            check.accepted = false
            check.error = String(describing: error)
            if empty {
                if case GarmentModelError.noDetection = error { check.expectedEmptyRejectionPassed = true }
                else { check.expectedEmptyRejectionPassed = false }
            }
        }
        if empty {
            check.captureInputDepthIsEmpty = true
            check.didComputeCentimetres = false
            do {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ValidationError.invalid("Could not decode empty capture fixture")
                }
                let size = PixelSize(width: image.width, height: image.height)
                let sessionID = UUID(), frameID = UUID()
                let frame = MeasurementFrame(sessionID: sessionID, frameID: frameID, timestamp: 0, capturedAt: Date(),
                    imageSize: size, intrinsics: .init(fx: 1, fy: 1, cx: 0, cy: 0, referenceSize: size),
                    depth: .init(size: .init(width: 0, height: 0), values: [], confidence: nil),
                    source: .synthetic, orientation: .up)
                let output = try await provider.landmarks(for: .init(frame: frame, imageJPEG: data))
                check.captureAdapterAccepted = true
                check.captureFrameIdentityPreserved = output.sessionID == sessionID && output.frameID == frameID
            } catch {
                check.captureAdapterAccepted = false
                check.captureAdapterError = String(describing: error)
            }
        }
        return check
    }

    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let provider = try CoreMLGarmentLandmarkProvider(kind: options.kind, modelURL: options.model,
                schemaData: Data(contentsOf: options.schema))
            var photos: [PhotoCheck] = []
            var foregroundPhotos: [PhotoForegroundCheck] = []
            var reference: (data: Data, check: PhotoCheck)?
            for url in options.photos {
                let check: PhotoCheck
                do {
                    let data = try Data(contentsOf: url)
                    check = await photoCheck(data, path: url.path, provider: provider)
                    foregroundPhotos.append(await photoForegroundCheck(data, path: url.path, provider: provider))
                    if reference == nil && check.passed { reference = (data, check) }
                } catch { check = .init(path: url.path, error: String(describing: error)) }
                photos.append(check)
            }
            var repeated: RepeatCheck?
            var orientations: OrientationChecks?
            var orientationError: String?
            if let reference {
                var check = RepeatCheck(path: reference.check.path)
                do {
                    let result = try await provider.recognizePhoto(reference.data)
                    try validatePoints(result.points, provider: provider)
                    let delta = try compare(result.points, to: reference.check.points!)
                    check.maximumCoordinateDelta = delta.coordinate
                    check.maximumConfidenceDelta = delta.confidence
                    check.repeatedElapsedSeconds = result.durationSeconds
                    check.passed = delta.coordinate <= tolerance && delta.confidence <= tolerance
                        && result.modelVersion == reference.check.modelVersion && result.imageSize == reference.check.imageSize
                } catch { check.error = String(describing: error) }
                repeated = check
                do { orientations = try await orientationChecks(reference.data, path: reference.check.path, provider: provider) }
                catch { orientationError = String(describing: error) }
            } else { orientationError = "No positive photo succeeded" }
            var empty: [NegativeCheck] = []
            let context = CIContext(options: [.cacheIntermediates: false])
            for gray in [0.0, 114.0 / 255, 1.0] {
                let image = CIImage(color: CIColor(red: gray, green: gray, blue: gray))
                    .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
                guard let cg = context.createCGImage(image, from: image.extent) else { throw ValidationError.invalid("Could not render empty image") }
                empty.append(await negativeCheck(try losslessPNG(cg), source: "synthetic:800x600:uniformGray=\(gray)", empty: true, provider: provider))
            }
            var wrongKind: [NegativeCheck] = []
            for url in options.wrongKindPhotos {
                do { wrongKind.append(await negativeCheck(try Data(contentsOf: url), source: url.path, empty: false, provider: provider)) }
                catch { wrongKind.append(.init(source: url.path, purpose: "Wrong selected model observation", error: String(describing: error))) }
            }
            let passed = photos.allSatisfy(\.passed) && repeated?.passed == true
                && orientations?.checks.count == 4 && orientations?.checks.allSatisfy(\.passed) == true
                && empty.allSatisfy { $0.expectedEmptyRejectionPassed == true }
            let foregroundPassed = orientations?.checks.count == 4
                && orientations?.checks.allSatisfy { $0.snapshot?.passed == true && $0.snapshot?.maskComparisonPassed == true } == true
                && foregroundPhotos.count == options.photos.count && foregroundPhotos.allSatisfy(\.passed)
            let report = ValidationReport(kind: options.kind.rawValue, modelPath: options.model.path,
                schemaPath: options.schema.path, modelVersion: provider.modelVersion,
                schemaDirectPointCount: provider.keypoints.count, schemaDerivedPointIDs: provider.schema.derivedOrder,
                measurementDefinitions: provider.measurementDefinitions,
                platform: ProcessInfo.processInfo.operatingSystemVersionString, recordedAt: Date(),
                requiredChecksPassed: passed, foregroundChecksPassed: foregroundPassed,
                photos: photos, photoForegroundChecks: foregroundPhotos, repeatCheck: repeated, orientationChecks: orientations,
                orientationError: orientationError, emptyImages: empty, wrongKindImages: wrongKind,
                limitations: [
                    "Photos have no independently verified landmark labels; this is an inference integration check, not accuracy evaluation.",
                    "No ground-truth lengths, real depth, distance engine, or centimetre calculation are used.",
                    "Rotation checks physically inverse-rotate the same raw RGB, restore its frame orientation, and compare upright predictions.",
                    "Snapshot/foreground-mask checks are separately reported; requiredChecksPassed refers to photo inference, repeat/rotation consistency, and empty-image rejection.",
                    "Pose-model confidence does not establish category correctness or landmark/measurement accuracy; wrong-kind photos only characterize this risk.",
                    "Empty-photo inference and the frozen capture adapter (which additionally requires a matched foreground mask) are reported separately; no depth is supplied to either.",
                    "Timing and Vision results come from this Mac, not the test iPhone; the first photo includes model compilation/loading."
                ])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(report)
            if let url = options.report { try json.write(to: url, options: .atomic) }
            print(String(decoding: json, as: UTF8.self))
            if !passed { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("Garment provider validation failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

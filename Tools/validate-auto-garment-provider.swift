// Same-RGB validation of the supplied classifier, selected pose and capture adapter.
// xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
//   Dobby/Dobby/LiDAR/Core/*.swift \
//   Dobby/Dobby/LiDAR/Capture/CoreMLBottomLandmarkProvider.swift \
//   Dobby/Dobby/LiDAR/Capture/CoreMLGarmentLandmarkProvider.swift \
//   Dobby/Dobby/LiDAR/Capture/GarmentForegroundMaskAnalyzer.swift \
//   Dobby/Dobby/LiDAR/Capture/AutoGarmentLandmarkProvider.swift \
//   Tools/validate-auto-garment-provider.swift -o /tmp/validate-auto-garment-provider
// /tmp/validate-auto-garment-provider <models-directory> <manifest.json> <report.json>
// Manifest: [{"path":"/absolute/photo.jpg","expectedKind":"top"|"bottoms"|null,
//             "orientation":"up"|"right"|"down"|"left"}]
// Photos are normalized upright first, then rotated into the requested raw-frame
// orientation. null expectedKind means the garment must not publish measurements.
// No real depth, centimetres, or generalization claim is produced by this tool.

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct Fixture: Codable {
    var path: String
    var expectedKind: AutomaticGarmentKind?
    var orientation: ImageOrientation?
}

private struct Check: Codable {
    var source: String
    var expectedKind: AutomaticGarmentKind?
    var orientation: ImageOrientation = .up
    var decision: GarmentKindSelection?
    var top: GarmentKindEvidence?
    var bottoms: GarmentKindEvidence?
    var poseRequests: Int?
    var foregroundRequests: Int?
    var classificationAttempts: [AutoGarmentClassificationAttempt]?
    var elapsedSeconds: Double?
    var evaluationSeconds: Double?
    var selectedKind: AutomaticGarmentKind?
    var modelVersion: String?
    var liveAndFrozenIdentityPassed: Bool?
    var liveAndFrozenPointDelta: Double?
    var liveAndFrozenMaskIoU: Double?
    var definitionIDs: [String]?
    var invalidKindAndVersionRejected: Bool?
    var partialDefinitionsPreserved: Bool?
    var safelyRejected = false
    var passed = false
    var error: String?
}

private struct Report: Codable {
    var recordedAt: Date
    var platform = "macOS real-model RGB validation; no physical depth or centimetres"
    var preparationSeconds: Double
    var requiredSafetyChecksPassed: Bool
    var selectedPhotoCount: Int
    var incorrectKindCount: Int
    var photos: [Check]
    var blanks: [Check]
    var limitations: [String]
}

@main private struct AutoProviderValidation {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw ValidationError.invalid("Usage: <models-directory> <manifest.json> <report.json>")
        }
        let directory = URL(fileURLWithPath: arguments[1])
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let top = try CoreMLGarmentLandmarkProvider(kind: .top,
            modelURL: directory.appendingPathComponent("TopLandmarks.mlpackage"),
            schemaData: Data(contentsOf: directory.appendingPathComponent("schema_top.json")))
        let bottoms = try CoreMLGarmentLandmarkProvider(kind: .bottoms,
            modelURL: directory.appendingPathComponent("BottomLandmarks.mlpackage"),
            schemaData: Data(contentsOf: directory.appendingPathComponent("schema_bottom7.json")))
        let provider = try AutoGarmentLandmarkProvider(top: top, bottoms: bottoms,
            classifierModelURL: directory.appendingPathComponent("clothes_image_detection.mlpackage"))
        let preparation = ContinuousClock.now
        try await provider.prepare()
        let preparationSeconds = seconds(preparation.duration(to: .now))
        let context = CIContext(options: [.cacheIntermediates: false])
        var photos: [Check] = []
        for fixture in fixtures {
            let data = try Data(contentsOf: URL(fileURLWithPath: fixture.path))
            guard let input = CIImage(data: data, options: [.applyOrientationProperty: true]),
                  let upright = context.createCGImage(input, from: input.extent) else {
                throw ValidationError.invalid("Unreadable fixture: \(fixture.path)")
            }
            let orientation = fixture.orientation ?? .up
            let inverseEXIF: Int32
            switch orientation {
            case .up: inverseEXIF = 1
            case .right: inverseEXIF = 8
            case .down: inverseEXIF = 3
            case .left: inverseEXIF = 6
            }
            let raw = CIImage(cgImage: upright).oriented(forExifOrientation: inverseEXIF)
            guard let image = context.createCGImage(raw, from: raw.extent) else {
                throw ValidationError.invalid("Raw orientation conversion failed")
            }
            let check = await check(image, source: fixture.path, expected: fixture.expectedKind,
                                    orientation: orientation, provider: provider)
            photos.append(check)
            print("\(URL(fileURLWithPath: fixture.path).lastPathComponent): \(String(describing: check.decision)) \(check.error ?? "")")
        }
        var blanks: [Check] = []
        for brightness in [0.0, 114.0 / 255, 1.0] {
            let input = CIImage(color: CIColor(red: brightness, green: brightness, blue: brightness))
                .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
            guard let image = context.createCGImage(input, from: input.extent) else {
                throw ValidationError.invalid("Blank fixture creation failed")
            }
            blanks.append(await check(image, source: "synthetic:800x600:gray=\(brightness)",
                                      expected: nil, provider: provider))
        }
        let incorrect = photos.filter { $0.selectedKind != nil && $0.selectedKind != $0.expectedKind }.count
        let report = Report(recordedAt: .now, preparationSeconds: preparationSeconds,
            requiredSafetyChecksPassed: incorrect == 0 && photos.allSatisfy(\.passed) && blanks.allSatisfy(\.passed),
            selectedPhotoCount: photos.filter { $0.selectedKind != nil }.count,
            incorrectKindCount: incorrect, photos: photos, blanks: blanks,
            limitations: ["Local supplied photos can overlap training data; this does not establish generalization accuracy.",
                "Conservative association or kind ambiguity rejects some genuine garments instead of assigning an unsupported model.",
                "Timing is measured on this Mac, not the iPhone camera pipeline.",
                "Snapshot depth is deliberately empty; no physical centimetres were calculated."])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
        if !report.requiredSafetyChecksPassed { throw ValidationError.invalid("Automatic adapter safety checks failed; inspect report") }
    }

    private static func check(_ image: CGImage, source: String, expected: AutomaticGarmentKind?,
                              orientation: ImageOrientation = .up,
                              provider: AutoGarmentLandmarkProvider) async -> Check {
        var check = Check(source: source, expectedKind: expected, orientation: orientation)
        let started = ContinuousClock.now
        do {
            let evaluation = try await provider.evaluateImage(image, orientation: orientation)
            check.evaluationSeconds = seconds(started.duration(to: .now))
            check.decision = evaluation.decision; check.top = evaluation.top; check.bottoms = evaluation.bottoms
            check.poseRequests = evaluation.poseRequests; check.foregroundRequests = evaluation.foregroundRequests
            check.classificationAttempts = evaluation.classificationAttempts
            switch evaluation.decision {
            case .selected(let kind):
                check.selectedKind = kind
                guard expected == kind else { throw ValidationError.invalid("Selected an incorrect garment kind") }
                let live = try await provider.recognizeForeground(image, orientation: orientation)
                let size = PixelSize(width: image.width, height: image.height)
                let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1, capturedAt: .now,
                    imageSize: size, intrinsics: .init(fx: 1, fy: 1, cx: 0, cy: 0, referenceSize: size),
                    depth: .init(size: .init(width: 0, height: 0), values: []), source: .synthetic, orientation: orientation)
                let snapshot = CaptureSnapshot(frame: frame, imageJPEG: try png(image))
                let frozen = try await provider.landmarks(for: snapshot)
                check.modelVersion = frozen.modelVersion
                check.liveAndFrozenIdentityPassed = frozen.frameID == frame.frameID && frozen.sessionID == frame.sessionID
                    && frozen.garmentKind == kind && live.recognition.garmentKind == kind
                    && frozen.modelVersion == kind.modelVersion && live.recognition.modelVersion == kind.modelVersion
                check.liveAndFrozenPointDelta = try pointDelta(live.recognition.points, frozen.points)
                check.liveAndFrozenMaskIoU = try maskIoU(live.selection.mask, frozen.mask)
                check.definitionIDs = try provider.measurementDefinitions(for: frozen).map(\.id)
                var wrongKind = frozen; wrongKind.garmentKind = kind == .top ? .bottoms : .top
                var wrongVersion = frozen; wrongVersion.modelVersion = "not-this-model"
                check.invalidKindAndVersionRejected = rejects(wrongKind, provider: provider) && rejects(wrongVersion, provider: provider)
                var partial = frozen
                if partial.points.count > 1 { partial.points.removeLast() }
                check.partialDefinitionsPreserved = (try? provider.measurementDefinitions(for: partial)) == nil ? false : true
                guard check.liveAndFrozenIdentityPassed == true,
                      check.liveAndFrozenPointDelta ?? 1 <= 2.0 / 640,
                      check.liveAndFrozenMaskIoU ?? 0 >= 0.98,
                      check.invalidKindAndVersionRejected == true, check.partialDefinitionsPreserved == true else {
                    throw ValidationError.invalid("Same-RGB capture, provenance, or partial-definition contract failed")
                }
                check.passed = true
            case .ambiguous, .noDetection:
                do {
                    _ = try await provider.recognizeForeground(image, orientation: orientation)
                    throw ValidationError.invalid("Unsupported kind still published recognition")
                } catch let error as AutoGarmentRecognitionError where error.isRecognitionRejection {
                    check.safelyRejected = true
                    check.error = String(describing: error)
                }
                check.passed = check.safelyRejected
            }
        } catch {
            check.error = String(describing: error)
            if case GarmentModelError.multipleGarments = error { check.safelyRejected = true }
            if case GarmentMaskAssociationError.multipleForegrounds = error { check.safelyRejected = true }
            check.passed = check.safelyRejected
        }
        check.elapsedSeconds = seconds(started.duration(to: .now))
        return check
    }

    private static func rejects(_ landmarks: GarmentLandmarkSet, provider: AutoGarmentLandmarkProvider) -> Bool {
        do { _ = try provider.measurementDefinitions(for: landmarks); return false }
        catch AutoGarmentRecognitionError.invalidProvenance { return true }
        catch { return false }
    }

    private static func pointDelta(_ first: [GarmentLandmark], _ second: [GarmentLandmark]) throws -> Double {
        guard Set(first.map(\.id)) == Set(second.map(\.id)), first.count == second.count else {
            throw ValidationError.invalid("Live and frozen point identities differ")
        }
        let reference = Dictionary(uniqueKeysWithValues: second.map { ($0.id, $0) })
        var maximum = 0.0
        for point in first {
            guard let other = reference[point.id], point.isVisible == other.isVisible else {
                throw ValidationError.invalid("Live and frozen point visibility differs")
            }
            maximum = max(maximum, abs(point.point.x - other.point.x), abs(point.point.y - other.point.y))
        }
        return maximum
    }

    private static func maskIoU(_ first: GarmentMask, _ second: GarmentMask?) throws -> Double {
        guard let second, first.size == second.size, first.values.count == second.values.count else {
            throw ValidationError.invalid("Live and frozen mask dimensions differ")
        }
        var intersection = 0, union = 0
        for (a, b) in zip(first.values, second.values) {
            if a != 0 && b != 0 { intersection += 1 }
            if a != 0 || b != 0 { union += 1 }
        }
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private static func png(_ image: CGImage) throws -> Data {
        guard let data = CFDataCreateMutable(kCFAllocatorDefault, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ValidationError.invalid("Cannot encode snapshot fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ValidationError.invalid("Snapshot encoding failed") }
        return data as Data
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private enum ValidationError: Error { case invalid(String) }
}

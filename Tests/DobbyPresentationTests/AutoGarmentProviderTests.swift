import CoreImage
import CoreVideo
import XCTest
@testable import Dobby

/// Executes the app's bundled models in the iOS runtime. Neutral pixels check
/// resource and rejection contracts; they do not establish garment accuracy.
@MainActor
final class AutoGarmentProviderTests: XCTestCase {
    private func neutralImage() throws -> CGImage {
        let neutral = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        return try XCTUnwrap(CIContext().createCGImage(neutral, from: neutral.extent))
    }

    private func recordCheckpoint(_ message: String) {
        print("AutoGarmentProvider runtime checkpoint: \(message)")
        let attachment = XCTAttachment(string: message)
        attachment.name = message
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBundledClassifierRejectsNeutralImageWithoutRunningPose() async throws {
        _ = try XCTUnwrap(Bundle.main.url(forResource: "clothes_image_detection", withExtension: "mlmodelc"),
            "The app must contain the compiled fifteen-category classifier")
        let provider = try AutoGarmentLandmarkProvider.bundled()

        let image = try neutralImage()
        // Probe the classifier before prepare(), which separately warms pose
        // and Vision foreground models. Blank rejection must need neither.
        let evaluation: AutoGarmentRecognitionEvaluation
        do {
            evaluation = try await provider.evaluateImage(image, orientation: .up)
        } catch let error as GarmentOrientationResolutionError {
            // A blank raster may produce contradictory rotations. It must stop
            // before category/pose rather than pretend that correction worked.
            XCTAssertTrue((1...3).contains(error.attempts.count))
            XCTAssertTrue(error.attempts.allSatisfy { $0.prediction.correction != .upright })
            XCTAssertEqual(error.automaticMeasurementFailureCause, .garmentOrientationUnverified)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let diagnostic = try encoder.encode(evaluation.classificationAttempts)
        let attachment = XCTAttachment(data: diagnostic, uniformTypeIdentifier: "public.json")
        attachment.name = "Neutral image classifier attempts"
        attachment.lifetime = .keepAlways
        add(attachment)

        let orientation = try XCTUnwrap(evaluation.orientationPrediction)
        let resolution = try XCTUnwrap(evaluation.orientationResolution)
        XCTAssertEqual(evaluation.classificationAttempts.map(\.orientation), [resolution.orientation],
            "Classification runs only at the verified final orientation")
        XCTAssertEqual(resolution.attempts.first?.prediction, orientation)
        XCTAssertEqual(resolution.attempts.first?.orientation, .up)
        XCTAssertEqual(resolution.attempts.last?.prediction.correction, .upright)
        XCTAssertTrue((1...3).contains(resolution.attempts.count))
        XCTAssertEqual(Set(orientation.probabilities.keys), Set([0, 90, 180, 270]))
        let expectedLabels = Set(GarmentClassificationCategory.allCases.map(\.rawValue))
        XCTAssertEqual(expectedLabels.count, 15)
        for attempt in evaluation.classificationAttempts {
            XCTAssertEqual(attempt.scores.count, 15)
            XCTAssertEqual(Set(attempt.scores.map(\.label)), expectedLabels)
            XCTAssertTrue(attempt.scores.allSatisfy { $0.confidence.isFinite && (0...1).contains($0.confidence) })
        }
        XCTAssertEqual(evaluation.decision, .noDetection)
        XCTAssertNil(evaluation.recognition, "A full neutral image must never become a garment silhouette")
        XCTAssertEqual(evaluation.poseRequests, 0, "Classifier rejection must avoid running either pose model")
        XCTAssertEqual(evaluation.foregroundRequests, 0, "A rejected frame must not enter garment foreground association")
    }

    func testBundledOrientationModelAndExactRGB224InputInIOSRuntime() throws {
        let url = try GarmentOrientationModelProvider.resourceURL(in: .main)
        XCTAssertEqual(url.pathExtension, "mlmodelc")
        let worker = GarmentOrientationModelProvider(modelURL: url)
        let image = try neutralImage()
        let prediction = try worker.classify(image, deviceOrientation: .right)
        XCTAssertEqual(Set(prediction.probabilities.keys), Set([0, 90, 180, 270]))
        XCTAssertEqual(prediction.probabilities.values.reduce(0, +), 1, accuracy: 0.02)
    }

    func testOrientationPreprocessorKeepsExactRGBBytesAndOddPadding() throws {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 3))
        let image = try XCTUnwrap(CIContext().createCGImage(black, from: black.extent))
        let buffer = try GarmentOrientationModelProvider.pixelBuffer(image)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in [0, 105, 106, 116, 117, 223] {
            let expected: UInt8 = (106..<117).contains(y) ? 0 : 114
            for channel in 0..<3 { XCTAssertEqual(bytes[y * stride + 112 * 4 + channel], expected) }
        }
    }

    func testBundledPoseModelsPrepareInIOSRuntime() async throws {
        let top = try CoreMLGarmentLandmarkProvider.bundled(kind: .top)
        let bottoms = try CoreMLGarmentLandmarkProvider.bundled(kind: .bottoms)
        for (name, provider) in [("top", top), ("bottoms", bottoms)] {
            recordCheckpoint("\(name) pose preparation started")
            do {
                try await provider.preparePoseModel()
                recordCheckpoint("\(name) pose preparation completed")
            } catch {
                recordCheckpoint("\(name) pose preparation failed: \(String(reflecting: error as NSError))")
                throw error
            }
        }
    }

}

import CoreImage
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
        let evaluation = try await provider.evaluateImage(image, orientation: .up)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let diagnostic = try encoder.encode(evaluation.classificationAttempts)
        let attachment = XCTAttachment(data: diagnostic, uniformTypeIdentifier: "public.json")
        attachment.name = "Neutral image classifier attempts"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(evaluation.classificationAttempts.map(\.orientation), [.up, .down],
            "Rejected frames must be evaluated in both original and half-turn orientations")
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

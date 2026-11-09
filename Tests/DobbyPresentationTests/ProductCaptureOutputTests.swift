// Created by mason on 11/8/26.
import Foundation
import Testing
@testable import Dobby

@MainActor
struct ProductCaptureOutputTests {
    @Test func allPhotosKeepCaptureOrderRegardlessOfSelectionAndLimit() async throws {
        let model = try makeModel(visualization: true)
        for _ in 0..<11 { try await model.captureDetail() }
        model.toggleSelection(model.detailPhotos.last!.id)
        let output = try #require(model.allPhotosOutput)
        #expect(output.selectedPhotos.map(\.id) == model.input.measurementPhotos.map(\.id)
            + model.detailPhotos.map(\.id))
        #expect(output.selectedPhotos.count == 13)
        #expect(output.representativePhotoID == model.input.measurement.id)
        #expect(output.detailPhotos == model.detailPhotos)
        #expect(output.sessionID == model.input.sessionID && output.garmentID == model.input.garmentID)
        #expect(model.selectedPhotoIDs == [model.detailPhotos.last!.id])
    }

    @Test func originalOnlyCanBeForwardedWithoutSelection() throws {
        let model = try makeModel(visualization: false)
        #expect(model.output == nil)
        #expect(model.allPhotosOutput?.selectedPhotos == [model.input.measurement])
    }

    @Test func inFlightCaptureCannotPublishPartialOutput() async throws {
        let provider = SuspendedCapture()
        let model = try makeModel(visualization: false, provider: provider)
        let task = Task { try await model.captureDetail() }
        await provider.waitUntilStarted()
        #expect(model.allPhotosOutput == nil)
        task.cancel()
        provider.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(model.allPhotosOutput?.selectedPhotos.count == 1)
    }

    private func makeModel(visualization: Bool, provider: (any CaptureProviding)? = nil) throws -> ProductPhotoModel {
        let session = UUID(), garment = UUID()
        func asset(_ purpose: CapturedAsset.Purpose) -> CapturedAsset {
            CapturedAsset(id: UUID(), sessionID: session, garmentID: garment, purpose: purpose,
                capturedAt: .now, source: .localFile(URL(fileURLWithPath: "/tmp/\(UUID()).jpg"),
                    metadata: .init(pixelWidth: 32, pixelHeight: 24, contentType: "public.jpeg", orientation: .up)))
        }
        let input = ProductPhotoInput(sessionID: session, garmentID: garment,
            measurement: asset(.measurement),
            measurementVisualization: visualization ? asset(.measurementVisualization) : nil)
        return try ProductPhotoModel(input: input, captureProvider: provider ?? MockCameraService(purpose: .detail))
    }

    private final class SuspendedCapture: CaptureProviding {
        private var pending: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
            await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
            return CapturedAsset(id: UUID(), sessionID: sessionID, garmentID: garmentID,
                purpose: .detail, capturedAt: .now, source: .mockPlaceholder)
        }
        func waitUntilStarted() async {
            if pending == nil { await withCheckedContinuation { started = $0 } }
        }
        func finish() { pending?.resume(); pending = nil }
    }
}

import Foundation
import Testing
@testable import Dobby

@MainActor
struct MeasurementPhotoReceiptTests {
    @Test func legacyVisualizationReceiptDecodesWithoutRenderVersion() throws {
        let photo = asset(.measurementVisualization)
        let receipt = try legacyReceipt(for: photo)

        #expect(receipt.visualizationRenderVersion == nil)
        #expect(receipt.matches(photo, visualizationRenderVersion: nil))
        #expect(!receipt.matches(photo, visualizationRenderVersion: 2))
    }

    @Test func visualizationReceiptOnlySkipsTheSavedRenderVersion() {
        let photo = asset(.measurementVisualization)
        let receipt = receipt(for: photo, renderVersion: 2)

        #expect(receipt.matches(photo, visualizationRenderVersion: 2))
        #expect(!receipt.matches(photo, visualizationRenderVersion: 3))
        #expect(!receipt.matches(photo, visualizationRenderVersion: nil))
    }

    @Test func retakingMeasurementDoesNotReuseThePreviousSessionReceipt() {
        for purpose in [CapturedAsset.Purpose.measurement, .measurementVisualization] {
            let photo = asset(purpose)
            let receipt = receipt(for: photo, renderVersion: 2)
            let retaken = asset(purpose, id: photo.id)

            #expect(retaken.sessionID != photo.sessionID)
            #expect(!receipt.matches(retaken, visualizationRenderVersion: 2))
        }
    }

    @Test func anotherCaptureCannotReuseAReceiptFromTheSameSession() {
        for purpose in [CapturedAsset.Purpose.measurement, .measurementVisualization, .detail] {
            let photo = asset(purpose)
            let receipt = receipt(for: photo, renderVersion: 2)
            let other = asset(purpose, sessionID: photo.sessionID)

            #expect(other.id != photo.id)
            #expect(!receipt.matches(other, visualizationRenderVersion: 2))
        }
    }

    @Test func legacyReceiptWithoutSessionOnlySkipsAnImmutableDetailPhoto() throws {
        let detail = asset(.detail)
        let receipt = try legacyReceipt(for: detail, includesSession: false)

        #expect(receipt.captureSessionID == nil)
        #expect(receipt.matches(detail, visualizationRenderVersion: 2))
        for purpose in [CapturedAsset.Purpose.measurement, .measurementVisualization] {
            let measurement = asset(purpose, id: detail.id, sessionID: detail.sessionID)
            #expect(!receipt.matches(measurement, visualizationRenderVersion: nil))
            #expect(!receipt.matches(measurement, visualizationRenderVersion: 2))
        }
    }

    @Test func originalAndDetailReceiptsSurviveVisualizationStyleChanges() throws {
        for purpose in [CapturedAsset.Purpose.measurement, .detail] {
            let photo = asset(purpose)
            let legacy = try legacyReceipt(for: photo)
            let versioned = receipt(for: photo, renderVersion: 2)

            for renderVersion in [nil, 2, 3] as [Int?] {
                #expect(legacy.matches(photo, visualizationRenderVersion: renderVersion))
                #expect(versioned.matches(photo, visualizationRenderVersion: renderVersion))
            }
        }
    }

    private func asset(_ purpose: CapturedAsset.Purpose,
                       id: UUID = UUID(), sessionID: UUID = UUID()) -> CapturedAsset {
        CapturedAsset(id: id, sessionID: sessionID, garmentID: UUID(), purpose: purpose,
            capturedAt: Date(timeIntervalSinceReferenceDate: 0), source: .mockPlaceholder)
    }

    private func receipt(for photo: CapturedAsset, renderVersion: Int?) -> DetailPhotoLibraryReceipt {
        DetailPhotoLibraryReceipt(schemaVersion: 1, captureID: photo.id, captureSessionID: photo.sessionID,
            photoLibraryIdentifier: nil, savedAt: Date(timeIntervalSinceReferenceDate: 0),
            visualizationRenderVersion: renderVersion)
    }

    private func legacyReceipt(for photo: CapturedAsset,
                               includesSession: Bool = true) throws -> DetailPhotoLibraryReceipt {
        // Older receipts did not encode a visualization render version. The
        // earliest detail-only receipts also omitted the capture session.
        var json: [String: Any] = ["schemaVersion": 1, "captureID": photo.id.uuidString, "savedAt": 0]
        if includesSession { json["captureSessionID"] = photo.sessionID.uuidString }
        return try JSONDecoder().decode(DetailPhotoLibraryReceipt.self,
            from: JSONSerialization.data(withJSONObject: json))
    }
}

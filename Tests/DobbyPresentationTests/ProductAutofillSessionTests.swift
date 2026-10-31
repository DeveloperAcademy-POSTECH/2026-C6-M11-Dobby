import Foundation
import Testing
@testable import Dobby

@MainActor
struct ProductAutofillSessionTests {
    @Test func anInFlightRequestCannotStartASecondGeneration() async throws {
        let generator = ControlledAutofillGenerator()
        let session = ProductAutofillSession(generator: generator)
        let photos = makePhotos(count: 1)
        let request = Task { try await session.generate(photos: photos) }
        await generator.waitForRequests(1)
        #expect(session.isGenerating)

        do {
            _ = try await session.generate(photos: photos)
            Issue.record("A duplicate generation should not reach the provider")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await generator.requestCount == 1)
        await generator.complete(0, with: draft())
        #expect(try await request.value == draft())
        #expect(!session.isGenerating)
    }

    @Test func aCancelledLateResultCannotFinishANewerRequest() async throws {
        // This provider deliberately ignores task cancellation until explicitly released.
        let generator = ControlledAutofillGenerator()
        let session = ProductAutofillSession(generator: generator)
        let first = Task { try await session.generate(photos: makePhotos(count: 1)) }
        await generator.waitForRequests(1)
        session.cancel()
        #expect(!session.isGenerating)

        let second = Task { try await session.generate(photos: makePhotos(count: 1)) }
        await generator.waitForRequests(2)
        await generator.complete(0, with: draft(name: "old result"))
        do {
            _ = try await first.value
            Issue.record("The cancelled request must not publish its late result")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(session.isGenerating, "Finishing the old request must not clear the newer request's loading state")
        await generator.complete(1, with: draft(name: "current result"))
        #expect(try await second.value.productName == "current result")
        #expect(!session.isGenerating)
    }

    @Test func taskCancellationAlsoRejectsAProviderThatIgnoresCancellation() async throws {
        let generator = ControlledAutofillGenerator()
        let session = ProductAutofillSession(generator: generator)
        let request = Task { try await session.generate(photos: makePhotos(count: 1)) }
        await generator.waitForRequests(1)
        request.cancel()
        await generator.complete(0, with: draft())
        do {
            _ = try await request.value
            Issue.record("A cancelled task must not return a usable draft")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!session.isGenerating)
    }

    @Test func onlyTheFirstFivePhotosAreSentInSelectionOrder() async throws {
        let generator = ControlledAutofillGenerator()
        let session = ProductAutofillSession(generator: generator)
        var selected = Array(makePhotos(count: 10).reversed())
        // A selected visualization is a normal upload candidate under the
        // existing first-five policy; it must not silently reorder details.
        let visualization = selected[1]
        selected[1] = CapturedAsset(id: visualization.id, sessionID: visualization.sessionID,
            garmentID: visualization.garmentID, purpose: .measurementVisualization,
            capturedAt: visualization.capturedAt, source: visualization.source)
        let request = Task { try await session.generate(photos: selected) }
        await generator.waitForRequests(1)
        #expect(await generator.photos(for: 0) == Array(selected.prefix(5)))
        #expect(selected.count == 10, "The upload limit must not remove registered product photos")
        await generator.complete(0, with: draft())
        _ = try await request.value
    }

    @Test func applyingADraftOnlyChangesTheThreeAIFieldsAndPreservesParagraphs() throws {
        let garment = makeGarment()
        let photo = try #require(garment.photos.first)
        let measurement = try #require(garment.measurements.first)
        let before = ProductAutofillInputSnapshot(garment: garment)
        let previousDate = garment.updatedAt
        let generated = draft(brand: nil)
        try before.apply(generated, to: garment)

        #expect(garment.name == generated.productName)
        #expect(garment.brand.isEmpty, "A null brand clears the field instead of displaying null or an old brand")
        #expect(garment.detail == "첫 번째 문단입니다.\n\n두 번째 문단입니다.")
        #expect(!garment.detail.contains("실물 확인"), "Review notes are separate from sale copy")
        #expect(garment.price == 48_000)
        #expect(garment.updatedAt == previousDate)
        #expect(garment.photos.count == 1)
        #expect(garment.photos.first === photo)
        #expect(photo.fileName == "retained.jpg")
        #expect(photo.role == .thumbnail)
        #expect(photo.order == 0)
        #expect(photo.isSelectedForProduct == true)
        #expect(garment.measurements.count == 1)
        #expect(garment.measurements.first === measurement)
        #expect(measurement.valueCm == 55.25)
        #expect(measurement.autoValueCm == 54.125)
        #expect(measurement.isEdited)

        before.restore(to: garment)
        #expect(before.matches(garment))
        #expect(garment.price == 48_000)
        #expect(measurement.valueCm == 55.25)
    }

    @Test func editsMadeDuringGenerationAreNeverOverwritten() throws {
        let garment = makeGarment()
        let before = ProductAutofillInputSnapshot(garment: garment)
        #expect(before.hasInformation)
        garment.detail = "사용자가 새로 작성한 설명"
        do {
            try before.apply(draft(), to: garment)
            Issue.record("A stale snapshot must reject application")
        } catch {
            #expect(error is ProductAutofillCompletionFailure)
        }
        #expect(garment.name == "기존 제품명")
        #expect(garment.brand == "기존 브랜드")
        #expect(garment.detail == "사용자가 새로 작성한 설명")
    }

    @Test func aSnapshotCannotApplyOrRestoreIntoAnotherProduct() throws {
        let first = makeGarment()
        let other = makeGarment()
        other.name = "다른 제품"
        let snapshot = ProductAutofillInputSnapshot(garment: first)
        #expect(!snapshot.matches(other))
        do {
            try snapshot.apply(draft(), to: other)
            Issue.record("A product identifier mismatch must reject application")
        } catch {
            #expect(error is ProductAutofillCompletionFailure)
        }
        snapshot.restore(to: other)
        #expect(other.name == "다른 제품")
    }

    @Test func whitespaceOnlyFieldsDoNotRequireReplacementConfirmation() {
        let garment = Garment(category: "Hoodie", group: .top, name: " \n", brand: "\t", detail: " ")
        #expect(!ProductAutofillInputSnapshot(garment: garment).hasInformation)
        garment.brand = "브랜드"
        #expect(ProductAutofillInputSnapshot(garment: garment).hasInformation)
    }

    @Test func versionOneDraftWithoutAIKeysStillDecodes() throws {
        let identifier = UUID(uuidString: "1E7192EB-CF27-4A32-A0F4-29339A6F36C1")!
        // This is the pre-AI format, with no optional AI keys added by a current encoder.
        let oldJSON = Data("""
        {"schemaVersion":1,"step":"photoSelection","measurementRecordID":"1E7192EB-CF27-4A32-A0F4-29339A6F36C1","savedAt":123}
        """.utf8)
        let restored = try JSONDecoder().decode(ProductCreationDraft.self, from: oldJSON)
        #expect(restored.schemaVersion == 1)
        #expect(restored.step == .photoSelection)
        #expect(restored.measurementRecordID == identifier)
        #expect(restored.savedAt == Date(timeIntervalSinceReferenceDate: 123))
        #expect(restored.aiReviewNotes == nil)
        #expect(restored.usesProductAutofill == nil)
    }

    @Test func savedDraftRoundTripPreservesReviewNotesAndDisabledToggle() throws {
        let original = ProductCreationDraft(step: .information, measurementRecordID: UUID(),
            photoState: nil, measurementInputData: Data([1, 2, 3]),
            savedAt: Date(timeIntervalSinceReferenceDate: 456),
            aiReviewNotes: ["브랜드 라벨 확인 필요", "소매의 얼룩은 그림자인지 실물 확인 필요"],
            usesProductAutofill: false)
        let restored = try JSONDecoder().decode(ProductCreationDraft.self,
            from: JSONEncoder().encode(original))
        #expect(restored.schemaVersion == original.schemaVersion)
        #expect(restored.step == original.step)
        #expect(restored.measurementRecordID == original.measurementRecordID)
        #expect(restored.measurementInputData == original.measurementInputData)
        #expect(restored.savedAt == original.savedAt)
        #expect(restored.aiReviewNotes == original.aiReviewNotes)
        #expect(restored.usesProductAutofill == false, "An explicit OFF choice must not turn into the default ON after reopening")
    }

    private func makePhotos(count: Int) -> [CapturedAsset] {
        let sessionID = UUID()
        let garmentID = UUID()
        return (0..<count).map { _ in
            CapturedAsset(id: UUID(), sessionID: sessionID, garmentID: garmentID,
                          purpose: .detail, capturedAt: .now, source: .mockPlaceholder)
        }
    }

    private func draft(name: String = "생성된 제품명", brand: String? = "생성된 브랜드") -> ProductAutofillDraft {
        ProductAutofillDraft(productName: name, brand: brand,
            description: "첫 번째 문단입니다.\n\n두 번째 문단입니다.", reviewNotes: ["실물 확인 필요"])
    }

    private func makeGarment() -> Garment {
        let garment = Garment(category: "Hoodie", group: .top,
            name: "기존 제품명", brand: "기존 브랜드", detail: "기존 설명", price: 48_000)
        let photo = GarmentPhoto(fileName: "retained.jpg", role: .thumbnail, order: 0)
        photo.isSelectedForProduct = true
        garment.photos = [photo]
        let measurement = MeasuredValue(key: "chestWidth", label: "가슴", displayOrder: 0,
            valueCm: 55.25, autoValueCm: 54.125)
        measurement.isEdited = true
        garment.measurements = [measurement]
        return garment
    }
}

/// A deterministic gate permits cancellation/race tests without a clock or paid AI requests.
private actor ControlledAutofillGenerator: ProductAutofillGenerating {
    private var requests: [[CapturedAsset]] = []
    private var pending: [Int: CheckedContinuation<ProductAutofillDraft, any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var requestCount: Int { requests.count }
    func photos(for index: Int) -> [CapturedAsset] { requests[index] }

    func generate(photos: [CapturedAsset]) async throws -> ProductAutofillDraft {
        let index = requests.count
        requests.append(photos)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with draft: ProductAutofillDraft) {
        pending.removeValue(forKey: index)?.resume(returning: draft)
    }
}

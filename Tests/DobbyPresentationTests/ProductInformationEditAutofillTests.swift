import SwiftData
import UIKit
import XCTest
@testable import Dobby

@MainActor
final class ProductInformationEditAutofillTests: XCTestCase {
    func testGeneratedInformationStaysInDraftAndDiscardRestoresMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let generator = HeldGenerator()
        let session = try fixture.session(generator)
        let task = Task { try await session.generateInformation() }
        let photos = await generator.request()
        XCTAssertEqual(photos.map(\.id), fixture.original.productPhotos.prefix(5).map(\.id))
        XCTAssertEqual(Set(photos.map(\.sessionID)).count, 1)
        await generator.finish(.success(Self.draft))
        try await task.value
        XCTAssertEqual(session.garment.name, Self.draft.productName)
        XCTAssertEqual(session.garment.price, 40_000)
        XCTAssertEqual(session.garment.measurements.first?.valueCm, 58)
        XCTAssertNotNil(session.garment.aiInformationGeneratedAt)
        XCTAssertTrue(session.hasChanges)
        let reopened = try fixture.session(HeldGenerator())
        XCTAssertEqual(reopened.garment.name, "원본")
        XCTAssertNil(reopened.garment.aiInformationGeneratedAt)
        session.discard()
        XCTAssertEqual(session.garment.name, "원본")
        XCTAssertNil(session.garment.aiInformationGeneratedAt)
        XCTAssertFalse(session.hasChanges)
    }

    func testCancelledLateResultCannotReplaceDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let generator = HeldGenerator()
        let session = try fixture.session(generator)
        let task = Task { try await session.generateInformation() }
        _ = await generator.request()
        session.cancelGeneration()
        await generator.finish(.success(Self.draft))
        do { try await task.value; XCTFail("Cancelled request applied its result") }
        catch is CancellationError { }
        XCTAssertEqual(session.garment.name, "원본")
        XCTAssertFalse(session.hasChanges)
    }

    func testFailureCanRetryAndDonePersistsGeneratedInformation() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let generator = HeldGenerator()
        let session = try fixture.session(generator)
        let failed = Task { try await session.generateInformation() }
        _ = await generator.request()
        await generator.finish(.failure(ProductAutofillError.serverUnavailable))
        do { try await failed.value; XCTFail("Expected failure") } catch { }
        XCTAssertFalse(session.hasChanges)
        let retry = Task { try await session.generateInformation() }
        _ = await generator.request()
        await generator.finish(.success(Self.draft))
        try await retry.value
        try session.context.save()
        session.reflectSavedChanges(in: fixture.original)
        XCTAssertEqual(fixture.original.name, Self.draft.productName)
        let reopened = try fixture.session(HeldGenerator())
        XCTAssertEqual(reopened.garment.brand, "CLIQUE")
        XCTAssertEqual(reopened.garment.price, 40_000)
        XCTAssertNotNil(reopened.garment.aiInformationGeneratedAt)
    }

    private static let draft = ProductAutofillDraft(productName: "CLIQUE 데님 셔츠", brand: "CLIQUE",
        description: "가슴 자수가 있는 데님 셔츠입니다.", reviewNotes: [])

    private struct Fixture {
        let container: ModelContainer
        let original: Garment
        let directory: URL
        init() throws {
            container = try ModelContainer(for: Garment.self, GarmentPhoto.self, LandmarkPoint.self,
                MeasuredValue.self, ExportRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            container.mainContext.autosaveEnabled = false
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            original = Garment(category: "셔츠", group: .top, name: "원본", brand: "기존 브랜드",
                detail: "기존 설명", price: 40_000)
            container.mainContext.insert(original)
            original.measurements.append(MeasuredValue(key: "chestWidth", label: "가슴",
                displayOrder: 0, valueCm: 58, autoValueCm: 58))
            let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
                UIColor.blue.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: 20, height: 20)).fill()
            }
            for index in 0..<6 {
                let file = "\(index).jpg"
                try image.jpegData(compressionQuality: 0.8)!.write(to: directory.appending(path: file))
                let photo = GarmentPhoto(fileName: file, role: index == 0 ? .thumbnail : .detail, order: index)
                photo.isSelectedForProduct = true
                original.photos.append(photo)
            }
            try container.mainContext.save()
        }
        func session(_ generator: HeldGenerator) throws -> ProductInformationEditSession {
            try ProductInformationEditSession(garmentID: original.id, container: container,
                generator: generator, photosDirectory: directory)
        }
        func removeFiles() { try? FileManager.default.removeItem(at: directory) }
    }
}

private actor HeldGenerator: ProductAutofillGenerating {
    private var pending: CheckedContinuation<ProductAutofillDraft, Error>?
    private var photos: [CapturedAsset]?
    private var observer: CheckedContinuation<[CapturedAsset], Never>?
    func generate(photos: [CapturedAsset]) async throws -> ProductAutofillDraft {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            if let observer { self.observer = nil; observer.resume(returning: photos) }
            else { self.photos = photos }
        }
    }
    func request() async -> [CapturedAsset] {
        if let photos { self.photos = nil; return photos }
        return await withCheckedContinuation { observer = $0 }
    }
    func finish(_ result: Result<ProductAutofillDraft, Error>) {
        let continuation = pending; pending = nil
        continuation?.resume(with: result)
    }
}

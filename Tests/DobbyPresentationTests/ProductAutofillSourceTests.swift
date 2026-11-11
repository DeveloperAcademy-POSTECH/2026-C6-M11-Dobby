import Foundation
import SwiftData
import Testing
@testable import Dobby

@MainActor
struct ProductAutofillSourceTests {
    private let source = ProductAutofillSource(title: "브랜드 제품 아카이브", url: "https://example.com/archive/product")

    @Test func legacyResponseAndSourceResponseRemainCompatible() throws {
        let old = Data("""
        {"productName":"후드","brand":null,"description":"제품 설명","reviewNotes":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(ProductAutofillDraft.self, from: old)
        #expect(decoded.sources.isEmpty && decoded.isValid)
        let current = ProductAutofillDraft(productName: "브랜드 후드", brand: "브랜드",
            description: "보이는 특징입니다.\n\n확인된 출시 배경입니다.", reviewNotes: [], sources: [source])
        #expect(try JSONDecoder().decode(ProductAutofillDraft.self, from: JSONEncoder().encode(current)) == current)
        #expect(current.isValid)
    }

    @Test func onlyPublicHTTPSReferencesAreUsable() {
        for value in ["http://example.com", "file:///tmp/photo", "javascript:alert(1)",
                      "https://localhost/a", "https://private.local/a", "https://192.168.0.1/a",
                      "https://[::1]/a", "https://127.1/a", "https://0177.0.0.1/a", "https://0x7f.0.0.1/a",
                      "https://user:pass@example.com/a", "https://example.com:0/a", "https://example.com./a",
                      "https://example..com/a", "https://private.home.arpa/a", "https://example.com/has space"] {
            #expect(ProductAutofillSource(title: "참고", url: value).publicURL == nil, "\(value)")
        }
        #expect(source.publicURL != nil)
        #expect(ProductAutofillSource(title: "참고", url: "https://xn--bcher-kva.de/a").publicURL != nil)
        #expect(ProductAutofillSource(title: "참고", url: "https://bücher.de/a").publicURL != nil)
        #expect(ProductAutofillSource(title: " \n", url: source.url).publicURL == nil)
        #expect(ProductAutofillSource(title: String(repeating: "a", count: 301), url: source.url).publicURL == nil)
        #expect(ProductAutofillSource(title: "참고", url: "https://example.com/" + String(repeating: "a", count: 2048)).publicURL == nil)
        let tooMany = ProductAutofillDraft(productName: "후드", brand: nil, description: "설명",
            reviewNotes: [], sources: Array(repeating: source, count: 4))
        #expect(!tooMany.isValid)
    }

    @Test func AIApplicationAndRollbackMoveCopyAndSourcesTogether() throws {
        let garment = Garment(category: "Hoodie", group: .top, name: "원본", detail: "원본 설명", price: 100)
        garment.aiSources = [source]
        let before = ProductAutofillInputSnapshot(garment: garment)
        let replacement = ProductAutofillSource(title: "다른 참고 자료", url: "https://example.org/product")
        try before.apply(.init(productName: "새 제품", brand: nil, description: "새 설명", reviewNotes: [],
            sources: [replacement]), to: garment)
        #expect(garment.aiSources == [replacement])
        before.restore(to: garment)
        #expect(garment.aiSources == [source] && garment.name == "원본")
        try before.apply(.init(productName: "사진 기반 초안", brand: nil, description: "사진 기반 설명", reviewNotes: []), to: garment)
        #expect(garment.aiSources.isEmpty, "A new draft without confirmed research clears older references")
    }

    @Test func referencesSurviveDraftCompletionDiskReopenAndIsolatedEditing() throws {
        let directory = URL.temporaryDirectory.appending(path: "dobby-source-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "products.store")
        let garmentID: UUID = try autoreleasepool {
            let container = try makeContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let garment = Garment(category: "Hoodie", group: .top, name: "후드", detail: "설명", price: 100)
            garment.photos = [GarmentPhoto(fileName: "autofill-completion.jpg", role: .thumbnail, order: 0)]
            garment.sourceMeasurementID = UUID()
            garment.aiSources = [source]
            context.insert(garment)
            try ProductDraftStore.save(garment: garment, step: .measurementResult,
                measurementRecordID: garment.sourceMeasurementID!, photoModel: nil,
                measurementInputData: nil, in: context)
            #expect(garment.isCreationDraft)
            return garment.id
        }
        try autoreleasepool {
            let container = try makeContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let garment = try #require(context.fetch(FetchDescriptor<Garment>()).first)
            #expect(garment.aiSources == [source] && garment.isCreationDraft)
            var input: [UUID: String] = [:]
            try GarmentInputCompletion.save(garment: garment, drafts: &input) { try context.save() }
            #expect(garment.creationDraftData == nil && garment.informationCompletedAt != nil)
            #expect(garment.aiSources == [source])
        }
        try autoreleasepool {
            let container = try makeContainer(at: store)
            let session = try ProductInformationEditSession(garmentID: garmentID, container: container)
            #expect(session.garment.aiSources == [source] && !session.garment.isCreationDraft)
            session.garment.name = "수정 중"
            session.garment.aiSources = []
            #expect(session.hasChanges)
            session.discard()
            #expect(session.garment.aiSources == [source])
            session.garment.name = "저장한 수정"
            try GarmentInputCompletion.save(garment: session.garment, drafts: &session.measurementInput.drafts) {
                try session.context.save()
            }
            let reader = try ProductInformationEditSession(garmentID: garmentID, container: container)
            #expect(reader.garment.aiSources == [source] && reader.garment.name == "저장한 수정")
        }
    }

    @Test func oldAndCorruptMetadataNeverProduceLinks() {
        let garment = Garment(category: "Hoodie", group: .top)
        #expect(garment.aiSourcesData == nil && garment.aiSources.isEmpty)
        garment.aiSourcesData = Data("invalid".utf8)
        #expect(garment.aiSources.isEmpty)
        garment.aiSources = [ProductAutofillSource(title: "bad", url: "file:///tmp/secret")]
        #expect(garment.aiSourcesData == nil)
        garment.aiSources = Array(repeating: source, count: 6)
        #expect(garment.aiSources.count == 3)
    }

    @Test func editSnapshotRestoresReferencesAndReflectsThemIntoExistingDetail() throws {
        let container = try ModelContainer(for: ProductAppStorage.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let garment = Garment(category: "Hoodie", group: .top, name: "후드", detail: "설명", price: 100)
        garment.aiSources = [source]
        container.mainContext.insert(garment)
        try container.mainContext.save()
        let session = try ProductInformationEditSession(garmentID: garment.id, container: container)
        var input = GarmentMeasurementInputState()
        let snapshot = ProductInformationEditSnapshot(garment: session.garment, measurementInput: input)
        session.garment.aiSources = []
        #expect(snapshot.hasChanges(in: session.garment, measurementInput: input))
        snapshot.restore(session.garment, measurementInput: &input)
        #expect(session.garment.aiSources == [source])
        session.garment.aiSources = []
        try session.context.save()
        session.reflectSavedChanges(in: garment)
        #expect(garment.aiSources.isEmpty)
    }

    private func makeContainer(at store: URL) throws -> ModelContainer {
        let schema = ProductAppStorage.schema
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)
        ])
    }
}

import Foundation
import Observation

/// Shared by generation entry points. A cancelled or replaced request cannot publish a late result.
@MainActor @Observable
final class ProductAutofillSession {
    private(set) var isGenerating = false
    private var requestID: UUID?
    private let generator: any ProductAutofillGenerating

    init(generator: (any ProductAutofillGenerating)? = nil) {
        self.generator = generator ?? ProductAutofillClient.makeDefault()
    }

    func generate(photos: [CapturedAsset]) async throws -> ProductAutofillDraft {
        guard !isGenerating else { throw CancellationError() }
        let identifier = UUID()
        requestID = identifier
        isGenerating = true
        defer {
            if requestID == identifier {
                requestID = nil
                isGenerating = false
            }
        }
        let draft = try await generator.generate(photos: Array(photos.prefix(5)))
        try Task.checkCancellation()
        guard requestID == identifier else { throw CancellationError() }
        return draft
    }

    func cancel() {
        requestID = nil
        isGenerating = false
    }
}

/// AI copy and its separate reference metadata share one transaction.
/// Photos, price, and measurements never enter this transaction.
@MainActor
struct ProductAutofillInputSnapshot: Equatable {
    let garmentID: UUID
    let name: String
    let brand: String
    let detail: String
    let aiSourcesData: Data?

    init(garment: Garment) {
        garmentID = garment.id
        name = garment.name
        brand = garment.brand
        detail = garment.detail
        aiSourcesData = garment.aiSourcesData
    }

    var hasInformation: Bool {
        [name, brand, detail].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func matches(_ garment: Garment) -> Bool { self == Self(garment: garment) }

    func restore(to garment: Garment) {
        guard garment.id == garmentID else { return }
        garment.name = name
        garment.brand = brand
        garment.detail = detail
        garment.aiSourcesData = aiSourcesData
    }

    func apply(_ draft: ProductAutofillDraft, to garment: Garment) throws {
        guard matches(garment) else { throw ProductAutofillCompletionFailure.changedInformation }
        garment.name = draft.productName
        garment.brand = draft.brand ?? ""
        garment.detail = draft.description
        garment.aiSources = draft.sources
    }
}

enum ProductAutofillCompletionFailure: LocalizedError {
    case generation(String)
    case changedInformation

    var errorDescription: String? {
        switch self {
        case .generation(let message): return message
        case .changedInformation: return "입력한 정보가 바뀌어 AI 내용을 적용하지 않았어요. 다시 시도하거나 직접 입력해 주세요."
        }
    }
}

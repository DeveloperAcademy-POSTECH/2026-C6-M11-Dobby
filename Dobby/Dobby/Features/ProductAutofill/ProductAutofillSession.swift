import Foundation
import Observation

/// Shared by generation entry points. A cancelled or replaced request cannot publish a late result.
@MainActor @Observable
final class ProductAutofillSession {
    private var activeRequest: Task<ProductAutofillDraft, Error>?
    private let autofill: ShowcaseProductAutofill

    var isGenerating: Bool { activeRequest != nil }

    init(generator: (any ProductAutofillGenerating)? = nil, diagnosticOrigin: String = "productFlow") {
        autofill = generator.map { ShowcaseProductAutofill(generator: $0) }
            ?? ProductAutofillClient.makeDefault(diagnosticOrigin: diagnosticOrigin)
    }

    func generate(photos: [CapturedAsset], additionalPhotoURLs: [URL] = []) async throws -> ProductAutofillDraft {
        try Task.checkCancellation()
        guard activeRequest == nil else { throw CancellationError() }
        let request = Task {
            try await autofill.generate(photos: photos, additionalPhotoURLs: additionalPhotoURLs)
        }
        activeRequest = request
        defer { if activeRequest == request { activeRequest = nil } }
        let draft = try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        guard activeRequest == request else { throw CancellationError() }
        return draft
    }

    func cancel() {
        activeRequest?.cancel()
        activeRequest = nil
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
    let aiInformationGeneratedAt: Date?

    init(garment: Garment) {
        garmentID = garment.id
        name = garment.name
        brand = garment.brand
        detail = garment.detail
        aiSourcesData = garment.aiSourcesData
        aiInformationGeneratedAt = garment.aiInformationGeneratedAt
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
        garment.aiInformationGeneratedAt = aiInformationGeneratedAt
    }

    func apply(_ draft: ProductAutofillDraft, to garment: Garment) throws {
        guard matches(garment) else { throw ProductAutofillCompletionFailure.changedInformation }
        garment.name = ProductTextLimit.truncated(draft.productName, maximumLength: ProductTextLimit.name)
        garment.brand = draft.brand ?? ""
        garment.detail = ProductTextLimit.truncated(draft.description, maximumLength: ProductTextLimit.detail)
        garment.aiSources = draft.sources
        garment.aiInformationGeneratedAt = .now
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

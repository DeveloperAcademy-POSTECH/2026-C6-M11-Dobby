import SwiftUI
#if DEBUG
import SwiftData
#endif

/// A saved creation step, using the product's own photo and draft metadata.
struct ProductLibraryDraftCard: View {
    let garment: Garment
    let draft: ProductCreationDraft

    var body: some View {
        ProductDraftCard(step: draft.step, relativeSaveTime: relativeSaveTime,
                         stageAccessibilityIdentifier: "library.draft.stage.\(garment.id.uuidString)") {
            thumbnail
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(accessibleProductName), 작업 이어서 하기, 현재 \(draft.step.title)")
        .accessibilityValue("사진 \(garment.productPhotos.count)장, \(relativeSaveTime) 저장")
    }

    private var accessibleProductName: String {
        let name = garment.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "이름 없는 상품" : name
    }

    private var thumbnail: some View {
        Group {
            if let photo = garment.thumbnail {
                StoredProductPhotoView(photo: photo, maximumPixelSize: 480)
            } else {
                Rectangle()
                    .fill(Color(red: 217.0 / 255, green: 217.0 / 255, blue: 217.0 / 255))
            }
        }
    }

    private var relativeSaveTime: String {
        guard Date.now.timeIntervalSince(draft.savedAt) >= 60 else { return "방금 전" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: draft.savedAt, relativeTo: .now)
    }
}

#if DEBUG
#Preview("작업 이어서 하기 · 3일 전", traits: .sizeThatFitsLayout) {
    makeDraftCardPreview()
}

@MainActor
private func makeDraftCardPreview() -> some View {
    let container = LibraryPreviewData.makeContainer()
    let draft = ProductCreationDraft(step: .details, measurementRecordID: UUID(),
        photoState: nil, measurementInputData: nil,
        savedAt: .now.addingTimeInterval(-3 * 24 * 60 * 60))
    let garment: Garment
    do {
        guard let sample = try container.mainContext.fetch(FetchDescriptor<Garment>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )).first else {
            preconditionFailure("작업 이어서 하기 미리보기 상품이 없습니다.")
        }
        sample.informationCompletedAt = nil
        sample.creationDraftData = try JSONEncoder().encode(draft)
        try container.mainContext.save()
        garment = sample
    } catch {
        preconditionFailure("작업 이어서 하기 미리보기를 준비하지 못했습니다: \(error)")
    }
    return ProductLibraryDraftCard(garment: garment, draft: draft)
        .frame(width: 362)
        .padding(20)
        .background(LibraryStyle.background)
        .modelContainer(container)
        .preferredColorScheme(.light)
}
#endif

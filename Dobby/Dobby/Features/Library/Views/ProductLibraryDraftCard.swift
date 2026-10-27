import SwiftUI
#if DEBUG
import SwiftData
#endif

/// A saved creation step, using the product's own photo and draft metadata.
struct ProductLibraryDraftCard: View {
    let garment: Garment
    let draft: ProductCreationDraft
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    private let stageColor = Color(red: 126.0 / 255, green: 126.0 / 255, blue: 126.0 / 255)
    private let dateColor = Color(red: 159.0 / 255, green: 159.0 / 255, blue: 159.0 / 255)

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("작업 이어서 하기")
                        .font(.custom("Pretendard-Bold", fixedSize: 16 * typeScale))
                        .tracking(-0.43 * typeScale)
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .frame(height: 24 * typeScale)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(stageColor)
                        .frame(width: 10, height: 18)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 6 * typeScale) {
                    Text(draft.step.title)
                        .font(.custom("Pretendard-SemiBold", fixedSize: 14 * typeScale))
                        .tracking(-0.43 * typeScale)
                        .foregroundStyle(stageColor)
                        .lineLimit(1)
                        .frame(height: 21 * typeScale)
                        .accessibilityLabel("현재 \(draft.step.title)")
                        .accessibilityIdentifier("library.draft.stage.\(garment.id.uuidString)")
                    Text(relativeSaveTime)
                        .font(.custom("Pretendard-Medium", fixedSize: 12 * typeScale))
                        .tracking(-0.43 * typeScale)
                        .foregroundStyle(dateColor)
                        .lineLimit(1)
                        .frame(height: 18 * typeScale)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 88 * typeScale, alignment: .topLeading)

            thumbnail
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: max(125, 88 * typeScale + 32))
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
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
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 11.136))
        .accessibilityHidden(true)
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

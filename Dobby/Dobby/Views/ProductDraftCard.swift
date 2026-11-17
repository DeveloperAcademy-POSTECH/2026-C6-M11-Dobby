import SwiftUI

/// 홈과 보관함에서 함께 사용하는 임시저장 카드의 표시 영역입니다.
struct ProductDraftCard<Thumbnail: View>: View {
    let step: ProductDraftStep
    let relativeSaveTime: String
    var stageAccessibilityIdentifier: String? = nil
    @ViewBuilder let thumbnail: () -> Thumbnail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    private let stageColor = Color(white: 126.0 / 255)
    private let dateColor = Color(white: 159.0 / 255)
    private var usesVerticalLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        let layout = usesVerticalLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("작업 이어서 하기")
                        .font(.custom("Pretendard-Bold", fixedSize: 16 * typeScale))
                        .tracking(-0.43 * typeScale)
                        .foregroundStyle(.black)
                        .lineLimit(usesVerticalLayout ? nil : 1)
                        .frame(height: usesVerticalLayout ? nil : 24 * typeScale)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(stageColor)
                        .frame(width: 10, height: 18)
                        .accessibilityHidden(true)
                }

                Spacer().frame(height: 20 * typeScale)

                VStack(alignment: .leading, spacing: 4 * typeScale) {
                    Text(step.title)
                        .font(.custom("Pretendard-Bold", fixedSize: 12 * typeScale))
                        .tracking(-0.43 * typeScale)
                        .foregroundStyle(stageColor)
                        .lineLimit(usesVerticalLayout ? nil : 1)
                        .frame(height: usesVerticalLayout ? nil : 18 * typeScale)
                        .accessibilityLabel("현재 \(step.title)")
                        .accessibilityIdentifier(stageAccessibilityIdentifier ?? "draft-card.stage")
                    Text(relativeSaveTime)
                        .font(.custom("Pretendard-Medium", fixedSize: 12 * typeScale))
                        .tracking(-0.43 * typeScale)
                        .foregroundStyle(dateColor)
                        .lineLimit(usesVerticalLayout ? nil : 1)
                        .frame(height: usesVerticalLayout ? nil : 18 * typeScale)
                }
            }
            // Center the text group in Figma's 95pt column; its visible
            // content fits alongside the 93pt photo with a 5.5pt top inset.
            .padding(.top, usesVerticalLayout ? 0 : 5.5 * typeScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: usesVerticalLayout ? nil : 93 * typeScale,
                   alignment: .topLeading)

            thumbnail()
                .frame(width: 123, height: 93)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: usesVerticalLayout ? nil : max(125, 93 * typeScale + 32))
        .background(Color("BrandNeutralWhite"), in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
    }
}

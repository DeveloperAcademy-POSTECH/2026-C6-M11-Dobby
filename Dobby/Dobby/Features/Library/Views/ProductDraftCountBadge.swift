import SwiftUI

struct ProductDraftCountBadge: View {
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("임시저장")
                    .font(.custom("Pretendard-Regular", size: 14, relativeTo: .subheadline))
                Text(count.formatted())
                    .font(.custom("Pretendard-SemiBold", size: 14, relativeTo: .subheadline))
            }
            .tracking(-0.23)
            .foregroundStyle(isSelected ? Color("BrandNeutral50") : Color(count == 0 ? "BrandNeutral500" : "BrandNeutral900"))
            .frame(minHeight: 20)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color("BrandNeutral950") : Color("BrandNeutral100"), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("임시저장 \(count)개")
        .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
        .accessibilityHint(isSelected ? "모든 상품을 표시합니다." : "임시저장한 상품만 표시합니다.")
        .accessibilityIdentifier("library.draft-count")
    }
}

#if DEBUG
#Preview("임시저장 개수", traits: .sizeThatFitsLayout) {
    HStack {
        ProductDraftCountBadge(count: 3, isSelected: false, action: {})
        ProductDraftCountBadge(count: 3, isSelected: true, action: {})
    }
        .padding()
        .background(LibraryStyle.background)
}
#endif

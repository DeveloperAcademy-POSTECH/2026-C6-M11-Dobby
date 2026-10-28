import SwiftUI

struct ProductDraftCountBadge: View {
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("임시저장")
                    .font(.custom("Pretendard-Medium", fixedSize: 14))
                Text(count.formatted())
                    .font(.custom("Pretendard-Bold", fixedSize: 14))
            }
            .tracking(-0.14)
            .foregroundStyle(isSelected ? Color("BrandNeutral50") : Color("BrandNeutral500"))
            .frame(minHeight: 16)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color("BrandNeutral950") : Color("BrandNeutral100"), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("임시저장 \(count)개")
        .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
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

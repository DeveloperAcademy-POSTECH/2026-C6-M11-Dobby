import SwiftUI

struct ProductDraftCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("임시저장")
                .font(.custom("Pretendard-Medium", fixedSize: 14))
            Text(count.formatted())
                .font(.custom("Pretendard-Bold", fixedSize: 14))
        }
        .foregroundStyle(Color(red: 122.0 / 255, green: 117.0 / 255, blue: 110.0 / 255))
        .frame(minHeight: 16)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 242.0 / 255, green: 241.0 / 255, blue: 240.0 / 255), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("임시저장 (count)개")
        .accessibilityIdentifier("library.draft-count")
    }
}

#if DEBUG
#Preview("임시저장 개수", traits: .sizeThatFitsLayout) {
    ProductDraftCountBadge(count: 3)
        .padding()
        .background(LibraryStyle.background)
}
#endif

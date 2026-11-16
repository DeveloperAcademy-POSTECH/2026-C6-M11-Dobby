import SwiftUI

/// Field-only presentation: photos stay visible in their original section, while
/// the editable product, drafts and measurements remain intact underneath.
struct ProductInformationSkeletonView: View {
    let measurementColumnCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            field("제품명", height: 52, isRequired: true)
            field("상세 설명", height: 204, isRequired: true)
            field("가격", height: 52, isRequired: true)
            field("브랜드", height: 52)

            VStack(alignment: .leading, spacing: 8) {
                title("실측 사이즈")
                VStack(spacing: 0) {
                    placeholder(height: 43, radius: 0)
                    HStack(spacing: 0) {
                        ForEach(0..<max(1, min(measurementColumnCount, 6)), id: \.self) { index in
                            if index > 0 {
                                Rectangle().fill(Color("BrandNeutral50")).frame(width: 1)
                            }
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 64)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color("BrandNeutral50"), lineWidth: 1.5) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI 제품 정보를 생성하고 있어요")
        .accessibilityIdentifier("product-ai.skeleton")
    }

    private func field(_ name: String, height: CGFloat, isRequired: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title(name, isRequired: isRequired)
            placeholder(height: height, radius: 16)
        }
    }

    private func title(_ name: String, isRequired: Bool = false) -> some View {
        ProductFieldTitle(title: name, isRequired: isRequired)
    }

    private func placeholder(height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color("BrandNeutral50"))
            .frame(height: height)
    }
}

/// Shared photo placeholders for AI generation and album/camera imports.
struct ProductPhotoSkeletonStrip: View {
    let photoCount: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(0..<max(4, min(photoCount, 10)), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color("BrandNeutral50"))
                        .frame(width: 77, height: 108)
                }
            }
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
    }
}

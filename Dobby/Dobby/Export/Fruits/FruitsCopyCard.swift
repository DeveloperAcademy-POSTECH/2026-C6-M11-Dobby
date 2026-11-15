import SwiftUI

struct FruitsCopyCard: View {
    let product: ExportProduct
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            FruitsCopyFieldView(
                field: .productName,
                value: product.marketplacePayload.productName,
                onCopy: onCopy
            )
            FruitsCopyDivider()
            FruitsCopyFieldView(
                field: .description,
                value: product.marketplacePayload.description,
                onCopy: onCopy
            )
            FruitsCopyDivider()
            FruitsCopyFieldView(
                field: .price,
                value: product.marketplacePayload.value(for: .price),
                onCopy: onCopy
            )
            FruitsCopyDivider()
            FruitsCopyFieldView(
                field: .brand,
                value: product.marketplacePayload.brand,
                onCopy: onCopy
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: 360, alignment: .topLeading)
        .background(Color("BrandNeutral50"))
        .cornerRadius(16)
    }
}

private struct FruitsCopyDivider: View {
    var body: some View {
        Rectangle()
            .foregroundStyle(.clear)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .background(Color("BrandNeutral200"))
    }
}

#Preview {
    FruitsCopyCard(product: .fruitsLongPreview, onCopy: { _ in })
        .padding()
}

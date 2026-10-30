import SwiftUI

struct FruitsCopyCard: View {
    let product: ExportProduct
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FruitsCopyFieldView(
                field: .productName,
                value: product.marketplacePayload.productName,
                onCopy: onCopy
            )
            Divider().overlay(Color("BrandNeutral200"))
            FruitsCopyFieldView(
                field: .description,
                value: product.marketplacePayload.description,
                onCopy: onCopy
            )
            Divider().overlay(Color("BrandNeutral200"))
            FruitsCopyFieldView(
                field: .brand,
                value: product.marketplacePayload.brand,
                onCopy: onCopy
            )
        }
        .padding(.horizontal, 16)
        .background(Color("BrandNeutral100"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview("복사 카드") {
    FruitsCopyCard(product: .fruitsLongPreview, onCopy: { _ in })
        .padding()
}

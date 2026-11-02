import SwiftUI

struct FruitsCopyCard: View {
    let product: ExportProduct
    let onCopy: (ProductCopyField) -> Void
    @State private var copiedField: ProductCopyField?

    init(
        product: ExportProduct,
        initialCopiedField: ProductCopyField? = nil,
        onCopy: @escaping (ProductCopyField) -> Void
    ) {
        self.product = product
        self.onCopy = onCopy
        _copiedField = State(initialValue: initialCopiedField)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FruitsCopyFieldView(
                field: .productName,
                value: product.marketplacePayload.productName,
                showsCopyFeedback: copiedField == .productName,
                onCopy: copy
            )
            Divider().overlay(Color("BrandNeutral200"))
            FruitsCopyFieldView(
                field: .description,
                value: product.marketplacePayload.description,
                showsCopyFeedback: copiedField == .description,
                onCopy: copy
            )
            Divider().overlay(Color("BrandNeutral200"))
            FruitsCopyFieldView(
                field: .brand,
                value: product.marketplacePayload.brand,
                showsCopyFeedback: copiedField == .brand,
                onCopy: copy
            )
        }
        .padding(.horizontal, 16)
        .background(Color("BrandNeutral100"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func copy(_ field: ProductCopyField) {
        onCopy(field)
        copiedField = field
    }
}

#Preview("선택 전") {
    FruitsCopyCard(product: .fruitsLongPreview, onCopy: { _ in })
        .padding()
}

#Preview("제품명 복사") {
    FruitsCopyCard(
        product: .fruitsLongPreview,
        initialCopiedField: .productName,
        onCopy: { _ in }
    )
    .padding()
}

#Preview("설명 복사") {
    FruitsCopyCard(
        product: .fruitsLongPreview,
        initialCopiedField: .description,
        onCopy: { _ in }
    )
    .padding()
}

#Preview("브랜드 복사") {
    FruitsCopyCard(
        product: .fruitsLongPreview,
        initialCopiedField: .brand,
        onCopy: { _ in }
    )
    .padding()
}

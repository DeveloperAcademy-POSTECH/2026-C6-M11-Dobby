import SwiftUI

struct FruitsExportLayout: View {
    let product: ExportProduct
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            FruitsExportContent(product: product, onCopy: onCopy)
                .padding(.top, 28)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                FruitsExportContent(product: product, onCopy: onCopy)
                    .padding(.top, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#Preview("기본") {
    FruitsExportLayout(product: .fruitsPreview, onCopy: { _ in })
}

#Preview("작은 화면 - 긴 내용") {
    FruitsExportLayout(product: .fruitsLongPreview, onCopy: { _ in })
        .frame(height: 500)
}

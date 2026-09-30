import Foundation
import SwiftUI

struct ExportProduct: Identifiable {
    let id: String
    let imageData: Data?
    let fruits: ProductCopyPayload
    let instagram: ProductCopyPayload
    var name: String { fruits.productName }
}

extension ExportProduct {
    static let demo = ExportProduct(id: "levis-550-example", imageData: nil,
                                    fruits: .sample(for: .fruits), instagram: .sample(for: .instagram))
}

struct ExportProductHeader: View {
    let product: ExportProduct
    var body: some View {
        VStack(spacing: 12) {
            if let data = product.imageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(height: 150)
            } else {
                Image(systemName: "tshirt").resizable().scaledToFit()
                    .foregroundStyle(.secondary).frame(width: 100, height: 130)
                    .accessibilityLabel("상품 사진 없음")
            }
            Text(product.name).font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
    }
}

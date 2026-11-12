import SwiftUI
import UIKit

struct ExportProductSummary: View {
    let product: ExportProduct
    var photoCount: Int? = nil

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let data = product.thumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "tshirt")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 76)
            .background(ExportScreenStyle.field)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Text(product.name.isEmpty ? "이름 없는 상품" : product.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Label("사진 \(photoCount ?? product.exportPhotos.count)장", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

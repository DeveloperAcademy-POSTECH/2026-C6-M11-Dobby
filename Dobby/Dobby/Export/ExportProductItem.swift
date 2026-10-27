import SwiftUI
import UIKit

struct ExportProductItem<Thumbnail: View>: View {
    let name: String
    let brand: String?
    let priceText: String?
    private let thumbnail: Thumbnail

    init(
        name: String,
        brand: String?,
        priceText: String?,
        @ViewBuilder thumbnail: () -> Thumbnail
    ) {
        self.name = name
        self.brand = brand
        self.priceText = priceText
        self.thumbnail = thumbnail()
    }

    var body: some View {
        VStack(spacing: 0) {
            thumbnail
                .frame(
                    width: ExportProductItemLayout.thumbnailWidth,
                    height: ExportProductItemLayout.thumbnailHeight
                )
                .background(Color(.secondarySystemBackground))
                .clipShape(
                    RoundedRectangle(cornerRadius: ExportProductItemLayout.cornerRadius)
                )

            ExportProductItemMetadata(
                name: name,
                brand: brand,
                priceText: priceText
            )

            Spacer(minLength: 0)
        }
        .frame(
            width: ExportProductItemLayout.cardWidth,
            height: ExportProductItemLayout.cardHeight,
            alignment: .top
        )
        .background(Color(.systemBackground))
        .clipShape(
            RoundedRectangle(cornerRadius: ExportProductItemLayout.cornerRadius)
        )
    }
}

extension ExportProductItem where Thumbnail == ExportProductThumbnail {
    init(product: ExportProduct) {
        self.init(
            name: product.name,
            brand: product.brand.nilIfEmpty,
            priceText: product.displayPrice.nilIfEmpty
        ) {
            ExportProductThumbnail(imageData: product.thumbnailData)
        }
    }
}

struct ExportProductThumbnail: View {
    let imageData: Data?

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "tshirt")
                    .resizable()
                    .scaledToFit()
                    .padding(60)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("상품 사진 없음")
            }
        }
    }
}

private struct ExportProductItemMetadata: View {
    let name: String
    let brand: String?
    let priceText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(size: 14))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let brand {
                Text(brand)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let priceText {
                Text(priceText)
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ExportProductItemLayout {
    static let cardWidth: CGFloat = 174
    static let cardHeight: CGFloat = 375
    static let thumbnailWidth: CGFloat = 175
    static let thumbnailHeight: CGFloat = 232
    static let cornerRadius: CGFloat = 20
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview("상품 아이템", traits: .sizeThatFitsLayout) {
    ExportProductItem(product: .demo)
        .background(Color(.brandNeutral50))
}

#Preview("조합 가능한 상품 아이템", traits: .sizeThatFitsLayout) {
    ExportProductItem(
        name: "베이프 카모플라주 후드 셔츠 재킷",
        brand: "Bape",
        priceText: "155,000원"
    ) {
        Image(systemName: "photo")
            .resizable()
            .scaledToFit()
            .padding(56)
            .foregroundStyle(.secondary)
    }
    .background(Color(.brandNeutral50))
}

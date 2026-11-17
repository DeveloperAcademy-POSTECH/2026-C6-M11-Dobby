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
        }
        .frame(
            width: ExportProductItemLayout.cardWidth,
            alignment: .top
        )
        .background(Color(.brandNeutral50))
        .clipShape(
            RoundedRectangle(cornerRadius: ExportProductItemLayout.cornerRadius)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "이름 없는 상품" : name)
        .accessibilityValue([brand.map { "브랜드 \($0)" } ?? "브랜드 없음", priceText].compactMap { $0 }.joined(separator: ", "))
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
            if let brand {
                Text(brand)
                    .font(Font.custom("Pretendard-SemiBold", fixedSize: 17))
                    .lineLimit(1)
                    .foregroundColor(.brandNeutralBlack)
            } else {
                Text("No Brand")
                    .font(Font.custom("Pretendard-SemiBold", fixedSize: 17))
                    .lineLimit(1)
                    .foregroundColor(.brandNeutral500)
            }

            Text(name)
                .font(Font.custom("Pretendard", fixedSize: 15))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let priceText {
                Text(priceText)
                    .font(Font.custom("Pretendard", fixedSize: 14))
                    .foregroundStyle(Color(.brandNeutral900))
            }
        }
        .foregroundStyle(Color(.brandNeutralBlack))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ExportProductItemLayout {
    static let cardWidth: CGFloat = 175
    static let thumbnailWidth: CGFloat = 175
    static let thumbnailHeight: CGFloat = 233
    static let cornerRadius: CGFloat = 16
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

#Preview("상품 썸네일", traits: .sizeThatFitsLayout) {
    let imageData = UIImage(named: "LaunchSplashJacket")?.jpegData(compressionQuality: 0.9)

    ExportProductThumbnail(imageData: imageData)
        .frame(width: 175, height: 233)
        .clipShape(RoundedRectangle(cornerRadius: 16))
}

#Preview("상품 정보", traits: .sizeThatFitsLayout) {
    ExportProductItemMetadata(
        name: "베이프 카모플라주 후드 셔츠 재킷",
        brand: "Bape",
        priceText: "155,000원"
    )
    .frame(width: 175)
    .background(Color(.brandNeutral50))
}

#Preview("상품 정보 브랜드 없음", traits: .sizeThatFitsLayout) {
    ExportProductItemMetadata(
        name: "베이프 카모플라주 후드 셔츠 재킷",
        brand: nil,
        priceText: "155,000원"
    )
    .frame(width: 175)
    .background(Color(.brandNeutral50))
}

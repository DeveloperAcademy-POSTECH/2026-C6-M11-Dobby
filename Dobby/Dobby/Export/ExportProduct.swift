import Foundation
import SwiftUI

struct ExportProduct: Identifiable {
    let id: String
    let thumbnailData: Data?
    let marketplacePayload: ProductCopyPayload
    let instagramPayload: ProductCopyPayload
    var measurements: [ExportMeasurement]? = nil
    var photos: [Data] = []
    var category: String? = nil
    var completedChannels: Set<ExportChannel> = []
}

extension ExportProduct {
    var exportPhotos: [Data] {
        photos.isEmpty ? thumbnailData.map { [$0] } ?? [] : photos
    }

    var name: String { marketplacePayload.productName }

    var brand: String { marketplacePayload.brand }

    var displayPrice: String {
        guard let price = Int(marketplacePayload.price) else { return marketplacePayload.price }
        return "\(price.formatted(.number.grouping(.automatic)))원"
    }

    var exportMeasurements: [ExportMeasurement] {
        measurements ?? [
            ExportMeasurement(id: "length", title: "총장", value: marketplacePayload.length),
            ExportMeasurement(id: "waist", title: "허리 단면", value: marketplacePayload.waist),
            ExportMeasurement(id: "thigh", title: "허벅지 단면", value: marketplacePayload.thigh)
        ]
    }
}

struct ExportMeasurement: Identifiable {
    let id: String
    let title: String
    /// 단위 없이 입력란에 붙여넣을 숫자 문자열.
    let value: String
    var displayValue: String { MeasurementDisplayText.centimeters(value) }

    init(id: String, title: String, value: String) {
        self.id = id
        self.title = title
        self.value = value
    }

    init(measuredValue: MeasuredValue) {
        id = measuredValue.key
        title = measuredValue.label
        value = measuredValue.valueCm.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(0...2)))
    }
}

struct ExportProductItem: View {
    let product: ExportProduct

    var body: some View {
        ZStack {
            VStack {
                Color.clear
                    .frame(width: 175, height: 232)

                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name)
                        .font(.system(size: 14))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !product.brand.isEmpty {
                        Text(product.brand)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !product.displayPrice.isEmpty {
                        Text(product.displayPrice)
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .padding(10)
                .frame(alignment: .leading)
                .background(Color(.white))

                Spacer()
            }
            .frame(width: 174, height: 375)

            VStack {
                ExportProductImage(imageData: product.thumbnailData)

                Spacer()
            }
            .frame(width: 174, height: 375)
        }
        .frame(width: 174, height: 375)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

private struct ExportProductImage: View {
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
        .frame(width: 175, height: 232)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

#Preview("상품 아이템", traits: .sizeThatFitsLayout) {
    ExportProductItem(product: .demo)
        .background(Color(.brandNeutral50))
}

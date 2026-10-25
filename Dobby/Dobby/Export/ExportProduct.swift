import Foundation
import SwiftUI

struct ExportProduct: Identifiable {
    let id: String
    let imageData: Data?
    let fruits: ProductCopyPayload
    let instagram: ProductCopyPayload
    var detailMeasurements: [ExportMeasurement]? = nil
    var photoData: [Data] = []
    var garmentCategory: String? = nil
    var completedChannels: Set<ExportChannel> = []
    var displayPhotos: [Data] { photoData.isEmpty ? imageData.map { [$0] } ?? [] : photoData }
    var name: String { fruits.productName }

    var brand: String { fruits.brand }

    var displayPrice: String {
        guard let price = Int(fruits.price) else { return fruits.price }
        return "\(price.formatted(.number.grouping(.automatic)))원"
    }

    var copyMeasurements: [ExportMeasurement] {
        detailMeasurements ?? [
            ExportMeasurement(id: "length", title: "총장", value: fruits.length),
            ExportMeasurement(id: "waist", title: "허리 단면", value: fruits.waist),
            ExportMeasurement(id: "thigh", title: "허벅지 단면", value: fruits.thigh)
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

extension ExportProduct {
    static let demo = ExportProduct(id: "levis-550-example", imageData: nil,
                                    fruits: .sample(for: .fruits), instagram: .sample(for: .instagram))
}

struct ExportProductHeader: View {
    let product: ExportProduct
    var body: some View {
        VStack(spacing: 0) {
            if let data = product.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 175, height: 200)
                    .clipped()
            } else {
                Image(systemName: "tshirt")
                    .resizable()
                    .scaledToFit()
                    .padding(42)
                    .foregroundStyle(.secondary)
                    .frame(width: 175, height: 200)
                    .background(Color(.secondarySystemBackground))
                    .accessibilityLabel("상품 사진 없음")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !product.brand.isEmpty {
                    Text(product.brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !product.displayPrice.isEmpty {
                    Text(product.displayPrice)
                        .font(.subheadline.weight(.medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.systemBackground))
        }
        .frame(width: 175)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

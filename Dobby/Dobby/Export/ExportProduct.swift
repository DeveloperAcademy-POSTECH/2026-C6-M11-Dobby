import Foundation
import SwiftUI

struct ExportProduct: Identifiable {
    let id: String
    let imageData: Data?
    let fruits: ProductCopyPayload
    let instagram: ProductCopyPayload
    var detailMeasurements: [ExportMeasurement]? = nil
    var photoData: [Data] = []
    var displayPhotos: [Data] { photoData.isEmpty ? imageData.map { [$0] } ?? [] : photoData }
    var name: String { fruits.productName }

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

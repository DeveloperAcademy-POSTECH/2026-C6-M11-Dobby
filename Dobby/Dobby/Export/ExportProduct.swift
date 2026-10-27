import Foundation

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

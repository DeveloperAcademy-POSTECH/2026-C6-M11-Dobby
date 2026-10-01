//
//  ExportProduct+Garment.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import Foundation

extension ExportProduct {
    /// 편집 완료 시점의 상품을 전달한다. 채널별 예시 문구나 측정값을 섞지 않는다.
    @MainActor
    init(garment: Garment, loadPhoto: @MainActor (GarmentPhoto) -> Data? = {
        try? Data(contentsOf: GarmentStore.url(for: $0))
    }) {
        let measurements = garment.orderedMeasurements
            .filter { $0.valueCm.isFinite && $0.valueCm > 0 }
            .map { value in
                // Export the accepted stored value; the rounded input display
                // and automatic original are not an export data source.
                return ExportMeasurement(id: value.key, title: value.label,
                    value: value.valueCm.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
                        .grouping(.never).precision(.significantDigits(1...15))))
            }
        let photos = garment.productPhotos.compactMap { photo -> (id: UUID, data: Data)? in
            guard let data = loadPhoto(photo) else { return nil }
            return (photo.id, data)
        }
        let payload = ProductCopyPayload(
            productName: garment.name,
            description: garment.detail,
            brand: garment.brand,
            measurements: measurements.map { "\($0.title) \($0.value) cm" }.joined(separator: "\n"),
            price: garment.price.map { String($0) } ?? "",
            length: measurements.first { $0.id == "totalLength" }?.value
                ?? measurements.first { $0.id == "totalLengthLeft" }?.value ?? "",
            waist: garment.group == .top ? "" : measurements.first { $0.id == "waistWidth" }?.value ?? "",
            thigh: garment.group == .pants
                ? measurements.first { $0.id == "thighWidthLeft" }?.value
                    ?? measurements.first { $0.id == "thighWidthRight" }?.value ?? ""
                : ""
        )
        self.init(
            id: garment.id.uuidString,
            imageData: photos.first { $0.id == garment.thumbnail?.id }?.data ?? photos.first?.data,
            fruits: payload,
            instagram: payload,
            detailMeasurements: measurements,
            photoData: photos.map(\.data)
        )
    }
}

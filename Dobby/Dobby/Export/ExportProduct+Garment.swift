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
        let measurements = garment.orderedMeasurements.map { ExportMeasurement(measuredValue: $0) }
        let photos = garment.orderedPhotos.compactMap { photo -> (id: UUID, data: Data)? in
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
            waist: measurements.first { $0.id == "waistWidth" }?.value ?? "",
            thigh: measurements.first { $0.id == "thighWidth" }?.value ?? ""
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

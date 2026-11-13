import Foundation

extension ExportProduct {
    static let fruitsPreview = ExportProduct(
        id: "fruits-preview",
        thumbnailData: nil,
        marketplacePayload: ProductCopyPayload(
            productName: "LEVI'S 550 보로 사시코 커스텀 팬츠",
            description: "빈티지한 워싱과 자연스러운 실루엣이 돋보이는 제품입니다.",
            brand: "LEVI'S",
            measurements: "",
            price: "56000",
            length: "68",
            waist: "",
            thigh: ""
        ),
        instagramPayload: .sample(for: .instagram),
        measurements: [
            ExportMeasurement(id: "shoulder", title: "어깨", value: "56"),
            ExportMeasurement(id: "chest", title: "가슴", value: "55"),
            ExportMeasurement(id: "length", title: "기장", value: "68"),
            ExportMeasurement(id: "sleeve", title: "소매", value: "52")
        ]
    )

    static let fruitsLongPreview = ExportProduct(
        id: "fruits-long-preview",
        thumbnailData: nil,
        marketplacePayload: ProductCopyPayload(
            productName: "아주 긴 제품명이 두 줄을 넘어가는 경우를 확인하기 위한 빈티지 오버사이즈 재킷",
            description: ProductCopyPayload.sample(for: .fruits).description,
            brand: "A VERY LONG VINTAGE BRAND NAME",
            measurements: "",
            price: "56000",
            length: "102",
            waist: "38",
            thigh: "32"
        ),
        instagramPayload: .sample(for: .instagram),
        measurements: [
            ExportMeasurement(id: "waist", title: "허리", value: "38"),
            ExportMeasurement(id: "rise", title: "밑위", value: "30"),
            ExportMeasurement(id: "thigh", title: "허벅지", value: "32"),
            ExportMeasurement(id: "hem", title: "밑단", value: "22"),
            ExportMeasurement(id: "length", title: "총장", value: "102")
        ]
    )
}

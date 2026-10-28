import Foundation

// 상품 편집 화면이 연결되기 전 앱 진입점과 프리뷰에서만 사용하는 제공된 예시.
extension ProductCopyPayload {
    static func sample(for channel: CopyChannel) -> Self {
        let name = "LEVI'S 550 보로 사시코 커스텀 팬츠"
        let priceLine = channel == .fruits ? "56,000" : "65,000 >팔로우 시 55,000"
        return Self(productName: name, description: """
        \(name)

        Size 59 43 32
        (총장 허리 허벅지)단면cm

        Price- \(priceLine)

        기본 배송료 4,000
        2개이상 구매시 배송비 무료

        모든 상품은 세탁 및 고온 스팀 살균 작업까지
        마친 상품입니다 (특수 제품 제외)

        사이즈는 실측을 기준으로 본인 옷하고 비교하는것이 가장 정확합니다.
        모델의 스팩이나 표기사이즈는
        별 도움이 안됩니다

        착샷이 제일 실물과 색감이 비슷합니다

        자신에게 맞는 제품은 언젠가 들어오니 천천히 비교해 보고 구매하세요😘

        검수 중 미쳐 확인치 못한 오염이나 하자가 있을 수 있습니다.
        상세 사진들 원하시면 보내드리니 원하는 부위 dm으로 보내주세요
        교환이나 환불이 어려우니 신중한 구매 부탁드립니다.
        """, brand: "LEVI'S", measurements: "총장 59 cm\n허리 단면 43 cm\n허벅지 단면 32 cm",
                    price: channel == .fruits ? "56000" : "65000", length: "59", waist: "43", thigh: "32")
    }
}

extension ExportProduct {
    static let demo = ExportProduct(
        id: "levis-550-example",
        thumbnailData: nil,
        marketplacePayload: .sample(for: .fruits),
        instagramPayload: .sample(for: .instagram)
    )
}

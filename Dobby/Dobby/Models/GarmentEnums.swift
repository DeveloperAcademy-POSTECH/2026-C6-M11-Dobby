//
//  GarmentEnums.swift
//  Dobby
//
//  Created by 오하나 on 10/1/26.
//

import SwiftUI

/// 랜드마크 모델이 나뉘는 단위. 실측 항목이 이 값에 따라 달라진다.
enum GarmentGroup: String, CaseIterable, Codable {
    case top, pants, skirt

    var label: String {
        switch self {
        case .top: return "상의"
        case .pants: return "바지"
        case .skirt: return "스커트"
        }
    }

    /// 분류 모델의 15종을 우리 세 그룹으로 옮긴다. 파이프라인의 `GarmentRouter`와 같은 표다.
    /// 여기 없는 값(Dresses)은 지원하지 않는 종류라 nil이 된다.
    static func from(category: String) -> GarmentGroup? {
        switch category {
        case "T-shirt", "Shirt", "Polo", "Sweater", "Hoodie",
             "Blazer", "Jacket", "Coat", "Denim Jacket", "Sports Jacket":
            return .top
        case "Jeans", "Long Pants", "Shorts":
            return .pants
        case "Skirt":
            return .skirt
        default:
            return nil
        }
    }
}

enum PhotoRole: String, Codable {
    /// 보관함과 내보내기에 쓰는 대표 사진. 한 벌에 하나만 둔다.
    case thumbnail
    case detail
}

extension ExportChannel {
    var label: String {
        switch self {
        case .instagram: return "Instagram"
        case .naverStore: return "네이버스토어"
        case .cafe24: return "카페24"
        case .fruitsFamily: return "후루츠패밀리"
        }
    }

    /// 목록에 쓸 임시 표시. 실제 브랜드 아이콘을 Assets에 넣으면 그쪽으로 바꾼다.
    var symbol: String {
        switch self {
        case .instagram: return "camera"
        case .naverStore: return "storefront"
        case .cafe24: return "cart"
        case .fruitsFamily: return "bag"
        }
    }

    var tint: Color {
        switch self {
        case .instagram: return Color(red: 0.88, green: 0.20, blue: 0.53)
        case .naverStore: return Color(red: 0.11, green: 0.78, blue: 0.33)
        case .cafe24: return Color(red: 0.13, green: 0.44, blue: 0.93)
        case .fruitsFamily: return Color(red: 0.12, green: 0.12, blue: 0.14)
        }
    }
}

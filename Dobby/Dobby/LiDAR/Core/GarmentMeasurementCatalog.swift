import Foundation

/// Manual measurement presets, not the classes recognised by a garment model.
/// Every preset describes one straight segment supported by the current A/B editor.
nonisolated enum GarmentCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case top, outerwear, bottoms, skirt, dress, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: "상의"
        case .outerwear: "아우터"
        case .bottoms: "바지"
        case .skirt: "치마"
        case .dress: "원피스"
        case .other: "기타"
        }
    }

    var definitions: [MeasurementDefinition] {
        let presets: [MeasurementDefinition]
        switch self {
        case .top, .outerwear:
            // Preserve IDs already used in saved measurements and the ML adapter contract.
            presets = MeasurementDefinition.longSleeve
        case .bottoms:
            presets = [
                GarmentMeasurementCatalog.waist,
                GarmentMeasurementCatalog.hip,
                .init(id: "thigh", title: "허벅지 단면", landmarkIDs: ["thighInnerLeft", "thighOuterLeft"]),
                .init(id: "frontRise", title: "앞밑위(직선)", landmarkIDs: ["waistCenterFront", "crotch"]),
                .init(id: "inseam", title: "인심(직선)", landmarkIDs: ["crotch", "innerHemLeft"]),
                .init(id: "outseam", title: "바깥길이(직선)", landmarkIDs: ["waistSideLeft", "outerHemLeft"]),
                .init(id: "legOpening", title: "바짓단 단면", landmarkIDs: ["innerHemLeft", "outerHemLeft"])
            ]
        case .skirt:
            presets = [
                GarmentMeasurementCatalog.waist,
                GarmentMeasurementCatalog.hip,
                .init(id: "skirtLength", title: "치마 길이(직선)", landmarkIDs: ["waistCenterFront", "skirtHemCenter"]),
                .init(id: "skirtHem", title: "치마 밑단 폭(직선)", landmarkIDs: ["skirtHemLeft", "skirtHemRight"])
            ]
        case .dress:
            presets = Array(MeasurementDefinition.longSleeve.prefix(2)) + [
                GarmentMeasurementCatalog.waist,
                .init(id: "dressLength", title: "원피스 총장(직선)", landmarkIDs: ["neckSide", "dressHemBelowNeck"]),
                MeasurementDefinition.longSleeve[3],
                .init(id: "dressHem", title: "원피스 밑단 폭(직선)", landmarkIDs: ["dressHemLeft", "dressHemRight"])
            ]
        case .other:
            presets = []
        }
        return presets + [.testDistance]
    }
}

nonisolated enum GarmentMeasurementCatalog {
    fileprivate static let waist = MeasurementDefinition(
        id: "waist", title: "허리 단면", landmarkIDs: ["waistLeft", "waistRight"]
    )
    fileprivate static let hip = MeasurementDefinition(
        id: "hip", title: "엉덩이 단면", landmarkIDs: ["hipLeft", "hipRight"]
    )

    /// Guides describe a reproducible placement convention, not an industry-wide size standard.
    static func guide(for definitionID: String) -> String {
        let placement: String
        switch definitionID {
        case "chest":
            placement = "양쪽 겨드랑이 아래의 같은 높이에 두 점을 놓으세요. 단면 너비이며 가슴둘레가 아닙니다."
        case "shoulder":
            placement = "양쪽 어깨 봉제선 끝에 두 점을 놓으세요. 어깨선이 없는 래글런 등은 측정 기준을 따로 기록하세요."
        case "length":
            placement = "목 옆 어깨 시작점과 그 바로 아래 밑단에 두 점을 놓으세요. 앞면·뒷면 중 어느 면인지 기록하세요."
        case "sleeve":
            placement = "소매를 곧게 펼쳐 어깨 봉제선 끝과 소맷단에 두 점을 놓으세요. 봉제선을 따라 굽은 길이가 아닌 직선거리입니다."
        case "waist":
            placement = "허리 양 끝의 같은 높이에 두 점을 놓으세요. 밴딩은 당기지 않은 상태로 재며 단면 너비이지 허리둘레가 아닙니다."
        case "hip":
            placement = "엉덩이 부분의 가장 넓은 위치에서 양쪽 같은 높이에 두 점을 놓으세요. 단면 너비이며 엉덩이둘레가 아닙니다."
        case "thigh":
            placement = "가랑이 바로 아래 한쪽 바지통의 안쪽과 바깥쪽 같은 높이에 두 점을 놓으세요. 허벅지 단면 너비입니다."
        case "frontRise":
            placement = "앞 허리선 중앙과 가랑이 봉제선 교차점에 두 점을 놓으세요. 곡선 봉제선을 따라 잰 밑위와 다른 직선거리입니다."
        case "inseam":
            placement = "한쪽 다리를 곧게 펼쳐 가랑이와 안쪽 밑단에 두 점을 놓으세요. 안쪽 봉제선을 따라 잰 길이와 다른 직선거리입니다."
        case "outseam":
            placement = "한쪽 허리 바깥 끝과 같은 쪽 바깥 밑단에 두 점을 놓으세요. 옆 봉제선을 따라 잰 길이와 다른 직선거리입니다."
        case "legOpening":
            placement = "한쪽 바짓단의 안쪽과 바깥쪽 끝에 두 점을 놓으세요. 바짓단 단면 너비이며 둘레가 아닙니다."
        case "skirtLength":
            placement = "앞 허리선 중앙과 그 아래 밑단 중앙에 두 점을 놓으세요. 직선거리이며 비대칭 밑단은 선택한 위치를 기록하세요."
        case "skirtHem", "dressHem":
            placement = "펼친 밑단의 왼쪽 끝과 오른쪽 끝에 두 점을 놓으세요. 주름이나 곡선을 따라 잰 밑단 길이·둘레가 아닌 직선 폭입니다."
        case "dressLength":
            placement = "목 옆 어깨 시작점과 그 바로 아래 원피스 밑단에 두 점을 놓으세요. 직선거리이며 비대칭 밑단은 선택한 위치를 기록하세요."
        default:
            placement = "측정하려는 구간의 양 끝에 두 점을 놓으세요. 두 점 사이의 직선거리이며 곡선·둘레·표면을 따라가는 길이가 아닙니다."
        }
        return "옷을 바닥에 평평하게 펼치고 주름을 편 뒤, " + placement
    }
}

import Foundation

/// Use the same automatic target gate as capture. Hooded outerwear is covered
/// by the existing jacket/coat labels; Hoodie and Sweater are also explicit targets.
nonisolated enum OuterwearComparisonClassificationPolicy {
    static func category(route: GarmentClassifierRoute, scores: [GarmentClassificationScore]) throws -> String {
        guard case let .selected(kind, category, _) = route, kind == .top,
              GarmentLandmarkSourceRoutingPolicy.route(classification: route, scores: scores) == .lunaOuterwear else {
            throw OuterwearComparisonClassificationError(route: route, scores: scores)
        }
        return category
    }
}

/// A comparison gate failure is not a statement that automatic measurement is
/// unsupported. Keep the classifier evidence so the UI can explain this stage.
nonisolated struct OuterwearComparisonClassificationError: Error, LocalizedError, Sendable {
    let route: GarmentClassifierRoute
    let scores: [GarmentClassificationScore]

    var errorDescription: String? {
        let reason: String
        switch route {
        case let .selected(_, category, _)
            where GarmentLandmarkSourceRoutingPolicy.outerwearCategories.contains(category):
            reason = "분류기의 1순위는 \(category)이지만 다른 옷 종류와 구분이 충분하지 않아 AI 측정 대상인지 확정하지 못했어요."
        case let .selected(_, category, _), let .unsupported(category, _):
            reason = "분류기가 이 사진을 \(category)(으)로 인식하여 비교 대상에 포함되지 않았어요."
        case .uncertain(let uncertainty):
            switch uncertainty {
            case .lowConfidence:
                reason = "옷 종류 분류 점수가 낮아 AI 측정 대상인지 확정하지 못했어요."
            case .ambiguousKinds, .insufficientMargin:
                reason = "옷 종류 분류 결과가 비슷해 AI 측정 대상인지 확정하지 못했어요."
            case .noResults:
                reason = "옷 종류 분류 결과를 얻지 못했어요."
            case .malformedResults, .invalidConfiguration:
                reason = "옷 종류 분류 결과 또는 설정을 확인하지 못했어요."
            }
        }
        let candidates = scores.filter { $0.confidence.isFinite }.sorted { $0.confidence > $1.confidence }
            .prefix(3).map { "\($0.label) \(String(format: "%.3f", $0.confidence))" }.joined(separator: " · ")
        let details = candidates.isEmpty ? "" : "\n분류 점수: " + candidates
        return reason + "\n비교 대상은 아우터·후드가 달린 아우터·Hoodie·Sweater입니다. AI 측정점 요청은 시작하지 않았어요." + details
    }
}

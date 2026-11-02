import Foundation

nonisolated enum GarmentLandmarkSourceRoute: Equatable, Sendable {
    case coreML, lunaOuterwear, uncertainOuterwear
}

nonisolated enum GarmentLandmarkSourceRoutingPolicy {
    static let outerwearCategories: Set<String> = ["Blazer", "Jacket", "Coat", "Denim Jacket", "Sports Jacket", "Hoodie", "Sweater"]

    /// Require separation from categories outside the AI target group. Close
    /// scores among Hoodie, Sweater and outerwear share the same AI route.
    static func route(classification: GarmentClassifierRoute, scores: [GarmentClassificationScore],
                      minimumOuterwearMargin: Double = 0.01) -> GarmentLandmarkSourceRoute {
        guard case let .selected(kind, category, confidence) = classification,
              kind == .top, outerwearCategories.contains(category) else { return .coreML }
        guard minimumOuterwearMargin.isFinite, (0...1).contains(minimumOuterwearMargin),
              confidence.isFinite, confidence > 0, confidence <= 1,
              Set(scores.map(\.label)).count == scores.count,
              scores.allSatisfy({ $0.confidence.isFinite && (0...1).contains($0.confidence) }),
              scores.contains(where: { $0.label == category && $0.confidence == confidence }) else {
            return .uncertainOuterwear
        }
        let rival = scores.filter { !outerwearCategories.contains($0.label) }.map(\.confidence).max() ?? 0
        return confidence - rival + 1e-12 >= minimumOuterwearMargin ? .lunaOuterwear : .uncertainOuterwear
    }
}

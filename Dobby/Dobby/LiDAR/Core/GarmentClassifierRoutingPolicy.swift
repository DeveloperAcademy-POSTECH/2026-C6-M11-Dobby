import Foundation

/// The exact labels exported by the supplied fifteen-category classifier.
/// A pose detector's confidence must never be fed into this contract.
nonisolated enum GarmentClassificationCategory: String, Codable, CaseIterable, Sendable {
    case tShirt = "T-shirt", shirt = "Shirt", polo = "Polo", sweater = "Sweater", hoodie = "Hoodie"
    case blazer = "Blazer", jacket = "Jacket", coat = "Coat", denimJacket = "Denim Jacket"
    case sportsJacket = "Sports Jacket", jeans = "Jeans", longPants = "Long Pants", shorts = "Shorts"
    case skirt = "Skirt", dresses = "Dresses"

    var garmentKind: AutomaticGarmentKind? {
        switch self {
        case .jeans, .longPants, .shorts: .bottoms
        case .skirt, .dresses: nil
        default: .top
        }
    }
}

nonisolated struct GarmentClassificationScore: Codable, Equatable, Sendable {
    var label: String
    var confidence: Double
}

nonisolated enum GarmentClassifierUncertainty: String, Codable, Sendable {
    case noResults, malformedResults, invalidConfiguration
    case lowConfidence, ambiguousKinds, insufficientMargin
}

nonisolated enum GarmentClassifierRoute: Codable, Equatable, Sendable {
    case selected(kind: AutomaticGarmentKind, category: String, confidence: Double)
    case unsupported(category: String, confidence: Double)
    case uncertain(reason: GarmentClassifierUncertainty)

    var garmentKind: AutomaticGarmentKind? {
        if case let .selected(kind, _, _) = self { return kind }
        return nil
    }

    var category: String? {
        switch self {
        case let .selected(_, category, _), let .unsupported(category, _): category
        case .uncertain: nil
        }
    }

    var confidence: Double? {
        switch self {
        case let .selected(_, _, confidence), let .unsupported(_, confidence): confidence
        case .uncertain: nil
        }
    }
}

/// Highest individual classifier category chooses the route; categories are
/// never summed. Optional thresholds are rejection heuristics, not a statement
/// about calibrated accuracy. Defaults preserve the supplied handoff's top-1
/// behavior, except that a tie between different routes remains ambiguous.
nonisolated enum GarmentClassifierRoutingPolicy {
    static func route(scores: [GarmentClassificationScore], minimumConfidence: Double = 0,
                      minimumCrossKindMargin: Double = 0) -> GarmentClassifierRoute {
        guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence),
              minimumCrossKindMargin.isFinite, (0...1).contains(minimumCrossKindMargin) else {
            return .uncertain(reason: .invalidConfiguration)
        }
        guard !scores.isEmpty else { return .uncertain(reason: .noResults) }
        guard scores.count <= 256, Set(scores.map(\.label)).count == scores.count,
              scores.allSatisfy({ !$0.label.isEmpty && $0.confidence.isFinite && (0...1).contains($0.confidence) }) else {
            return .uncertain(reason: .malformedResults)
        }
        // Stable top-1 keeps the first category only when routes are identical.
        let best = scores.dropFirst().reduce(scores[0]) { best, candidate in
            candidate.confidence > best.confidence ? candidate : best
        }
        guard best.confidence > 0 else { return .uncertain(reason: .noResults) }
        guard best.confidence >= minimumConfidence else { return .uncertain(reason: .lowConfidence) }
        let kind = GarmentClassificationCategory(rawValue: best.label)?.garmentKind
        let rival = scores.filter {
            GarmentClassificationCategory(rawValue: $0.label)?.garmentKind != kind
        }.map(\.confidence).max()
        if let rival {
            let margin = best.confidence - rival
            if abs(margin) <= 0.000_000_001 { return .uncertain(reason: .ambiguousKinds) }
            if margin < minimumCrossKindMargin { return .uncertain(reason: .insufficientMargin) }
        }
        guard let kind else { return .unsupported(category: best.label, confidence: best.confidence) }
        return .selected(kind: kind, category: best.label, confidence: best.confidence)
    }
}

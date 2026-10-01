import Foundation
import XCTest
@testable import DobbyLiDARCore

final class GarmentClassifierRoutingPolicyTests: XCTestCase {
    private func score(_ label: String, _ confidence: Double) -> GarmentClassificationScore {
        .init(label: label, confidence: confidence)
    }

    func testAllFifteenCategoriesRouteToTheirSupportedModelOrStop() {
        XCTAssertEqual(GarmentClassificationCategory.allCases.count, 15)
        for category in GarmentClassificationCategory.allCases {
            let route = GarmentClassifierRoutingPolicy.route(scores: [score(category.rawValue, 0.8)])
            if let kind = category.garmentKind {
                XCTAssertEqual(route, .selected(kind: kind, category: category.rawValue, confidence: 0.8))
            } else {
                XCTAssertEqual(route, .unsupported(category: category.rawValue, confidence: 0.8))
                XCTAssertNil(route.garmentKind)
            }
        }
    }

    func testHighestIndividualCategoryWinsEvenWhenOtherGroupScoresSumHigher() {
        let scores = [score("Shirt", 0.24), score("T-shirt", 0.23), score("Shorts", 0.3), score("Jeans", 0.1)]
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: scores),
                       .selected(kind: .bottoms, category: "Shorts", confidence: 0.3))
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: scores.reversed()),
                       .selected(kind: .bottoms, category: "Shorts", confidence: 0.3))
    }

    func testUnsupportedTopCategoryNeverFallsThroughToBestSupportedCategory() {
        for category in ["Skirt", "Dresses", "Future category", "shirt"] {
            let result = GarmentClassifierRoutingPolicy.route(scores: [score("Shirt", 0.4), score(category, 0.6)])
            XCTAssertEqual(result, .unsupported(category: category, confidence: 0.6))
            XCTAssertNil(result.garmentKind)
        }
    }

    func testDifferentRouteTiesAreAmbiguousRegardlessOfInputOrder() {
        for pair in [("Shirt", "Shorts"), ("Jeans", "Skirt"), ("Dresses", "T-shirt")] {
            let scores = [score(pair.0, 0.5), score(pair.1, 0.5)]
            XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: scores), .uncertain(reason: .ambiguousKinds))
            XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: scores.reversed()), .uncertain(reason: .ambiguousKinds))
        }
    }

    func testSameKindTiePreservesFirstCategoryWithoutUnnecessaryModelAmbiguity() {
        let result = GarmentClassifierRoutingPolicy.route(scores: [score("T-shirt", 0.5), score("Shirt", 0.5)])
        XCTAssertEqual(result, .selected(kind: .top, category: "T-shirt", confidence: 0.5))
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: [score("Skirt", 0.5), score("Dresses", 0.5)]),
                       .unsupported(category: "Skirt", confidence: 0.5))
    }

    func testMarginUsesBestCompetingRouteCategoryWithoutSummingOrBlockingWithinTop() {
        let scores = [score("Shirt", 0.45), score("T-shirt", 0.44), score("Jeans", 0.1), score("Skirt", 0.01)]
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: scores, minimumCrossKindMargin: 0.3).garmentKind, .top)
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: scores, minimumCrossKindMargin: 0.36),
                       .uncertain(reason: .insufficientMargin))
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: [score("Shirt", 0.51), score("Skirt", 0.49)],
                                                           minimumCrossKindMargin: 0.1),
                       .uncertain(reason: .insufficientMargin))
    }

    func testThresholdsRejectBeforeAnyModelRouteAndDefaultsPreserveHandoffLowScores() {
        let scores = [score("Shirt", 0.2), score("Shorts", 0.1)]
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: scores).garmentKind, .top)
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: scores, minimumConfidence: 0.3),
                       .uncertain(reason: .lowConfidence))
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: [score("Jeans", 1)], minimumConfidence: 1).garmentKind, .bottoms)
    }

    func testMalformedEntriesCannotBeSilentlyDiscardedToSelectAnotherCategory() {
        for invalid in [score("Shorts", .nan), score("Shorts", .infinity), score("Shorts", -0.1),
                        score("Shorts", 1.01), score("", 0.9)] {
            XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: [score("Shirt", 0.9), invalid]),
                           .uncertain(reason: .malformedResults))
        }
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: [score("Shirt", 0.9), score("Shirt", 0.8)]),
                       .uncertain(reason: .malformedResults))
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: (0..<257).map { score("category\($0)", 0.001) }),
                       .uncertain(reason: .malformedResults))
    }

    func testEmptyZeroAndInvalidThresholdsCannotSelectModels() {
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: []), .uncertain(reason: .noResults))
        XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: [score("Shirt", 0), score("Shorts", 0)]),
                       .uncertain(reason: .noResults))
        for invalid in [-0.01, 1.01, Double.nan, .infinity] {
            XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: [score("Shirt", 0.9)], minimumConfidence: invalid),
                           .uncertain(reason: .invalidConfiguration))
            XCTAssertEqual(GarmentClassifierRoutingPolicy.route(scores: [score("Shirt", 0.9)], minimumCrossKindMargin: invalid),
                           .uncertain(reason: .invalidConfiguration))
        }
    }

    func testRouteAndEvidenceAreCodableForSavedFrameDiagnostics() throws {
        let routes: [GarmentClassifierRoute] = [.selected(kind: .top, category: "Shirt", confidence: 0.9),
                                              .unsupported(category: "Skirt", confidence: 0.8),
                                              .uncertain(reason: .insufficientMargin)]
        for route in routes {
            XCTAssertEqual(try JSONDecoder().decode(GarmentClassifierRoute.self, from: JSONEncoder().encode(route)), route)
        }
        let scores = [score("Shirt", 0.9)]
        XCTAssertEqual(try JSONDecoder().decode([GarmentClassificationScore].self, from: JSONEncoder().encode(scores)), scores)
    }
}

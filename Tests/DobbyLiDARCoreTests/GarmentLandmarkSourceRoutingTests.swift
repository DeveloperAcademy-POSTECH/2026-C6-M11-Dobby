import XCTest
@testable import DobbyLiDARCore

final class GarmentLandmarkSourceRoutingTests: XCTestCase {
    func testOnlyRequestedOuterwearAndSweaterCategoriesSelectLuna() {
        for category in GarmentClassificationCategory.allCases {
            let scores: [GarmentClassificationScore] = [.init(label: category.rawValue, confidence: 0.9)]
            let classification = GarmentClassifierRoutingPolicy.route(scores: scores)
            let selected = GarmentLandmarkSourceRoutingPolicy.route(classification: classification, scores: scores)
            let outerwear = ["Blazer", "Jacket", "Coat", "Denim Jacket", "Sports Jacket", "Hoodie", "Sweater"].contains(category.rawValue)
            XCTAssertEqual(selected, outerwear ? .lunaOuterwear : .coreML, category.rawValue)
        }
    }

    func testTopVsBottomConfidenceCannotHideAnAmbiguousShirt() {
        let scores: [GarmentClassificationScore] = [.init(label: "Hoodie", confidence: 0.401),
            .init(label: "Shirt", confidence: 0.4), .init(label: "Jeans", confidence: 0.01)]
        let classification = GarmentClassifierRoutingPolicy.route(scores: scores)
        XCTAssertEqual(classification.category, "Hoodie")
        XCTAssertEqual(GarmentLandmarkSourceRoutingPolicy.route(classification: classification, scores: scores), .uncertainOuterwear)
        let tied: [GarmentClassificationScore] = [.init(label: "Hoodie", confidence: 0.4), .init(label: "Shirt", confidence: 0.4)]
        XCTAssertEqual(GarmentLandmarkSourceRoutingPolicy.route(classification:
            GarmentClassifierRoutingPolicy.route(scores: tied), scores: tied), .uncertainOuterwear)
    }

    func testSiblingOuterwearCategoriesDoNotCauseDuplicateOrAmbiguousRoutes() {
        for (selected, sibling, siblingConfidence) in [("Jacket", "Coat", 0.399),
            ("Jacket", "Hoodie", 0.399), ("Hoodie", "Jacket", 0.4),
            ("Hoodie", "Sweater", 0.399), ("Sweater", "Hoodie", 0.4)] {
            let scores: [GarmentClassificationScore] = [.init(label: selected, confidence: 0.4),
                .init(label: sibling, confidence: siblingConfidence), .init(label: "Shirt", confidence: 0.2)]
            XCTAssertEqual(GarmentLandmarkSourceRoutingPolicy.route(classification:
                GarmentClassifierRoutingPolicy.route(scores: scores), scores: scores), .lunaOuterwear)
        }
    }

    func testMismatchedScoresAndNonfiniteMarginsCannotAuthorizeRemote() {
        let classification = GarmentClassifierRoute.selected(kind: .top, category: "Coat", confidence: 0.9)
        XCTAssertEqual(GarmentLandmarkSourceRoutingPolicy.route(classification: classification, scores: []), .uncertainOuterwear)
        XCTAssertEqual(GarmentLandmarkSourceRoutingPolicy.route(classification: classification,
            scores: [.init(label: "Coat", confidence: 0.9)], minimumOuterwearMargin: .nan), .uncertainOuterwear)
    }

    func testRemoteIdentityOptsIntoTopContractOnlyAndKeepsElevenPhysicalSlots() {
        let version = GarmentLandmarkModelContract.lunaOuterwearVersion
        XCTAssertEqual(version, OuterwearLandmarkResponse.expectedModelVersion)
        XCTAssertTrue(GarmentLandmarkModelContract.isCurrent(version: version, kind: .top))
        XCTAssertFalse(GarmentLandmarkModelContract.isCurrent(version: version, kind: .bottoms))
        XCTAssertFalse(GarmentLandmarkModelContract.isCurrent(version: "luna-other-version", kind: .top))
        XCTAssertFalse(GarmentLandmarkModelContract.isCurrent(version: AutomaticGarmentKind.top.legacyModelVersion, kind: .top))
        XCTAssertEqual(TopLandmarkSchema.expectedKeypoints.count, 11)
        XCTAssertEqual(TopLandmarkSchema.canonicalMeasurementDefinitions.last?.landmarkIDs, ["top_length_start", "hem_center"])
    }
}

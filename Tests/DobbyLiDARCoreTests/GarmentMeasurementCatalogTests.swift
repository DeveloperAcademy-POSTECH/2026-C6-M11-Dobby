import XCTest
@testable import DobbyLiDARCore

final class GarmentMeasurementCatalogTests: XCTestCase {
    func testExistingTopDefinitionsRetainPersistedAndModelIDs() {
        for category in [GarmentCategory.top, .outerwear] {
            let definitions = category.definitions.filter { $0.id != MeasurementDefinition.testDistance.id }
            XCTAssertEqual(definitions.map(\.id), MeasurementDefinition.longSleeve.map(\.id))
            XCTAssertEqual(definitions.map(\.landmarkIDs), MeasurementDefinition.longSleeve.map(\.landmarkIDs))
        }
    }

    func testAllCategoriesCanMeasureAFreeSegmentWithoutPretendingToRecogniseGarment() {
        for category in GarmentCategory.allCases {
            let generic = category.definitions.filter { $0.id == MeasurementDefinition.testDistance.id }
            XCTAssertEqual(generic.count, 1)
            XCTAssertEqual(generic.first?.landmarkIDs, ["A", "B"])
            XCTAssertEqual(Set(category.definitions.map(\.id)).count, category.definitions.count)
            XCTAssertTrue(category.definitions.allSatisfy { $0.landmarkIDs.count == 2 && Set($0.landmarkIDs).count == 2 })
        }
        XCTAssertEqual(GarmentCategory.other.definitions.map(\.id), [MeasurementDefinition.testDistance.id])
    }

    func testReusedDefinitionIDsHaveTheSameMeaningAcrossCategories() {
        var seen: [String: MeasurementDefinition] = [:]
        for category in GarmentCategory.allCases {
            for definition in category.definitions {
                if let previous = seen[definition.id] {
                    XCTAssertEqual(previous.title, definition.title)
                    XCTAssertEqual(previous.landmarkIDs, definition.landmarkIDs)
                }
                seen[definition.id] = definition
            }
        }
        // Different reference points must not silently reuse the old top-length ID.
        XCTAssertNotEqual(seen["length"]?.landmarkIDs, seen["skirtLength"]?.landmarkIDs)
        XCTAssertNotEqual(seen["length"]?.landmarkIDs, seen["dressLength"]?.landmarkIDs)
    }

    func testEveryPresetCanResolveThroughTheTwoPointMeasurementPipeline() throws {
        for category in GarmentCategory.allCases {
            for definition in category.definitions {
                var fixture = SyntheticFixtures.scene(tilted: true)
                for index in 0..<2 { fixture.landmarks.points[index].id = definition.landmarkIDs[index] }
                let result = LiDARMeasurementEngine().measure(
                    frame: fixture.frame, landmarks: fixture.landmarks, definitions: [definition]
                )
                let value = try XCTUnwrap(result.values.first)
                XCTAssertEqual(value.id, definition.id)
                XCTAssertEqual(value.status, .valid, "\(category.id)/\(definition.id)")
                XCTAssertEqual(try XCTUnwrap(value.meters), fixture.expectedMeters, accuracy: 0.0005)
            }
        }
    }

    func testCurvedSeamPresetsAndUnknownDefinitionNeverPromiseSurfaceLength() throws {
        for id in ["frontRise", "inseam", "outseam"] {
            let definition = try XCTUnwrap(GarmentCategory.bottoms.definitions.first { $0.id == id })
            XCTAssertTrue(definition.title.contains("직선"))
            let guide = GarmentMeasurementCatalog.guide(for: id)
            XCTAssertTrue(guide.contains("직선거리"))
            XCTAssertTrue(guide.contains("봉제선"))
            XCTAssertTrue(guide.contains("평평하게"))
        }
        let unknownGuide = GarmentMeasurementCatalog.guide(for: "future-unrecognised-definition")
        XCTAssertTrue(unknownGuide.contains("곡선·둘레·표면"))
        XCTAssertTrue(unknownGuide.contains("아닙니다"))
    }

    func testCurrentTopTotalLengthGuideMatchesItsStraightPhysicalEndpoints() {
        let guide = GarmentMeasurementCatalog.guide(for: "top.totalLength")
        XCTAssertTrue(guide.contains("목 중앙"))
        XCTAssertTrue(guide.contains("밑단 중앙"))
        XCTAssertTrue(guide.contains("직선거리"))
        XCTAssertFalse(guide.contains("가로축"))
        XCTAssertFalse(guide.contains("수직"))
    }

    func testCategoryMetadataRoundTripsForSavedRecords() throws {
        let encoded = try JSONEncoder().encode(GarmentCategory.allCases)
        let decoded = try JSONDecoder().decode([GarmentCategory].self, from: encoded)
        XCTAssertEqual(decoded, GarmentCategory.allCases)
        XCTAssertEqual(Set(decoded.map(\.id)).count, decoded.count)
    }
}

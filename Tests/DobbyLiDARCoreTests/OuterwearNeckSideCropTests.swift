import XCTest
@testable import DobbyLiDARCore

final class OuterwearNeckSideCropTests: XCTestCase {
    func testExperimentalSquareCropAndEdgeClamp() throws {
        // Geometry depends on AI anchors only; no ground-truth or mask input.
        var response = OuterwearLandmarkResponse(requestID: UUID().uuidString, view: .front,
            neckStyle: .collar, points: [:])
        response.points["neck_left"] = .init(point: .init(x: 0.38, y: 0.17366013071895428), visibility: .visible)
        response.points["neck_right"] = .init(point: .init(x: 0.52, y: 0.17366013071895428), visibility: .visible)
        let crop = try XCTUnwrap(OuterwearComparisonGeometry.neckSideCrop(side: .left, response: response,
            size: .init(width: 5712, height: 4284)))
        XCTAssertEqual(crop.rect.width * 5712, 800, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.height * 4284, 800, accuracy: 0.000001)
        XCTAssertEqual(crop.rect.x * 5712, 1770, accuracy: 0.000001)
        response.points["neck_left"]?.point = .init(x: 0.001, y: 0.001)
        let edge = try XCTUnwrap(OuterwearComparisonGeometry.neckSideCrop(side: .left, response: response,
            size: .init(width: 100, height: 200)))
        XCTAssertEqual(edge.rect.x, 0)
        XCTAssertEqual(edge.rect.y, 0)
        response.points["neck_left"] = .init(point: nil, visibility: .uncertain)
        XCTAssertNil(try OuterwearComparisonGeometry.neckSideCrop(side: .left, response: response,
            size: .init(width: 100, height: 200)))
    }
}

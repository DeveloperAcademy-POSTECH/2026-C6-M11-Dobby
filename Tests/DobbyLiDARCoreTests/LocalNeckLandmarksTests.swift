import XCTest
@testable import DobbyLiDARCore

final class LocalNeckLandmarksTests: XCTestCase {
    func testLocalPeakDecodeMatchesTrainingPixelCenters() throws {
        var values = [Float](repeating: -100, count: 2 * 64 * 112)
        values[20 * 64 + 10] = 0
        values[64 * 112 + 21 * 64 + 40] = 0
        let points = try LocalNeckLandmarks.decode(values)
        XCTAssertEqual(try XCTUnwrap(points["neck_left"]).x, 10.5 / 64, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(points["neck_left"]).y, 20.5 / 112, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(points["neck_right"]).x, 40.5 / 64, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(points["neck_right"]).y, 21.5 / 112, accuracy: 1e-10)
    }

    func testInvalidShapesNaNAndReversedNecksAreRejected() {
        XCTAssertThrowsError(try LocalNeckLandmarks.decode([]))
        XCTAssertThrowsError(try LocalNeckLandmarks.decode([], width: Int.max, height: Int.max))
        var values = [Float](repeating: -100, count: 2 * 64 * 112)
        values[20 * 64 + 40] = 0; values[64 * 112 + 20 * 64 + 10] = 0
        XCTAssertThrowsError(try LocalNeckLandmarks.decode(values))
        values[0] = .nan
        XCTAssertThrowsError(try LocalNeckLandmarks.decode(values))
    }

    func testLocalDiagnosticsDecodeOldArchivesAndRoundTrip() throws {
        let diagnostic = LocalNeckLandmarkDiagnostics(inputRect: .init(x: 0.1, y: 0.2, width: 0.8, height: 0.7),
            predictedPoints: ["neck_left": .init(x: 0.4, y: 0.3)], adoptedLandmarkIDs: ["neck_left"])
        let decoded = try JSONDecoder().decode(LocalNeckLandmarkDiagnostics.self, from: JSONEncoder().encode(diagnostic))
        XCTAssertEqual(decoded.modelVersion, LocalNeckLandmarks.modelVersion)
        XCTAssertEqual(decoded.adoptedLandmarkIDs, ["neck_left"])
    }
}

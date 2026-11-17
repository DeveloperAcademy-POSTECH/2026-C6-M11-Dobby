import XCTest
@testable import Dobby

@MainActor
final class VoiceOverMeasurementTextTests: XCTestCase {
    func testSpokenPositionUsesTheVisibleCropInsteadOfFullSensorCoordinates() {
        let crop = PhotoDisplayCrop(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        XCTAssertEqual(MeasurementPointAccessibilityText.position(.init(x: 0.2, y: 0.1), crop: crop),
                       "사진 가로 0.00퍼센트, 세로 0.00퍼센트")
        XCTAssertEqual(MeasurementPointAccessibilityText.position(.init(x: 0.5, y: 0.5), crop: crop),
                       "사진 가로 50.00퍼센트, 세로 50.00퍼센트")
        XCTAssertEqual(MeasurementPointAccessibilityText.position(.init(x: 0.8, y: 0.9), crop: crop),
                       "사진 가로 100.00퍼센트, 세로 100.00퍼센트")
    }

    func testSpokenCoordinatesClampOutsidePointsAndRejectNonfinitePositions() {
        XCTAssertEqual(MeasurementPointAccessibilityText.position(.init(x: -0.3, y: 1.2)),
                       "사진 가로 0.00퍼센트, 세로 100.00퍼센트")
        XCTAssertEqual(MeasurementPointAccessibilityText.position(.init(x: .nan, y: 0.4)), "위치 확인 필요")
        XCTAssertEqual(MeasurementPointAccessibilityText.position(.init(x: 0.4, y: .infinity)), "위치 확인 필요")
        let invalidCrop = PhotoDisplayCrop(x: 0, y: 0, width: 0, height: 1)
        XCTAssertEqual(MeasurementPointAccessibilityText.position(.init(x: 0.25, y: 0.75), crop: invalidCrop),
                       "사진 가로 25.00퍼센트, 세로 75.00퍼센트")
    }

    func testSmallPointAdjustmentsRemainAudibleInsteadOfRoundingToWholePercentages() {
        let before = MeasurementPointAccessibilityText.position(.init(x: 0.5000, y: 0.5))
        let after = MeasurementPointAccessibilityText.position(.init(x: 0.5001, y: 0.5))
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(after.contains("50.01퍼센트"))
    }
}

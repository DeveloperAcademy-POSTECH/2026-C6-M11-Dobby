// Created by mason on 10/31/26.
import XCTest
@testable import Dobby

final class DetailWhiteBalanceStabilityTests: XCTestCase {
    func testRequiresContinuousStableSamplesForOneSecond() {
        var gate = DetailWhiteBalanceStability()
        for time in [0.0, 0.25, 0.5, 0.75] {
            XCTAssertFalse(gate.observe(time: time, zoom: 1, adjusting: false, gains: [2, 1, 2]))
        }
        XCTAssertTrue(gate.observe(time: 1, zoom: 1, adjusting: false, gains: [2, 1, 2]))
    }

    func testInvalidZoomAdjustmentAndSamplingGapResetSettling() {
        for (zoom, adjusting, time) in [(0.0, false, 1.0), (1.0, true, 1.0), (1.0, false, 2.0)] {
            var gate = DetailWhiteBalanceStability()
            for t in [0.0, 0.25, 0.5, 0.75] {
                _ = gate.observe(time: t, zoom: 1, adjusting: false, gains: [2, 1, 2])
            }
            XCTAssertFalse(gate.observe(time: time, zoom: zoom, adjusting: adjusting, gains: [2, 1, 2]))
            XCTAssertFalse(gate.observe(time: time + 0.25, zoom: 1, adjusting: false, gains: [2, 1, 2]))
        }
    }

    func testSlowCumulativeDriftDoesNotCountAsStable() {
        var gate = DetailWhiteBalanceStability()
        for i in 0...8 {
            XCTAssertFalse(gate.observe(time: Double(i) * 0.25, zoom: 1, adjusting: false,
                gains: [2 + Float(i) * 0.015, 1, 2]))
        }
    }

    func testInvalidGainsCannotTriggerLock() {
        let cases: [[Float]] = [[], [2, 1], [2, 0, 2], [.nan, 1, 2], [2, 1, .infinity]]
        for gains in cases {
            var gate = DetailWhiteBalanceStability()
            for i in 0...8 {
                XCTAssertFalse(gate.observe(time: Double(i) * 0.25, zoom: 1, adjusting: false, gains: gains))
            }
        }
    }
}

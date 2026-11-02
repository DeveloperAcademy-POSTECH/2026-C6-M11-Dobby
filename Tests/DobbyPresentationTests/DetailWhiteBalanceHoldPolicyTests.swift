// Created by mason on 11/1/26.
import XCTest
@testable import Dobby

final class DetailWhiteBalanceHoldPolicyTests: XCTestCase {
    func testStableSceneWaitsForInteractionAndConfirmation() throws {
        var policy = settled()
        XCTAssertEqual(policy.state, .automatic)
        let revision = try XCTUnwrap(policy.requestLock(at: 3))
        XCTAssertEqual(policy.state, .locking)
        XCTAssertNil(policy.requestLock(at: 3.1))
        XCTAssertTrue(policy.confirm(revision: revision))
        XCTAssertEqual(policy.state, .held)
        policy.observe(at: 4, zoom: 2, adjusting: true, gains: [3, 1, 1.5])
        XCTAssertEqual(policy.state, .held, "줌으로 장면이 바뀌어도 기준을 다시 잡지 않는다")
        XCTAssertNil(policy.requestLock(at: 4))
    }

    func testUnstableOrStaleSceneKeepsAutomaticMode() {
        var stale = settled()
        XCTAssertNil(stale.requestLock(at: 3.6))
        XCTAssertEqual(stale.state, .automatic)
        var adjusting = settled()
        adjusting.observe(at: 3.1, zoom: 1, adjusting: true, gains: [2, 1, 2])
        XCTAssertNil(adjusting.requestLock(at: 3.1))
        XCTAssertEqual(adjusting.state, .automatic)
    }

    func testWarmupMustFinishEvenIfSamplesAreStable() {
        var policy = DetailWhiteBalanceHoldPolicy()
        policy.reset(at: 0)
        for i in 0...4 {
            policy.observe(at: Double(i) / 4, zoom: 1, adjusting: false, gains: [2, 1, 2])
        }
        XCTAssertNil(policy.requestLock(at: 1))
    }

    func testRetryCanSettleAfterEarlierZoomInteraction() throws {
        var policy = settled(zoom: 2)
        XCTAssertNotNil(policy.requestLock(at: 3))
    }

    func testExitOrInterruptionInvalidatesPendingConfirmation() throws {
        var policy = settled()
        let old = try XCTUnwrap(policy.requestLock(at: 3))
        policy.reset(at: 4)
        XCTAssertFalse(policy.confirm(revision: old))
        XCTAssertEqual(policy.state, .automatic)
        XCTAssertNil(policy.requestLock(at: 7), "이전 세션의 안정화 기록을 재사용하지 않는다")
        for i in 0...4 {
            policy.observe(at: 7 + Double(i) / 4, zoom: 1, adjusting: false, gains: [1.5, 1, 2.5])
        }
        let new = try XCTUnwrap(policy.requestLock(at: 8))
        XCTAssertNotEqual(old, new)
        XCTAssertTrue(policy.confirm(revision: new))
    }

    private func settled(zoom: Double = 1) -> DetailWhiteBalanceHoldPolicy {
        var policy = DetailWhiteBalanceHoldPolicy()
        policy.reset(at: 0)
        for i in 0...4 {
            policy.observe(at: 2 + Double(i) / 4, zoom: zoom, adjusting: false, gains: [2, 1, 2])
        }
        return policy
    }
}

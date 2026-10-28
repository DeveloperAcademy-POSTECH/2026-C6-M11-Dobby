import XCTest
@testable import DobbyLiDARCore

final class MultiCameraTimestampJoinTests: XCTestCase {
    private typealias Join = MultiCameraTimestampJoin<String, String>
    private let skew: TimeInterval = 1.0 / 60

    func testAtomicPairThenSeparateUltraCallbackMatchesPhaseOffset() throws {
        let id = UUID()
        var join = Join(sessionID: id, maxSkew: skew)
        XCTAssertNil(join.insertPrimary(value: "wide+depth", timestamp: 10, endTimestamp: 10.001, sessionID: id))
        let result = try XCTUnwrap(join.insertSecondary(value: "ultra", timestamp: 10.01, sessionID: id))
        XCTAssertEqual(result.primary, "wide+depth")
        XCTAssertEqual(result.secondary, "ultra")
        XCTAssertEqual(result.primaryTimestamp, 10)
        XCTAssertEqual(result.primaryEndTimestamp, 10.001)
        XCTAssertEqual(result.secondaryTimestamp, 10.01)
    }

    func testUltraBeforeAtomicPairMatchesWithoutRequiringSameCallback() throws {
        let id = UUID()
        var join = Join(sessionID: id, maxSkew: skew)
        XCTAssertNil(join.insertSecondary(value: "ultra", timestamp: 2, sessionID: id))
        let result = try XCTUnwrap(join.insertPrimary(value: "pair", timestamp: 2.005,
                                                      endTimestamp: 2.006, sessionID: id))
        XCTAssertEqual(result.secondary, "ultra")
    }

    func testBatchPrefersCurrentExactUltraOverBufferedOlderUltra() throws {
        let id = UUID()
        var join = Join(sessionID: id, maxSkew: skew)
        XCTAssertNil(join.insertSecondary(value: "old", timestamp: 1, sessionID: id))
        let result = try XCTUnwrap(join.insert(
            primary: .init(value: "pair", timestamp: 1.01, endTimestamp: 1.01),
            secondary: .init(value: "current", timestamp: 1.01), sessionID: id))
        XCTAssertEqual(result.secondary, "current")
    }

    func testNewestEligiblePrimaryWinsAndOlderPairCannotPublishLater() throws {
        let id = UUID()
        var join = Join(sessionID: id, maxSkew: skew)
        XCTAssertNil(join.insertPrimary(value: "old", timestamp: 1, endTimestamp: 1, sessionID: id))
        XCTAssertNil(join.insertPrimary(value: "new", timestamp: 1.008, endTimestamp: 1.008, sessionID: id))
        let result = try XCTUnwrap(join.insertSecondary(value: "ultra", timestamp: 1.004, sessionID: id))
        XCTAssertEqual(result.primary, "new")
        XCTAssertNil(join.insertSecondary(value: "later", timestamp: 1.009, sessionID: id))
        XCTAssertNil(join.insertPrimary(value: "old replay", timestamp: 1, endTimestamp: 1, sessionID: id))
    }

    func testTotalSpanIncludesBothWideAndDepthTimesRatherThanMidpointOnly() {
        let id = UUID()
        var join = Join(sessionID: id, maxSkew: skew)
        XCTAssertNil(join.insertPrimary(value: "pair", timestamp: 1, endTimestamp: 1.015, sessionID: id))
        // Ultra is close to the midpoint, but the complete three-sample span is 20 ms.
        XCTAssertNil(join.insertSecondary(value: "too late", timestamp: 1.02, sessionID: id))
    }

    func testExactSkewBoundaryAcceptedAndNextRepresentableValueRejected() throws {
        let id = UUID()
        var accepted = Join(sessionID: id, maxSkew: skew)
        XCTAssertNil(accepted.insertPrimary(value: "pair", timestamp: 0, endTimestamp: 0, sessionID: id))
        XCTAssertNotNil(accepted.insertSecondary(value: "boundary", timestamp: skew, sessionID: id))
        var rejected = Join(sessionID: id, maxSkew: skew)
        XCTAssertNil(rejected.insertPrimary(value: "pair", timestamp: 0, endTimestamp: 0, sessionID: id))
        XCTAssertNil(rejected.insertSecondary(value: "outside", timestamp: skew.nextUp, sessionID: id))
    }

    func testEveryUltraAndAtomicPairIsConsumedAtMostOnce() throws {
        let id = UUID()
        var join = Join(sessionID: id, maxSkew: skew)
        XCTAssertNotNil(join.insert(primary: .init(value: "pair1", timestamp: 1, endTimestamp: 1),
                                   secondary: .init(value: "ultra1", timestamp: 1), sessionID: id))
        XCTAssertNil(join.insertPrimary(value: "pair2", timestamp: 1.005, endTimestamp: 1.005, sessionID: id))
        XCTAssertNil(join.insertSecondary(value: "ultra1 replay", timestamp: 1, sessionID: id))
        let next = try XCTUnwrap(join.insertSecondary(value: "ultra2", timestamp: 1.006, sessionID: id))
        XCTAssertEqual(next.primary, "pair2")
        XCTAssertEqual(next.secondary, "ultra2")
        XCTAssertNil(join.insert(primary: nil, secondary: nil, sessionID: id))
    }

    func testBuffersRetainAtMostThreeUnmatchedMembers() throws {
        let id = UUID()
        var primaries = Join(sessionID: id, maxSkew: skew)
        for index in 0..<4 {
            let time = 1 + Double(index) * 0.02
            XCTAssertNil(primaries.insertPrimary(value: "pair\(index)", timestamp: time,
                                                 endTimestamp: time, sessionID: id))
        }
        XCTAssertNil(primaries.insertSecondary(value: "evicted pair", timestamp: 1, sessionID: id))
        let newest = try XCTUnwrap(primaries.insertSecondary(value: "current", timestamp: 1.06, sessionID: id))
        XCTAssertEqual(newest.primary, "pair3")

        var secondaries = Join(sessionID: id, maxSkew: skew)
        for index in 0..<4 {
            XCTAssertNil(secondaries.insertSecondary(value: "ultra\(index)", timestamp: 1 + Double(index) * 0.02,
                                                      sessionID: id))
        }
        XCTAssertNil(secondaries.insertPrimary(value: "evicted ultra", timestamp: 1, endTimestamp: 1, sessionID: id))
        let current = try XCTUnwrap(secondaries.insertPrimary(value: "current", timestamp: 1.06,
                                                               endTimestamp: 1.06, sessionID: id))
        XCTAssertEqual(current.secondary, "ultra3")
    }

    func testUnbegunGenerationCannotJoinOrErasePendingCurrentPair() throws {
        let id = UUID(), unrelated = UUID()
        var join = Join(sessionID: id, maxSkew: skew)
        XCTAssertNil(join.insertPrimary(value: "current", timestamp: 1, endTimestamp: 1, sessionID: id))
        XCTAssertNil(join.insertSecondary(value: "other session", timestamp: 1, sessionID: unrelated))
        let result = try XCTUnwrap(join.insertSecondary(value: "current ultra", timestamp: 1, sessionID: id))
        XCTAssertEqual(result.primary, "current")
        XCTAssertEqual(join.sessionID, id)
    }

    func testBeginClearsBuffersAndWatermarksAndRejectsOldCallbacks() throws {
        let old = UUID(), current = UUID()
        var join = Join(sessionID: old, maxSkew: skew)
        XCTAssertNil(join.insertPrimary(value: "old pair", timestamp: 100, endTimestamp: 100, sessionID: old))
        join.begin(sessionID: current)
        XCTAssertNil(join.insertSecondary(value: "old ultra", timestamp: 100, sessionID: old))
        XCTAssertNil(join.insertSecondary(value: "new ultra", timestamp: 1, sessionID: current))
        let result = try XCTUnwrap(join.insertPrimary(value: "new pair", timestamp: 1, endTimestamp: 1, sessionID: current))
        XCTAssertEqual(result.primary, "new pair")
        XCTAssertEqual(result.secondary, "new ultra")
    }

    func testMalformedTimestampsDoNotPoisonSubsequentValidSamples() throws {
        let id = UUID()
        var join = Join(sessionID: id, maxSkew: skew)
        for time in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertNil(join.insertPrimary(value: "invalid", timestamp: time, endTimestamp: time, sessionID: id))
            XCTAssertNil(join.insertSecondary(value: "invalid", timestamp: time, sessionID: id))
        }
        XCTAssertNil(join.insertPrimary(value: "reversed", timestamp: 1, endTimestamp: 0.99, sessionID: id))
        XCTAssertNil(join.insertPrimary(value: "wide/depth unsynchronized", timestamp: 1,
                                        endTimestamp: 1.1, sessionID: id))
        XCTAssertNotNil(join.insert(primary: .init(value: "valid", timestamp: 1, endTimestamp: 1),
                                   secondary: .init(value: "valid", timestamp: 1), sessionID: id))
    }

    func testStaleAndReorderedCallbacksCannotReviveExpiredSources() throws {
        let id = UUID()
        var join = Join(sessionID: id, maxSkew: skew)
        XCTAssertNil(join.insertPrimary(value: "stale pair", timestamp: 1, endTimestamp: 1, sessionID: id))
        XCTAssertNil(join.insertSecondary(value: "advanced ultra", timestamp: 2, sessionID: id))
        XCTAssertNil(join.insertSecondary(value: "late old ultra", timestamp: 1, sessionID: id))
        let result = try XCTUnwrap(join.insertPrimary(value: "current pair", timestamp: 2, endTimestamp: 2, sessionID: id))
        XCTAssertEqual(result.primary, "current pair")
        XCTAssertEqual(result.secondary, "advanced ultra")
        XCTAssertNil(join.insertPrimary(value: "late old pair", timestamp: 1, endTimestamp: 1, sessionID: id))
    }
}

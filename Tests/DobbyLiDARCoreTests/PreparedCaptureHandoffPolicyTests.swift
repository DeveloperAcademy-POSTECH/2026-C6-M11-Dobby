import XCTest
@testable import DobbyLiDARCore

final class PreparedCaptureHandoffPolicyTests: XCTestCase {
    private func fixture() -> (PreparedCaptureHandoffIdentity, LiveCaptureReadiness, PreparedCaptureHandoffObservation) {
        let identity = PreparedCaptureHandoffIdentity(sessionID: UUID(), frameID: UUID(), analysisEpoch: UUID(),
            timestamp: 10, orientation: .right, garmentKind: .top, modelVersion: AutomaticGarmentKind.top.modelVersion)
        let readiness = LiveCaptureReadiness(state: .ready, timestamp: identity.timestamp,
            silhouette: .init(size: .init(width: 1, height: 1), values: [1]),
            recognitionModelVersion: identity.modelVersion, garmentKind: identity.garmentKind,
            imageOrientation: identity.orientation, analysisEpoch: identity.analysisEpoch)
        let observation = PreparedCaptureHandoffObservation(sessionID: identity.sessionID, readiness: readiness,
            orientation: identity.orientation, currentFrameTimestamp: 10.4, cameraObservationTimestamp: 10.4,
            trackingStable: true, hasDepth: true, freshnessExpired: false,
            translationSpeedMetersPerSecond: 0.01, angularSpeedRadiansPerSecond: 0.02)
        return (identity, readiness, observation)
    }

    func testAcceptedRecognizedFrameCanBeConsumedExactlyOnce() {
        let (identity, readiness, observation) = fixture()
        var policy = PreparedCaptureHandoffPolicy()
        XCTAssertTrue(policy.offer(identity, readiness: readiness))
        XCTAssertTrue(policy.consume(identity, observation: observation))
        XCTAssertFalse(policy.consume(identity, observation: observation))
        XCTAssertFalse(policy.offer(identity, readiness: readiness), "Delayed callback cannot offer the consumed RGB again")
    }

    func testCancellationOrLifecycleInvalidationCannotReviveTheTicket() {
        let (identity, readiness, observation) = fixture()
        var policy = PreparedCaptureHandoffPolicy()
        XCTAssertTrue(policy.offer(identity, readiness: readiness))
        policy.invalidate()
        XCTAssertFalse(policy.consume(identity, observation: observation))
        XCTAssertFalse(policy.offer(identity, readiness: readiness))
    }

    func testAnotherFrameWithIdenticalKindCannotUseTheAcceptedPoints() {
        let (identity, readiness, observation) = fixture()
        var other = identity
        other.frameID = UUID()
        var policy = PreparedCaptureHandoffPolicy()
        XCTAssertTrue(policy.offer(identity, readiness: readiness))
        XCTAssertFalse(policy.consume(other, observation: observation))
        XCTAssertFalse(policy.consume(identity, observation: observation), "A failed consumption also invalidates the slot")
    }

    func testCameraRestartAndOrientationOrAnalysisEpochChangeInvalidateHandoff() {
        let (identity, readiness, observation) = fixture()
        let changes: [(String, (inout PreparedCaptureHandoffObservation) -> Void)] = [
            ("session", { $0.sessionID = UUID() }),
            ("orientation", { $0.orientation = .left }),
            ("epoch", { $0.readiness.analysisEpoch = UUID() }),
            ("ready orientation", { $0.readiness.imageOrientation = .up })
        ]
        for (name, change) in changes {
            var policy = PreparedCaptureHandoffPolicy(), current = observation
            XCTAssertTrue(policy.offer(identity, readiness: readiness))
            change(&current)
            XCTAssertFalse(policy.consume(identity, observation: current), name)
        }
    }

    func testNewerReadyKindModelOrFrameTimestampCannotReuseEarlierTicket() {
        let (identity, readiness, observation) = fixture()
        let changes: [(String, (inout PreparedCaptureHandoffObservation) -> Void)] = [
            ("kind", { $0.readiness.garmentKind = .bottoms }),
            ("model", { $0.readiness.recognitionModelVersion = "different-model" }),
            ("timestamp", { $0.readiness.timestamp += 0.35 }),
            ("not ready", { $0.readiness.state = .searching })
        ]
        for (name, change) in changes {
            var policy = PreparedCaptureHandoffPolicy(), current = observation
            XCTAssertTrue(policy.offer(identity, readiness: readiness))
            change(&current)
            XCTAssertFalse(policy.consume(identity, observation: current), name)
        }
    }

    func testOldFutureOrExpiredSourceFramesCannotBecomeFreshAtTap() {
        let (identity, readiness, observation) = fixture()
        let changes: [(String, (inout PreparedCaptureHandoffObservation) -> Void)] = [
            ("two-second limit", { $0.currentFrameTimestamp = 12.001; $0.cameraObservationTimestamp = 12.001 }),
            ("future result", { $0.currentFrameTimestamp = 9.99; $0.cameraObservationTimestamp = 9.99 }),
            ("arrival deadline", { $0.freshnessExpired = true }),
            ("camera silence", { $0.cameraObservationTimestamp = 9.39 })
        ]
        for (name, change) in changes {
            var policy = PreparedCaptureHandoffPolicy(), current = observation
            XCTAssertTrue(policy.offer(identity, readiness: readiness))
            change(&current)
            XCTAssertFalse(policy.consume(identity, observation: current), name)
        }
    }

    func testCurrentMotionTrackingAndDepthMustRemainUsable() {
        let (identity, readiness, observation) = fixture()
        let changes: [(String, (inout PreparedCaptureHandoffObservation) -> Void)] = [
            ("tracking", { $0.trackingStable = false }),
            ("depth", { $0.hasDepth = false }),
            ("translation", { $0.translationSpeedMetersPerSecond = CaptureFrameQuality.maximumTranslationSpeed }),
            ("rotation", { $0.angularSpeedRadiansPerSecond = CaptureFrameQuality.maximumAngularSpeed }),
            ("unknown motion", { $0.translationSpeedMetersPerSecond = nil }),
            ("invalid motion", { $0.angularSpeedRadiansPerSecond = .nan })
        ]
        for (name, change) in changes {
            var policy = PreparedCaptureHandoffPolicy(), current = observation
            XCTAssertTrue(policy.offer(identity, readiness: readiness))
            change(&current)
            XCTAssertFalse(policy.consume(identity, observation: current), name)
        }
    }

    func testRecognitionOnlyOrWrongModelIsNeverOfferedAsPreparedMeasurement() {
        let (identity, readiness, _) = fixture()
        var policy = PreparedCaptureHandoffPolicy(), recognitionOnly = readiness
        recognitionOnly.state = .analyzing
        XCTAssertFalse(policy.offer(identity, readiness: recognitionOnly))
        var unrecognized = readiness
        unrecognized.silhouette = nil
        XCTAssertFalse(policy.offer(identity, readiness: unrecognized))
        var incorrect = identity
        incorrect.modelVersion = AutomaticGarmentKind.bottoms.modelVersion
        XCTAssertFalse(policy.offer(incorrect, readiness: readiness))
    }

    func testFreshReadyFrameCanBeAcceptedAfterEarlierFrameWasConsumed() {
        let (identity, readiness, observation) = fixture()
        var policy = PreparedCaptureHandoffPolicy()
        XCTAssertTrue(policy.offer(identity, readiness: readiness))
        XCTAssertTrue(policy.consume(identity, observation: observation))
        var next = identity
        next.frameID = UUID(); next.timestamp += 0.35
        var nextReadiness = readiness
        nextReadiness.timestamp = next.timestamp
        var current = observation
        current.readiness = nextReadiness
        XCTAssertTrue(policy.offer(next, readiness: nextReadiness))
        XCTAssertTrue(policy.consume(next, observation: current))
        XCTAssertFalse(policy.offer(identity, readiness: readiness), "A late earlier frame must stay retired after a newer consumption")
    }

    func testSameEpochDuplicateTimestampCannotOfferDifferentFrameAsNewEvidence() {
        let (identity, readiness, observation) = fixture()
        var policy = PreparedCaptureHandoffPolicy()
        XCTAssertTrue(policy.offer(identity, readiness: readiness))
        XCTAssertTrue(policy.consume(identity, observation: observation))
        var duplicate = identity
        duplicate.frameID = UUID()
        XCTAssertFalse(policy.offer(duplicate, readiness: readiness))
    }
}

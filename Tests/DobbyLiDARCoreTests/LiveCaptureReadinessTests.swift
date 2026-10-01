import XCTest
@testable import DobbyLiDARCore

final class LiveCaptureReadinessTests: XCTestCase {
    private func evidence(timestamp: TimeInterval = 1, xOffset: Int = 0) -> LiveCaptureEvidence {
        let size = PixelSize(width: 100, height: 80)
        var mask = GarmentMask(size: size, values: .init(repeating: 0, count: 8_000))
        for y in 16..<64 {
            for x in (20 + xOffset)..<(80 + xOffset) { mask.values[y * 100 + x] = 1 }
        }
        return LiveCaptureEvidence(
            timestamp: timestamp, candidateCount: 1,
            bounds: .init(x: Double(20 + xOffset) / 100, y: 0.2, width: 0.6, height: 0.6),
            mask: mask, imageSize: .init(width: 1_000, height: 800),
            depth: .init(size: size, values: .init(repeating: 1.2, count: 8_000),
                         confidence: .init(repeating: 2, count: 8_000)),
            trackingStable: true, recognitionModelVersion: "analytic-garment-test"
        )
    }


    func testGarmentKindChangeNeedsNewStableObservations() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        observation.garmentKind = .top
        XCTAssertEqual(evaluator.evaluate(observation).state, .steadying)
        observation.timestamp = 1.5
        XCTAssertEqual(evaluator.evaluate(observation).state, .ready)
        // Even identical silhouette and depth must not carry readiness to pants.
        observation.timestamp = 2
        observation.garmentKind = .bottoms
        let switched = evaluator.evaluate(observation)
        XCTAssertEqual(switched.state, .steadying)
        XCTAssertEqual(switched.garmentKind, .bottoms)
        observation.timestamp = 2.5
        XCTAssertEqual(evaluator.evaluate(observation).state, .ready)
    }

    func testModelVersionChangeAndClassificationLossResetReadiness() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        observation.garmentKind = .top
        _ = evaluator.evaluate(observation)
        observation.timestamp = 1.5
        XCTAssertEqual(evaluator.evaluate(observation).state, .ready)
        observation.timestamp = 2
        observation.recognitionModelVersion = "different-model"
        XCTAssertEqual(evaluator.evaluate(observation).state, .steadying)
        observation.timestamp = 2.5
        observation.recognitionModelVersion = nil
        observation.garmentKind = nil
        let missing = evaluator.evaluate(observation)
        XCTAssertEqual(missing.state, .searching)
        XCTAssertNil(missing.garmentKind)
        XCTAssertFalse(missing.garmentRecognized)
        observation.timestamp = 3
        observation.recognitionModelVersion = "different-model"
        observation.garmentKind = .top
        XCTAssertEqual(evaluator.evaluate(observation).state, .steadying)
    }

    func testReadyNeedsConsecutiveFreshObservationsAndStableDuration() {
        var evaluator = LiveReadinessEvaluator()
        XCTAssertEqual(evaluator.evaluate(evidence()).state, .steadying)
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 1.1)).state, .steadying)
        let result = evaluator.evaluate(evidence(timestamp: 1.4))
        XCTAssertEqual(result.state, .ready)
        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.depthCoverage, 1)
        XCTAssertEqual(result.highConfidenceCoverage, 1)
        XCTAssertEqual(result.boundaryCoverage, 1)
        XCTAssertEqual(result.medianDepthMeters ?? 0, 1.2, accuracy: 0.0001)
        XCTAssertTrue(result.garmentRecognized)
        XCTAssertEqual(result.silhouette, evidence().mask)
    }

    func testUnclassifiedForegroundNeverPublishesGarmentSuccessOrSilhouette() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        observation.recognitionModelVersion = nil
        XCTAssertEqual(evaluator.evaluate(observation).state, .searching)
        observation.timestamp = 2
        let result = evaluator.evaluate(observation)
        XCTAssertFalse(result.isReady)
        XCTAssertFalse(result.garmentRecognized)
        XCTAssertNil(result.silhouette)
    }

    func testUnsupportedClassificationRemovesPreviousReadyKindAndSilhouette() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        observation.garmentKind = .top
        _ = evaluator.evaluate(observation)
        observation.timestamp = 1.5
        XCTAssertEqual(evaluator.evaluate(observation).state, .ready)
        observation.timestamp = 2
        observation.unsupportedGarment = true
        // Even stale semantic fields must not revive a supported garment.
        let result = evaluator.evaluate(observation)
        XCTAssertEqual(result.state, .unsupportedGarment)
        XCTAssertFalse(result.isReady)
        XCTAssertNil(result.garmentKind)
        XCTAssertNil(result.silhouette)
        XCTAssertFalse(result.garmentRecognized)
        observation.timestamp = 2.5
        observation.unsupportedGarment = false
        XCTAssertEqual(evaluator.evaluate(observation).state, .steadying)
    }

    func testNewNoDetectionDropsPreviouslyRecognizedSilhouette() {
        var evaluator = LiveReadinessEvaluator()
        _ = evaluator.evaluate(evidence())
        XCTAssertTrue(evaluator.evaluate(evidence(timestamp: 1.5)).garmentRecognized)
        var missing = evidence(timestamp: 2)
        missing.candidateCount = 0
        missing.recognitionModelVersion = nil
        let result = evaluator.evaluate(missing)
        XCTAssertFalse(result.garmentRecognized)
        XCTAssertNil(result.silhouette)
    }

    func testDepthFailureKeepsRecognizedSilhouetteWithoutClaimingReady() {
        var evaluator = LiveReadinessEvaluator()
        var missingDepth = evidence()
        missingDepth.depth = nil
        let result = evaluator.evaluate(missingDepth)
        XCTAssertEqual(result.state, .noDepth)
        XCTAssertTrue(result.garmentRecognized)
        XCTAssertFalse(result.isReady)
        XCTAssertEqual(result.silhouette, missingDepth.mask)
    }

    func testNoObjectOrEmptyMaskCannotBeReady() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        observation.candidateCount = 0
        observation.bounds = nil
        observation.mask = nil
        XCTAssertEqual(evaluator.evaluate(observation).state, .searching)
        observation = evidence(timestamp: 2)
        observation.mask?.values = .init(repeating: 0, count: 8_000)
        XCTAssertEqual(evaluator.evaluate(observation).state, .searching)
    }

    func testMultipleObjectsAndVisionFailureAreExplicit() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        observation.candidateCount = 2
        XCTAssertEqual(evaluator.evaluate(observation).state, .multipleObjects)
        observation.timestamp = 2
        observation.analysisFailed = true
        observation.candidateCount = 0
        XCTAssertEqual(evaluator.evaluate(observation).state, .analysisFailed)
    }

    func testMalformedOrMisregisteredMasksAreRejected() {
        var candidates = [LiveCaptureEvidence]()
        var truncated = evidence()
        truncated.mask?.values.removeLast()
        candidates.append(truncated)
        var aspectMismatch = evidence()
        aspectMismatch.mask?.size = .init(width: 80, height: 100)
        candidates.append(aspectMismatch)
        var nonbinary = evidence()
        nonbinary.mask?.values[2_020] = 255
        candidates.append(nonbinary)
        var mismatchedBounds = evidence()
        mismatchedBounds.bounds = .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        candidates.append(mismatchedBounds)
        var missing = evidence()
        missing.mask = nil
        candidates.append(missing)
        for observation in candidates {
            var evaluator = LiveReadinessEvaluator()
            XCTAssertEqual(evaluator.evaluate(observation).state, .analysisFailed)
        }
    }

    func testCroppedAndSmallObjectsAreNotReady() {
        var evaluator = LiveReadinessEvaluator()
        XCTAssertEqual(evaluator.evaluate(evidence(xOffset: -20)).state, .clipped)
        var small = evidence(timestamp: 2)
        small.bounds = .init(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        small.mask?.values = .init(repeating: 0, count: 8_000)
        for y in 32..<40 { for x in 40..<50 { small.mask?.values[y * 100 + x] = 1 } }
        XCTAssertEqual(evaluator.evaluate(small).state, .tooSmall)
    }

    func testMissingAndMalformedDepthAreNotUsable() {
        var candidates = [LiveCaptureEvidence]()
        var missing = evidence()
        missing.depth = nil
        candidates.append(missing)
        var malformed = evidence()
        malformed.depth?.values.removeLast()
        candidates.append(malformed)
        var wrongAspect = evidence()
        wrongAspect.depth?.size = .init(width: 80, height: 100)
        candidates.append(wrongAspect)
        var wrongConfidence = evidence()
        wrongConfidence.depth?.confidence = [2]
        candidates.append(wrongConfidence)
        var illegalConfidence = evidence()
        illegalConfidence.depth?.confidence?[2_020] = 3
        candidates.append(illegalConfidence)
        for observation in candidates {
            var evaluator = LiveReadinessEvaluator()
            let result = evaluator.evaluate(observation)
            XCTAssertEqual(result.state, .noDepth)
            XCTAssertNil(result.depthCoverage)
        }
    }

    func testZeroAndNonfiniteDepthDoNotContributeCoverage() {
        for depthValue: Float in [0, -.infinity, .infinity, .nan, -1, 0.1, 3.1] {
            var evaluator = LiveReadinessEvaluator()
            var observation = evidence()
            observation.depth?.values = .init(repeating: depthValue, count: 8_000)
            let result = evaluator.evaluate(observation)
            XCTAssertEqual(result.state, .lowDepth)
            XCTAssertEqual(result.depthCoverage, 0)
            XCTAssertEqual(result.highConfidenceCoverage, 0)
            XCTAssertNil(result.medianDepthMeters)
        }
    }

    func testUnknownConfidenceNeverTurnsGreen() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        observation.depth?.confidence = nil
        XCTAssertEqual(evaluator.evaluate(observation).state, .lowDepth)
        observation.timestamp = 2
        let result = evaluator.evaluate(observation)
        XCTAssertEqual(result.state, .lowDepth)
        XCTAssertEqual(result.depthCoverage, 1)
        XCTAssertNil(result.highConfidenceCoverage)
        XCTAssertNil(result.boundaryCoverage)
    }

    func testConfidenceUsesAllForegroundSamplesAsDenominator() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        // Half of this foreground has high confidence. Background confidence is irrelevant.
        for y in 16..<64 { for x in 20..<50 { observation.depth?.confidence?[y * 100 + x] = 1 } }
        let result = evaluator.evaluate(observation)
        XCTAssertEqual(result.state, .lowDepth)
        XCTAssertEqual(result.depthCoverage, 1)
        XCTAssertEqual(result.highConfidenceCoverage, 0.5)
        XCTAssertEqual(result.boundaryCoverage, 1)
    }

    func testPartialDepthCoverageCannotBeHiddenByValidBackground() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        for y in 16..<64 { for x in 20..<50 { observation.depth?.values[y * 100 + x] = 0 } }
        let result = evaluator.evaluate(observation)
        XCTAssertEqual(result.state, .lowDepth)
        XCTAssertEqual(result.depthCoverage, 0.5)
        XCTAssertEqual(result.highConfidenceCoverage, 0.5)
    }

    func testPoorBoundaryBlocksReadyEvenWithGoodInterior() throws {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        for y in 16..<64 {
            for x in 20..<80 where y == 16 || y == 63 || x == 20 || x == 79 {
                observation.depth?.values[y * 100 + x] = 0
            }
        }
        let result = evaluator.evaluate(observation)
        XCTAssertGreaterThan(try XCTUnwrap(result.depthCoverage), 0.85)
        XCTAssertGreaterThan(try XCTUnwrap(result.highConfidenceCoverage), 0.60)
        XCTAssertEqual(result.boundaryCoverage, 0)
        XCTAssertEqual(result.state, .lowDepth)
    }

    func testSparseLowResolutionROINeedsEnoughSamples() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        observation.depth = .init(size: .init(width: 5, height: 4), values: .init(repeating: 1, count: 20),
                                  confidence: .init(repeating: 2, count: 20))
        XCTAssertEqual(evaluator.evaluate(observation).state, .lowDepth)
    }

    func testSlopingSurfaceIsAllowedWithoutGlobalDepthVarianceGate() {
        var evaluator = LiveReadinessEvaluator()
        var observation = evidence()
        for y in 0..<80 { for x in 0..<100 { observation.depth?.values[y * 100 + x] = 0.8 + Float(x) * 0.012 } }
        XCTAssertEqual(evaluator.evaluate(observation).state, .steadying)
        observation.timestamp = 1.5
        XCTAssertEqual(evaluator.evaluate(observation).state, .ready)
    }

    func testLossOfTrackingImmediatelyRemovesReadyAndRestartsSettling() {
        var evaluator = LiveReadinessEvaluator()
        _ = evaluator.evaluate(evidence())
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 1.5)).state, .ready)
        var moving = evidence(timestamp: 1.6)
        moving.trackingStable = false
        XCTAssertEqual(evaluator.evaluate(moving).state, .unstable)
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 1.7)).state, .steadying)
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 2.1)).state, .ready)
    }

    func testChangedCandidateOrDepthRestartsSettling() {
        var evaluator = LiveReadinessEvaluator()
        _ = evaluator.evaluate(evidence())
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 1.5)).state, .ready)
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 1.6, xOffset: 5)).state, .steadying)
        var movedDepth = evidence(timestamp: 2, xOffset: 5)
        movedDepth.depth?.values = .init(repeating: 1.4, count: 8_000)
        XCTAssertEqual(evaluator.evaluate(movedDepth).state, .steadying)
        movedDepth.timestamp = 2.5
        XCTAssertEqual(evaluator.evaluate(movedDepth).state, .ready)
    }

    func testStaleEvidenceAndExplicitResetRequireNewStableSequence() {
        var evaluator = LiveReadinessEvaluator()
        _ = evaluator.evaluate(evidence())
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 1.5)).state, .ready)
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 4)).state, .steadying)
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 4.5)).state, .ready)
        evaluator.reset()
        XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 4.6)).state, .steadying)
    }

    func testDuplicateOrReorderedTimestampsCannotAdvanceReadiness() {
        for duplicateTimestamp in [1.5, 1.4] {
            var evaluator = LiveReadinessEvaluator()
            _ = evaluator.evaluate(evidence())
            XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 1.5)).state, .ready)
            XCTAssertEqual(evaluator.evaluate(evidence(timestamp: duplicateTimestamp)).state, .analyzing)
            XCTAssertEqual(evaluator.evaluate(evidence(timestamp: 2)).state, .steadying)
        }
    }

    func testMalformedEvidenceOrOptionsCannotProduceReady() {
        var malformed = [LiveCaptureEvidence]()
        var nonfinite = evidence()
        nonfinite.timestamp = .nan
        malformed.append(nonfinite)
        var negativeCount = evidence()
        negativeCount.candidateCount = -1
        malformed.append(negativeCount)
        var invalidSize = evidence()
        invalidSize.imageSize = .init(width: 0, height: 0)
        malformed.append(invalidSize)
        var invalidBounds = evidence()
        invalidBounds.bounds?.width = .infinity
        malformed.append(invalidBounds)
        for observation in malformed {
            var evaluator = LiveReadinessEvaluator()
            XCTAssertEqual(evaluator.evaluate(observation).state, .analysisFailed)
        }
        var config = LiveReadinessConfiguration()
        config.minimumConsecutiveObservations = 1
        var evaluator = LiveReadinessEvaluator(configuration: config)
        XCTAssertEqual(evaluator.evaluate(evidence()).state, .analysisFailed)
    }

    func testConfigurationAllowsExplicitProductThresholdTuning() {
        var config = LiveReadinessConfiguration()
        config.minimumHighConfidenceCoverage = 0.4
        var evaluator = LiveReadinessEvaluator(configuration: config)
        var observation = evidence()
        for y in 16..<64 { for x in 20..<50 { observation.depth?.confidence?[y * 100 + x] = 1 } }
        XCTAssertEqual(evaluator.evaluate(observation).state, .steadying)
        observation.timestamp = 1.5
        XCTAssertEqual(evaluator.evaluate(observation).state, .ready)
    }
}

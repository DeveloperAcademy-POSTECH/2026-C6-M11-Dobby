import CoreGraphics
import XCTest
@testable import Dobby

final class HomeMeasurementTransitionTests: XCTestCase {
    func testPrototypeDurationsAndCommitBoundaryStayIndependent() {
        XCTAssertEqual(HomeMeasurementMotion.transitionDuration, 0.65, accuracy: 0.000001)
        XCTAssertEqual(HomeMeasurementMotion.returnDuration, 0.25, accuracy: 0.000001)
        XCTAssertEqual(HomeMeasurementMotion.idleDuration, 2.0, accuracy: 0.000001)
        XCTAssertEqual(HomeMeasurementMotion.accessiblePullDuration, 0.30, accuracy: 0.000001)
        XCTAssertFalse(HomeMeasurementMotion.shouldCommit(pull: 87.5 - 0.001))
        XCTAssertTrue(HomeMeasurementMotion.shouldCommit(pull: 87.5))
        XCTAssertTrue(HomeMeasurementMotion.shouldCommit(pull: 87.5 + 0.001))
        XCTAssertTrue(HomeMeasurementMotion.shouldCommit(pull: HomeMeasurementMotion.accessiblePullDistance))
    }

    func testHeldPullMovesOnlyTheBoundedStripAndKeepsHomeCovered() {
        XCTAssertEqual(HomeMeasurementMotion.maximumPull, 140)
        for size in phoneSizes {
            let scale = size.width / 402
            let idle = HomeMeasurementMotion.pose(seed: .init(pull: 0, canvasSize: size), progress: 0)
            for requestedPull: CGFloat in [0, 1, 24, 87.5, 100, 140, 160, 1_000] {
                let expectedPull = min(140, requestedPull)
                for lead: CGFloat in [0, 8] {
                    let seed = HomeMeasurementTransitionSeed(pull: requestedPull, canvasSize: size, tapeLead: lead)
                    let held = HomeMeasurementMotion.pose(seed: seed, progress: 0)
                    XCTAssertEqual(seed.pull, expectedPull)
                    XCTAssertEqual(held.pull, expectedPull * scale, accuracy: 0.000001)
                    XCTAssertEqual(held.follow, 0, "The reel must wait until the finger is released")
                    XCTAssertEqual(held.drop, 0)
                    XCTAssertEqual(held.bodyCenter, idle.bodyCenter)
                    XCTAssertTrue((0...1).contains(held.homeOpacity),
                                  "Home instructions may fade beneath the opaque Home cover")
                    XCTAssertEqual(held.guideRevealOpacity, 0, "A held pull must never reveal capture behind Home")
                    assertPoint(held.tape.capCenter, equals: CGPoint(x: 193.55 * scale,
                        y: (438.445 + expectedPull + lead) * scale))
                    XCTAssertLessThanOrEqual(held.tape.capCenter.y - idle.tape.capCenter.y,
                                             (140 + lead) * scale + 0.000001)
                    assertTapeIsStraightAndAttached(held)
                }
            }
        }
    }

    func testRaisedEnlargedReelCoversBothTopCornersThroughoutHeldPull() {
        for size in phoneSizes {
            let scale = size.width / 402
            for pull: CGFloat in [0, 24, 87.5, 100, 140] {
                let held = HomeMeasurementMotion.pose(seed: .init(pull: pull, canvasSize: size), progress: 0)
                assertPoint(held.bodyCenter, equals: CGPoint(x: 201 * scale, y: 77.5 * scale))
                XCTAssertEqual(held.bodyDiameter, size.width * 1.12, accuracy: 0.000001)
                let radius = held.bodyDiameter / 2
                for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0)] {
                    XCTAssertLessThan(hypot(corner.x - held.bodyCenter.x, corner.y - held.bodyCenter.y), radius,
                                      "The reel must overlap the upper corners so capture cannot peek through")
                }
            }
        }
    }

    func testPullThresholdUsesTheSameReferenceDistanceAcrossPhoneWidths() {
        let widths: [CGFloat] = [320, 375, 402, 440]
        for width in widths {
            let scale = width / 402
            let below = HomeMeasurementMotion.normalizedPull(translation: 87.4 * scale, canvasWidth: width)
            let above = HomeMeasurementMotion.normalizedPull(translation: 87.6 * scale, canvasWidth: width)
            XCTAssertEqual(below, 87.4, accuracy: 0.000001)
            XCTAssertEqual(above, 87.6, accuracy: 0.000001)
            XCTAssertFalse(HomeMeasurementMotion.shouldCommit(pull: below))
            XCTAssertTrue(HomeMeasurementMotion.shouldCommit(pull: above))
            XCTAssertEqual(HomeMeasurementMotion.normalizedPull(translation: 140 * scale, canvasWidth: width),
                140, accuracy: 0.000001)
            XCTAssertEqual(HomeMeasurementMotion.normalizedPull(translation: 360 * scale, canvasWidth: width),
                140, accuracy: 0.000001)
        }
    }

    func testInvalidUpwardAndExcessivePullsCannotInvertOrOvershootTheArtwork() {
        XCTAssertEqual(HomeMeasurementMotion.normalizedPull(translation: -120, canvasWidth: 402), 0)
        XCTAssertEqual(HomeMeasurementMotion.normalizedPull(translation: 1_000, canvasWidth: 402), 140)
        let invalidWidths: [CGFloat] = [0, -10, .nan, .infinity]
        for width in invalidWidths {
            XCTAssertEqual(HomeMeasurementMotion.normalizedPull(translation: 100, canvasWidth: width), 0)
        }
        let invalidPulls: [CGFloat] = [.nan, .infinity, -.infinity, -10]
        for pull in invalidPulls {
            let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: CGSize(width: 402, height: 874))
            XCTAssertEqual(seed.pull, 0)
            XCTAssertFalse(HomeMeasurementMotion.shouldCommit(pull: pull))
        }
    }

    func testIdleTapeCueUsesTwoDownwardBouncesAndStopsForReducedMotion() {
        let samples: [(TimeInterval, CGFloat)] = [
            (0, 0), (0.30, 0), (0.46, 4), (0.62, 8), (0.76, 4),
            (0.90, 0), (1.00, 1.5), (1.10, 3), (1.21, 1.5),
            (1.32, 0), (1.99, 0), (2.0, 0)
        ]
        for (time, offset) in samples {
            XCTAssertEqual(HomeMeasurementMotion.idleTapeOffset(elapsed: time), offset, accuracy: 0.000001)
            XCTAssertEqual(HomeMeasurementMotion.idleTapeOffset(elapsed: time + 2.0), offset, accuracy: 0.000001)
            XCTAssertEqual(HomeMeasurementMotion.idleTapeOffset(elapsed: time, reducedMotion: true), 0)
        }
        for time: TimeInterval in [-1, .nan, .infinity, -.infinity] {
            XCTAssertEqual(HomeMeasurementMotion.idleTapeOffset(elapsed: time), 0)
        }
        // The cap stops before changing direction rather than snapping through
        // a linear keyframe corner or starting a fresh cycle with a jump.
        for time: TimeInterval in [0.30, 0.62, 0.90, 1.10, 1.32, 2.0] {
            let center = HomeMeasurementMotion.idleTapeOffset(elapsed: time)
            for sample in [time - 0.0001, time + 0.0001] {
                XCTAssertEqual(HomeMeasurementMotion.idleTapeOffset(elapsed: sample), center,
                    accuracy: 0.00001)
            }
        }
    }

    func testIdleCueExtendsOnlyTheTapeWithoutSupplyingPullOrMovingTheReel() {
        for size in phoneSizes {
            let scale = size.width / 402
            let resting = HomeMeasurementMotion.pose(seed: .init(pull: 0, canvasSize: size), progress: 0)
            for step in 0...200 {
                let lead = HomeMeasurementMotion.idleTapeOffset(elapsed: Double(step) / 100)
                let seed = HomeMeasurementTransitionSeed(pull: 0, canvasSize: size, tapeLead: lead)
                let pose = HomeMeasurementMotion.pose(seed: seed, progress: 0)
                XCTAssertTrue((0...8).contains(lead))
                XCTAssertEqual(seed.pull, 0)
                XCTAssertEqual(pose.pull, 0)
                XCTAssertEqual(pose.follow, 0)
                XCTAssertEqual(pose.drop, 0)
                XCTAssertEqual(pose.bodyCenter, resting.bodyCenter)
                XCTAssertEqual(pose.bodyDiameter, resting.bodyDiameter)
                XCTAssertEqual(pose.homeOpacity, 1)
                XCTAssertFalse(HomeMeasurementMotion.shouldCommit(pull: seed.pull))
                assertPoint(pose.tape.capCenter, equals: CGPoint(x: resting.tape.capCenter.x,
                    y: resting.tape.capCenter.y + lead * scale))
                assertTapeIsStraightAndAttached(pose)
                // The first-touch snapshot must not retain a second cap below
                // its 494pt artwork crop, even at the bottom of the idle bounce.
                let cap = pose.tape
                let halfHeight = cap.capSize.height * CGFloat(cos(cap.capAngleRadians)) / 2
                    + cap.capSize.width * CGFloat(sin(cap.capAngleRadians)) / 2
                XCTAssertLessThan(cap.capCenter.y + halfHeight, 494 * scale)
            }
        }
    }

    func testTapeLeadIsFiniteBoundedAndDefaultsToZero() {
        let size = CGSize(width: 402, height: 874)
        XCTAssertEqual(HomeMeasurementTransitionSeed(pull: 0, canvasSize: size).tapeLead, 0)
        let samples: [(CGFloat, CGFloat)] = [
            (.nan, 0), (.infinity, 0), (-.infinity, 0), (-1, 0),
            (0, 0), (4, 4), (8, 8), (100, 8)
        ]
        for (lead, expected) in samples {
            let seed = HomeMeasurementTransitionSeed(pull: 87.4, canvasSize: size, tapeLead: lead)
            XCTAssertEqual(seed.tapeLead, expected)
            XCTAssertEqual(seed.pull, 87.4)
            XCTAssertFalse(HomeMeasurementMotion.shouldCommit(pull: seed.pull))
            assertFinite(HomeMeasurementMotion.pose(seed: seed, progress: 0))
        }
    }

    func testReleaseStartsAtTheHeldTapePoseWithoutASnap() {
        for size in phoneSizes {
            let scale = size.width / 402
            for pull: CGFloat in [0, 87.5, 100, 120, 140] {
                for lead: CGFloat in [0, 4, 8] {
                    let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: size, tapeLead: lead)
                    let initial = HomeMeasurementMotion.pose(seed: seed, progress: 0)
                    let immediatelyAfterRelease = HomeMeasurementMotion.pose(seed: seed, progress: 0.0000001)
                    XCTAssertEqual(initial.pull, pull * scale, accuracy: 0.000001)
                    XCTAssertEqual(initial.drop, initial.follow, accuracy: 0.000001)
                    XCTAssertEqual(initial.bodyCenter.x, 201 * scale, accuracy: 0.000001)
                    // Keep the raised reel over both upper corners, while the
                    // strip cap retains its independent resting position.
                    XCTAssertEqual(initial.bodyCenter.y - initial.follow,
                        77.5 * scale, accuracy: 0.000001)
                    XCTAssertEqual(initial.bodyDiameter, size.width * 1.12, accuracy: 0.000001)
                    XCTAssertEqual(initial.bodyCenter.x - initial.bodyDiameter / 2, -size.width * 0.06,
                        accuracy: 0.000001)
                    XCTAssertEqual(initial.bodyCenter.x + initial.bodyDiameter / 2, size.width * 1.06,
                        accuracy: 0.000001)
                    XCTAssertGreaterThanOrEqual(
                        initial.bodyCenter.y - initial.follow - initial.bodyDiameter * 40 / 626, 48 * scale)
                    assertPoint(initial.tape.capCenter, equals: CGPoint(x: 193.55 * scale,
                        y: (438.445 + pull + lead) * scale))
                    XCTAssertEqual(initial.guideRevealOpacity, 0)
                    XCTAssertFalse(initial.isComplete)

                    // A cover presentation reuses the held geometry, including
                    // any idle lead captured at first touch. Its first frame
                    // must not reset the reel, cap, ribbon, or shaded fold.
                    assertPoint(immediatelyAfterRelease.bodyCenter, equals: initial.bodyCenter, accuracy: 0.001)
                    assertPoint(immediatelyAfterRelease.tape.capCenter, equals: initial.tape.capCenter, accuracy: 0.001)
                    assertPoint(immediatelyAfterRelease.tape.leftJoin, equals: initial.tape.leftJoin, accuracy: 0.001)
                    assertPoint(immediatelyAfterRelease.tape.rightJoin, equals: initial.tape.rightJoin, accuracy: 0.001)
                    assertPoint(immediatelyAfterRelease.tape.leftTop, equals: initial.tape.leftTop, accuracy: 0.001)
                    assertPoint(immediatelyAfterRelease.tape.rightTop, equals: initial.tape.rightTop, accuracy: 0.001)
                    assertPoint(immediatelyAfterRelease.tape.shadowTip, equals: initial.tape.shadowTip, accuracy: 0.001)
                    assertPoint(immediatelyAfterRelease.tape.shadowOuter, equals: initial.tape.shadowOuter, accuracy: 0.001)
                    assertPoint(immediatelyAfterRelease.tape.shadowInner, equals: initial.tape.shadowInner, accuracy: 0.001)
                    XCTAssertEqual(immediatelyAfterRelease.tape.shadowVisibleLength,
                        initial.tape.shadowVisibleLength, accuracy: 0.001)
                    XCTAssertEqual(immediatelyAfterRelease.tape.shadowOpacity, initial.tape.shadowOpacity,
                        accuracy: 0.000001)
                    XCTAssertEqual(HomeMeasurementMotion.pose(seed: seed, progress: -1), initial)
                    XCTAssertEqual(HomeMeasurementMotion.pose(seed: seed, progress: .nan), initial)
                }
            }
        }
    }

    func testHeldIdleLeadCannotAdvanceTheReelCommitOrHapticPullDataDuringRelease() {
        for size in phoneSizes {
            let scale = size.width / 402
            for pull: CGFloat in [0, 87.4, 87.5, 100, 120, 140] {
                for lead: CGFloat in [4, 8] {
                    let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: size, tapeLead: lead)
                    XCTAssertEqual(HomeMeasurementMotion.shouldCommit(pull: seed.pull), pull >= 87.5)
                    for progress in [0, 0.08, 0.27, 0.65, 1.0] {
                        let baseline = HomeMeasurementMotion.pose(seed: .init(pull: pull, canvasSize: size),
                            progress: progress)
                        let pose = HomeMeasurementMotion.pose(seed: seed, progress: progress)
                        XCTAssertEqual(pose.pull, baseline.pull)
                        XCTAssertEqual(pose.follow, baseline.follow)
                        XCTAssertEqual(pose.drop, baseline.drop)
                        XCTAssertEqual(pose.bodyCenter, baseline.bodyCenter)
                        XCTAssertEqual(pose.bodyRotationRadians, baseline.bodyRotationRadians)
                        XCTAssertEqual(pose.homeOpacity, baseline.homeOpacity)
                        XCTAssertEqual(pose.homeDrift, baseline.homeDrift)
                        XCTAssertEqual(pose.guideRevealOpacity, baseline.guideRevealOpacity)
                        XCTAssertEqual(pose.tape.capAngleRadians, baseline.tape.capAngleRadians)
                        assertPoint(pose.tape.capCenter, equals: CGPoint(x: baseline.tape.capCenter.x,
                            y: baseline.tape.capCenter.y + lead * scale))
                        assertFinite(pose)
                        assertTapeIsStraightAndAttached(pose)
                        if progress == 1 {
                            XCTAssertTrue(pose.isComplete)
                            XCTAssertGreaterThan(pose.bodyCenter.y - pose.bodyDiameter / 2, size.height)
                            XCTAssertGreaterThan(pose.tape.capCenter.y - pose.tape.capSize.height, size.height)
                            XCTAssertEqual(pose.tape.shadowVisibleLength, 0, accuracy: 0.000001)
                            XCTAssertEqual(pose.tape.shadowOpacity, 0)
                        }
                    }
                }
            }
        }
    }

    func testReelWaitsThroughThePullAndMovesTogetherWithTheTapeAfterRelease() {
        let size = CGSize(width: 402, height: 874)
        let idle = HomeMeasurementMotion.pose(seed: .init(pull: 0, canvasSize: size), progress: 0)
        var previous = idle
        for pull: CGFloat in [5, 10, 22, 40, 87.5, 100, 120, 140] {
            let held = HomeMeasurementMotion.pose(seed: .init(pull: pull, canvasSize: size), progress: 0)
            XCTAssertEqual(held.follow, 0)
            XCTAssertEqual(held.drop, 0)
            XCTAssertEqual(held.bodyCenter, idle.bodyCenter)
            XCTAssertGreaterThan(held.tape.capCenter.y, previous.tape.capCenter.y)
            previous = held
        }

        let seed = HomeMeasurementTransitionSeed(pull: 140, canvasSize: size)
        for progress in [0.01, 0.25, 0.5, 1] {
            let released = HomeMeasurementMotion.pose(seed: seed, progress: progress)
            XCTAssertGreaterThan(released.bodyCenter.y, previous.bodyCenter.y,
                                 "The reel must begin the wipe only after release")
            XCTAssertGreaterThan(released.tape.capCenter.y, previous.tape.capCenter.y)
            XCTAssertGreaterThan(released.guideRevealOpacity, 0)
            previous = released
        }
        XCTAssertTrue(previous.isComplete)
        XCTAssertGreaterThan(previous.bodyCenter.y - previous.bodyDiameter / 2, size.height)
    }

    func testStraightTapeKeepsItsWidthAndConnectionWhileTheReelDescends() {
        for size in phoneSizes {
            for pull: CGFloat in [0, 87.5, 100, 120, 140] {
                let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: size)
                var previous = HomeMeasurementMotion.pose(seed: seed, progress: 0)
                for step in 0...100 {
                    let pose = HomeMeasurementMotion.pose(seed: seed, progress: Double(step) / 100)
                    assertFinite(pose)
                    assertTapeIsStraightAndAttached(pose)
                    XCTAssertEqual(pose.bodyCenter.x, size.width / 2, accuracy: 0.000001)
                    XCTAssertEqual(pose.bodyDiameter, size.width * 1.12, accuracy: 0.000001)
                    XCTAssertEqual(pose.bodyRotationRadians, 0)
                    XCTAssertGreaterThanOrEqual(pose.drop + 0.000001, previous.drop)
                    XCTAssertLessThanOrEqual(pose.homeOpacity, previous.homeOpacity + 0.000001)
                    XCTAssertGreaterThanOrEqual(pose.guideRevealOpacity + 0.000001, previous.guideRevealOpacity)
                    XCTAssertTrue((0...1).contains(pose.homeOpacity))
                    XCTAssertTrue((0...1).contains(pose.guideRevealOpacity))
                    XCTAssertEqual(pose.isComplete, step == 100)
                    previous = pose
                }
                XCTAssertEqual(previous.homeOpacity, 0)
                XCTAssertEqual(previous.guideRevealOpacity, 1)
                XCTAssertGreaterThan(previous.bodyCenter.y - previous.bodyDiameter / 2, size.height)
                XCTAssertEqual(HomeMeasurementMotion.pose(seed: seed, progress: 2), previous)
                XCTAssertEqual(HomeMeasurementMotion.pose(seed: seed, progress: 0.14).guideRevealOpacity, 1)
            }
        }
    }

    func testShadowRollsUpTheStraightRightEdgeWithoutNarrowingTheWhiteTape() {
        for size in phoneSizes {
            for pull: CGFloat in [0, 87.5, 100, 120, 140] {
                let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: size)
                let initial = HomeMeasurementMotion.pose(seed: seed, progress: 0)
                let middle = HomeMeasurementMotion.pose(seed: seed, progress: 0.5)
                XCTAssertEqual(initial.tape.shadowOpacity, 1)
                XCTAssertEqual(middle.tape.shadowOpacity, 1)
                var previous = HomeMeasurementMotion.pose(seed: seed, progress: 0.08)
                for step in 8...100 {
                    let pose = HomeMeasurementMotion.pose(seed: seed, progress: Double(step) / 100)
                    let tape = pose.tape
                    let rightEdgeTip = subtract(tape.shadowTip, tape.rightJoin)
                    let rightEdgeOuter = subtract(tape.shadowOuter, tape.rightJoin)
                    XCTAssertEqual(cross(rightEdgeTip, tape.axis), 0, accuracy: 0.000001)
                    XCTAssertEqual(cross(rightEdgeOuter, tape.axis), 0, accuracy: 0.000001)
                    let inward = subtract(tape.shadowInner, tape.shadowOuter)
                    XCTAssertEqual(dot(inward, tape.axis), 0, accuracy: 0.000001)
                    XCTAssertLessThanOrEqual(dot(inward, tape.normal), 0.000001)
                    XCTAssertEqual(tape.width, initial.tape.width, accuracy: 0.000001)
                    XCTAssertGreaterThanOrEqual(tape.shadowVisibleLength, 0)
                    XCTAssertLessThanOrEqual(tape.shadowVisibleLength,
                        previous.tape.shadowVisibleLength + 0.000001)
                    XCTAssertTrue((0...1).contains(tape.shadowOpacity))
                    XCTAssertLessThanOrEqual(tape.shadowOpacity, previous.tape.shadowOpacity + 0.000001)
                    previous = pose
                }
                XCTAssertEqual(previous.tape.shadowVisibleLength, 0, accuracy: 0.000001)
                XCTAssertEqual(previous.tape.shadowOpacity, 0)
            }
        }
    }

    func testFittedArtworkKeepsItsHomeSizeAndHorizontalInsetDuringHandoff() {
        let canvas = CGSize(width: 375, height: 667)
        let artworkWidth: CGFloat = 180
        let local = HomeMeasurementMotion.pose(seed: .init(pull: 100,
            canvasSize: CGSize(width: artworkWidth, height: canvas.height), tapeLead: 6), progress: 0)
        let seed = HomeMeasurementTransitionSeed(pull: 100, canvasSize: canvas,
            artworkWidth: artworkWidth, tapeLead: 6)
        let handoff = HomeMeasurementMotion.pose(seed: seed, progress: 0)
        let inset = (canvas.width - artworkWidth) / 2
        XCTAssertEqual(handoff.scale, local.scale)
        XCTAssertEqual(handoff.bodyCenter.x, canvas.width / 2)
        XCTAssertEqual(handoff.bodyCenter.y, local.bodyCenter.y)
        XCTAssertEqual(handoff.bodyDiameter, local.bodyDiameter)
        for (screenPoint, localPoint) in [
            (handoff.tape.capCenter, local.tape.capCenter),
            (handoff.tape.leftJoin, local.tape.leftJoin),
            (handoff.tape.rightJoin, local.tape.rightJoin),
            (handoff.tape.shadowTip, local.tape.shadowTip)
        ] {
            assertPoint(screenPoint, equals: CGPoint(x: localPoint.x + inset, y: localPoint.y))
        }
        XCTAssertEqual(handoff.guideRevealOpacity, 0)
        assertTapeIsStraightAndAttached(handoff)
        let finish = HomeMeasurementMotion.pose(seed: seed, progress: 1)
        XCTAssertGreaterThan(finish.bodyCenter.y - finish.bodyDiameter / 2, canvas.height)
    }

    func testResponsiveScalingPreservesTimingAndTapeGeometryInsteadOfDevicePixels() {
        let referenceSize = CGSize(width: 402, height: 874)
        let scales: [CGFloat] = [320.0 / 402, 1, 440.0 / 402]
        let progressSamples: [Double] = [0, 0.27, 0.65, 1]
        for scale in scales {
            let size = CGSize(width: referenceSize.width * scale, height: referenceSize.height * scale)
            for lead: CGFloat in [0, 4, 8] {
                for progress in progressSamples {
                    let reference = HomeMeasurementMotion.pose(
                        seed: .init(pull: 100, canvasSize: referenceSize, tapeLead: lead), progress: progress)
                    let resized = HomeMeasurementMotion.pose(
                        seed: .init(pull: 100, canvasSize: size, tapeLead: lead), progress: progress)
                    XCTAssertEqual(resized.pull, reference.pull * scale, accuracy: 0.000001)
                    XCTAssertEqual(resized.follow, reference.follow * scale, accuracy: 0.000001)
                    XCTAssertEqual(resized.drop, reference.drop * scale, accuracy: 0.000001)
                    assertPoint(resized.bodyCenter, equals: multiplied(reference.bodyCenter, by: scale))
                    assertPoint(resized.tape.capCenter, equals: multiplied(reference.tape.capCenter, by: scale))
                    assertPoint(resized.tape.leftJoin, equals: multiplied(reference.tape.leftJoin, by: scale))
                    assertPoint(resized.tape.rightJoin, equals: multiplied(reference.tape.rightJoin, by: scale))
                    assertPoint(resized.tape.leftTop, equals: multiplied(reference.tape.leftTop, by: scale))
                    assertPoint(resized.tape.rightTop, equals: multiplied(reference.tape.rightTop, by: scale))
                    assertPoint(resized.tape.shadowTip, equals: multiplied(reference.tape.shadowTip, by: scale))
                    assertPoint(resized.tape.shadowOuter, equals: multiplied(reference.tape.shadowOuter, by: scale))
                    assertPoint(resized.tape.shadowInner, equals: multiplied(reference.tape.shadowInner, by: scale))
                    assertPoint(resized.tape.axis, equals: reference.tape.axis)
                    assertPoint(resized.tape.normal, equals: reference.tape.normal)
                    XCTAssertEqual(resized.tape.width, reference.tape.width * scale, accuracy: 0.000001)
                    XCTAssertEqual(resized.tape.shadowVisibleLength,
                        reference.tape.shadowVisibleLength * scale, accuracy: 0.000001)
                    XCTAssertEqual(resized.tape.shadowOpacity, reference.tape.shadowOpacity)
                    XCTAssertEqual(resized.tape.capAngleRadians, reference.tape.capAngleRadians)
                    XCTAssertEqual(resized.bodyRotationRadians, reference.bodyRotationRadians)
                    XCTAssertEqual(resized.homeOpacity, reference.homeOpacity)
                    XCTAssertEqual(resized.guideRevealOpacity, reference.guideRevealOpacity)
                    XCTAssertEqual(resized.isComplete, reference.isComplete)
                }
            }
        }
    }

    private var phoneSizes: [CGSize] {
        [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
         CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)]
    }

    private func assertTapeIsStraightAndAttached(_ pose: HomeMeasurementTransitionPose,
        file: StaticString = #filePath, line: UInt = #line) {
        let tape = pose.tape
        let scale = pose.scale
        XCTAssertEqual(dot(tape.axis, tape.axis), 1, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(dot(tape.normal, tape.normal), 1, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(dot(tape.axis, tape.normal), 0, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(tape.width, 84 * scale, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(tape.capSize.width, 92 * scale, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(tape.capSize.height, 68 * scale, accuracy: 0.000001, file: file, line: line)
        assertPoint(subtract(tape.rightJoin, tape.leftJoin), equals: multiplied(tape.normal, by: tape.width),
            file: file, line: line)
        for (join, top, shoulder) in [(tape.leftJoin, tape.leftTop, CGFloat(-42)),
                                      (tape.rightJoin, tape.rightTop, CGFloat(42))] {
            let fromCap = subtract(join, tape.capCenter)
            XCTAssertEqual(dot(fromCap, tape.normal), shoulder * scale,
                accuracy: 0.000001, file: file, line: line)
            XCTAssertEqual(dot(fromCap, tape.axis), 26 * scale,
                accuracy: 0.000001, file: file, line: line)
            let edge = subtract(top, join)
            XCTAssertEqual(cross(edge, tape.axis), 0, accuracy: 0.000001, file: file, line: line)
            XCTAssertGreaterThan(dot(edge, tape.axis), 0, file: file, line: line)
            let fromReel = subtract(top, pose.bodyCenter)
            XCTAssertLessThanOrEqual(dot(fromReel, fromReel),
                pose.bodyDiameter * pose.bodyDiameter / 4 + 0.000001, file: file, line: line)
        }
    }

    private func assertFinite(_ pose: HomeMeasurementTransitionPose,
        file: StaticString = #filePath, line: UInt = #line) {
        let tape = pose.tape
        let values: [CGFloat] = [pose.scale, pose.pull, pose.follow, pose.drop, pose.bodyDiameter,
            pose.homeDrift, tape.width, tape.capSize.width, tape.capSize.height, tape.shadowVisibleLength]
        XCTAssertTrue(values.allSatisfy(\.isFinite), file: file, line: line)
        XCTAssertTrue(pose.bodyRotationRadians.isFinite && pose.homeOpacity.isFinite &&
            pose.guideRevealOpacity.isFinite && tape.capAngleRadians.isFinite && tape.shadowOpacity.isFinite,
            file: file, line: line)
        let points = [pose.bodyCenter, tape.capCenter, tape.leftJoin, tape.rightJoin, tape.leftTop,
            tape.rightTop, tape.axis, tape.normal, tape.shadowTip, tape.shadowOuter, tape.shadowInner]
        XCTAssertTrue(points.allSatisfy { $0.x.isFinite && $0.y.isFinite }, file: file, line: line)
    }

    private func assertPoint(_ actual: CGPoint, equals expected: CGPoint, accuracy: CGFloat = 0.000001,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }

    private func subtract(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    private func multiplied(_ point: CGPoint, by scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private func dot(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        lhs.x * rhs.x + lhs.y * rhs.y
    }

    private func cross(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        lhs.x * rhs.y - lhs.y * rhs.x
    }
}

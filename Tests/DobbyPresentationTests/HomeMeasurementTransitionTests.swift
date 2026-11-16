import CoreGraphics
import XCTest
@testable import Dobby

final class HomeMeasurementTransitionTests: XCTestCase {
    func testPrototypeDurationsAndCommitBoundaryStayIndependent() {
        XCTAssertEqual(HomeMeasurementMotion.transitionDuration, 0.65, accuracy: 0.000001)
        XCTAssertEqual(HomeMeasurementMotion.returnDuration, 0.25, accuracy: 0.000001)
        XCTAssertEqual(HomeMeasurementMotion.idleDuration, 2.25, accuracy: 0.000001)
        XCTAssertEqual(HomeMeasurementMotion.accessiblePullDuration, 0.30, accuracy: 0.000001)
        XCTAssertFalse(HomeMeasurementMotion.shouldCommit(pull: 87.5 - 0.001))
        XCTAssertTrue(HomeMeasurementMotion.shouldCommit(pull: 87.5))
        XCTAssertTrue(HomeMeasurementMotion.shouldCommit(pull: 87.5 + 0.001))
        XCTAssertTrue(HomeMeasurementMotion.shouldCommit(pull: HomeMeasurementMotion.accessiblePullDistance))
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
            XCTAssertEqual(HomeMeasurementMotion.normalizedPull(translation: 270 * scale, canvasWidth: width),
                270, accuracy: 0.000001)
        }
    }

    func testInvalidUpwardAndExcessivePullsCannotInvertOrOvershootTheArtwork() {
        XCTAssertEqual(HomeMeasurementMotion.normalizedPull(translation: -120, canvasWidth: 402), 0)
        XCTAssertEqual(HomeMeasurementMotion.normalizedPull(translation: 1_000, canvasWidth: 402), 270)
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

    func testIdleArrowKeepsThePrototypeKeyframesAndStopsForReducedMotion() {
        let samples: [(TimeInterval, CGFloat)] = [
            (0, 0), (0.10, 5), (0.20, 13.5), (0.60, 10), (1.85, 10), (1.95, -1), (2.05, 0)
        ]
        for (time, offset) in samples {
            XCTAssertEqual(HomeMeasurementMotion.idleArrowOffset(elapsed: time), offset, accuracy: 0.000001)
            XCTAssertEqual(HomeMeasurementMotion.idleArrowOffset(elapsed: time + 2.25), offset, accuracy: 0.000001)
            XCTAssertEqual(HomeMeasurementMotion.idleArrowOffset(elapsed: time, reducedMotion: true), 0)
        }
        XCTAssertEqual(HomeMeasurementMotion.idleArrowOffset(elapsed: .nan), 0)
    }

    func testTransitionStartsAtTheReleasedPullAndFinishesBelowTheCanvas() {
        let seed = HomeMeasurementTransitionSeed(pull: 100, canvasSize: CGSize(width: 402, height: 874))
        let initial = HomeMeasurementMotion.pose(seed: seed, progress: 0)
        XCTAssertEqual(initial.follow, 18.6, accuracy: 0.000001)
        XCTAssertEqual(initial.drop, initial.follow)
        XCTAssertEqual(initial.bodyCenter.x, 201, accuracy: 0.000001)
        XCTAssertEqual(initial.bodyCenter.y, 1.6, accuracy: 0.000001)
        XCTAssertEqual(initial.bodyDiameter, 604, accuracy: 0.000001)
        XCTAssertEqual(initial.bodyRotationRadians, 0)
        XCTAssertFalse(initial.isComplete)

        let final = HomeMeasurementMotion.pose(seed: seed, progress: 1)
        XCTAssertEqual(final.drop, 1_225, accuracy: 0.000001)
        XCTAssertEqual(final.bodyCenter.y, 1_208, accuracy: 0.000001)
        XCTAssertEqual(final.bodyRotationRadians, -0.215, accuracy: 0.000001)
        XCTAssertEqual(final.homeOpacity, 0)
        XCTAssertGreaterThanOrEqual(final.guideMaskOpaqueEnd, seed.canvasSize.height)
        XCTAssertTrue(final.isComplete)
        XCTAssertEqual(HomeMeasurementMotion.pose(seed: seed, progress: -1), initial)
        XCTAssertEqual(HomeMeasurementMotion.pose(seed: seed, progress: .nan), initial)
        XCTAssertEqual(HomeMeasurementMotion.pose(seed: seed, progress: 2), final)
    }

    func testMaskAndBodyAdvanceContinuouslyWithoutRevealingGapsOnDifferentScreens() {
        let pulls: [CGFloat] = [87.5, 100, 270]
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)] {
            for pull in pulls {
                let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: size)
                var previous = HomeMeasurementMotion.pose(seed: seed, progress: 0)
                for step in 0...100 {
                    let pose = HomeMeasurementMotion.pose(seed: seed, progress: Double(step) / 100)
                    XCTAssertEqual(pose.bodyCenter.x, size.width / 2, accuracy: 0.000001)
                    XCTAssertEqual(pose.bodyDiameter, 604 * size.width / 402, accuracy: 0.000001)
                    XCTAssertGreaterThanOrEqual(pose.drop + 0.000001, previous.drop)
                    XCTAssertGreaterThanOrEqual(pose.guideMaskOpaqueEnd + 0.000001, previous.guideMaskOpaqueEnd)
                    XCTAssertGreaterThanOrEqual(pose.guideMaskTransparentEnd + 0.000001, previous.guideMaskTransparentEnd)
                    XCTAssertEqual(pose.guideMaskTransparentEnd - pose.guideMaskOpaqueEnd,
                        25 * size.width / 402, accuracy: 0.000001)
                    XCTAssertGreaterThanOrEqual(pose.guideMaskOpaqueEnd, -22 * size.width / 402 - 0.000001)
                    XCTAssertLessThanOrEqual(pose.homeOpacity, previous.homeOpacity + 0.000001)
                    XCTAssertTrue((0...1).contains(pose.homeOpacity))
                    XCTAssertTrue(pose.bodyCenter.y.isFinite && pose.guideMaskOpaqueEnd.isFinite)
                    XCTAssertEqual(pose.isComplete, step == 100)
                    previous = pose
                }
                XCTAssertGreaterThanOrEqual(previous.guideMaskOpaqueEnd, size.height)
            }
        }
    }

    func testResponsiveScalingPreservesTimingAndRotationInsteadOfDevicePixels() {
        let referenceSize = CGSize(width: 402, height: 874)
        let scales: [CGFloat] = [320.0 / 402, 1, 440.0 / 402]
        let progressSamples: [Double] = [0, 0.27, 0.65, 1]
        for scale in scales {
            let size = CGSize(width: referenceSize.width * scale, height: referenceSize.height * scale)
            for progress in progressSamples {
                let reference = HomeMeasurementMotion.pose(seed: .init(pull: 100, canvasSize: referenceSize),
                                                           progress: progress)
                let resized = HomeMeasurementMotion.pose(seed: .init(pull: 100, canvasSize: size), progress: progress)
                XCTAssertEqual(resized.drop, reference.drop * scale, accuracy: 0.000001)
                XCTAssertEqual(resized.bodyCenter.y, reference.bodyCenter.y * scale, accuracy: 0.000001)
                XCTAssertEqual(resized.guideMaskOpaqueEnd, reference.guideMaskOpaqueEnd * scale, accuracy: 0.000001)
                XCTAssertEqual(resized.bodyRotationRadians, reference.bodyRotationRadians)
                XCTAssertEqual(resized.homeOpacity, reference.homeOpacity)
                XCTAssertEqual(resized.isComplete, reference.isComplete)
            }
        }
    }
}
